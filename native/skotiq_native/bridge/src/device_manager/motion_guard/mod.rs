//! The mount motion guard: notices a mount moving on its own or losing its
//! position, stops what it can, holds the run, and refuses automatic moves
//! until the operator has recovered the mount.
//!
//! # Why
//!
//! The owner's NYX-101 ran its Dec axis at about 4.7 deg/s with no command
//! from any program on 2026-10-17, 10-19 and 11-08, ending with the tube
//! pointing at the ground; on 11-08 it then stopped answering and came back
//! reporting home while it was somewhere else. Skotiq cannot fix the mount's
//! firmware, so it has to recognize the fault and recover from it.
//!
//! # How
//!
//! Every mount command Skotiq sends passes through the device manager, which
//! records it here ([`record_command`]). Every status read is fed to the
//! detector ([`observe_status`]); a sampler makes sure there is a reading at
//! least every second during a run and every five seconds otherwise, reusing
//! the reads the UI already makes. The detector ([`detector`]) compares the
//! readings with the commands and reports uncommanded motion or a lost
//! position. The response ([`response`]) tries to stop the mount, stops
//! guiding, pauses the run, and tells the operator. While a fault is open or
//! the position is unknown, slews, parks and homes are refused
//! ([`block_reason`]).

pub(crate) mod detector;
pub(crate) mod ledger;
pub(crate) mod response;

#[cfg(test)]
mod tests;

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::device::MountStatus;

pub(crate) use detector::{Finding, LostReason, MotionKind, Sample};
pub(crate) use ledger::CommandKind;

/// Readings during a run come at least this often.
pub(crate) const RUN_SAMPLE_INTERVAL: Duration = Duration::from_secs(1);

/// Readings while no run is active come at least this often.
pub(crate) const IDLE_SAMPLE_INTERVAL: Duration = Duration::from_secs(5);

/// A plate solve this far from the mount's reported position means the
/// mount's position model is wrong, not that it points a little off.
pub(crate) const DEFAULT_SOLVE_MISMATCH_DEG: f64 = 10.0;

/// The guard's settings.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GuardConfig {
    /// Watch the mount at all.
    pub enabled: bool,
    /// The altitude below which uncommanded motion is a danger to the rig and
    /// the guard sends stop commands. Above it the guard never fights motion
    /// it did not command: it may be someone using the mount's own software
    /// or hand controller.
    pub min_altitude_deg: f64,
    /// When a run is held by a mount fault, take a frame, plate solve it,
    /// sync and resume without waiting for the operator. Off by default: the
    /// first recovery is the operator's call.
    pub auto_sync_resume: bool,
    /// A sync further than this from the reported position is refused and
    /// marks the position unknown.
    pub solve_mismatch_deg: f64,
}

impl Default for GuardConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            min_altitude_deg: 0.0,
            auto_sync_resume: false,
            solve_mismatch_deg: DEFAULT_SOLVE_MISMATCH_DEG,
        }
    }
}

/// A motion fault as the operator sees it.
#[derive(Debug, Clone, PartialEq)]
pub struct FaultRecord {
    pub kind: MotionKind,
    pub message: String,
    pub detected_at_unix: i64,
    pub rate_deg_per_sec: f64,
    pub ra_hours: f64,
    pub dec_deg: f64,
    pub altitude_deg: Option<f64>,
    pub still_moving: bool,
    /// What the guard sent to stop it, and how each went.
    pub stop_attempts: Vec<String>,
    pub run_paused: bool,
}

/// Why the mount's position is unknown.
#[derive(Debug, Clone, PartialEq)]
pub struct LostRecord {
    pub reason: LostReason,
    pub message: String,
    pub flagged_at_unix: i64,
    pub run_paused: bool,
}

#[derive(Debug, Default)]
pub(crate) struct MountEntry {
    pub(crate) ledger: ledger::CommandLedger,
    pub(crate) detector: detector::Detector,
    /// Clock time of the last reading or failed read, from any caller.
    pub(crate) last_observed: Option<f64>,
    pub(crate) fault: Option<FaultRecord>,
    pub(crate) lost: Option<LostRecord>,
    /// The guard is sending its own stop commands; they explain nothing.
    pub(crate) responding: bool,
    /// The next sync is the operator's recovery and skips the mismatch check.
    pub(crate) recovery_sync: bool,
    /// Clock time the operator was last told about an open fault or lost
    /// position.
    pub(crate) last_reminder: Option<f64>,
    pub(crate) auto_recovering: bool,
    /// Stop commands are going out for a dive below the altitude limit.
    pub(crate) stopping: bool,
    /// Motion with no command that the guard noticed and, with no run active
    /// and no danger, left alone: kind and rate, kept in case it turns into a
    /// dive.
    pub(crate) unrecorded_motion: Option<(MotionKind, f64)>,
}

#[derive(Default)]
pub(crate) struct Registry {
    pub(crate) config: Option<GuardConfig>,
    pub(crate) mounts: HashMap<String, MountEntry>,
}

pub(crate) fn registry() -> &'static Mutex<Registry> {
    static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(Registry::default()))
}

pub(crate) fn with_registry<T>(f: impl FnOnce(&mut Registry) -> T) -> T {
    let mut guard = registry().lock().unwrap_or_else(|p| p.into_inner());
    f(&mut guard)
}

/// Seconds on the guard's monotonic clock.
pub(crate) fn now() -> f64 {
    static ORIGIN: OnceLock<Instant> = OnceLock::new();
    ORIGIN.get_or_init(Instant::now).elapsed().as_secs_f64()
}

pub(crate) fn unix_now() -> i64 {
    chrono::Utc::now().timestamp()
}

pub fn config() -> GuardConfig {
    with_registry(|r| r.config.unwrap_or_else(default_config))
}

#[cfg(not(test))]
fn default_config() -> GuardConfig {
    GuardConfig::default()
}

/// Off in unit tests: the simulator tests move the shared simulated mount in
/// ways a real mount never moves, and a fault there would refuse their slews.
/// The guard's own tests turn it on.
#[cfg(test)]
fn default_config() -> GuardConfig {
    GuardConfig {
        enabled: false,
        ..GuardConfig::default()
    }
}

pub fn set_config(config: GuardConfig) {
    with_registry(|r| r.config = Some(config));
}

/// Whether a run is active, cached so a read that finds the executor busy
/// answers with the last value it saw.
static RUN_ACTIVE: AtomicBool = AtomicBool::new(false);

pub(crate) async fn run_is_active() -> bool {
    if let Ok(executor) = skotiq_sequencer::get_executor().try_read() {
        let active = matches!(
            executor.get_state().await,
            skotiq_sequencer::ExecutorState::Running
                | skotiq_sequencer::ExecutorState::Paused
                | skotiq_sequencer::ExecutorState::Recovering
        );
        RUN_ACTIVE.store(active, Ordering::Relaxed);
    }
    RUN_ACTIVE.load(Ordering::Relaxed)
}

/// Declination of the home pose for the configured site.
fn home_dec_deg() -> f64 {
    let southern = crate::api::get_state()
        .get_observer_location()
        .ok()
        .flatten()
        .is_some_and(|site| site.latitude < 0.0);
    if southern {
        -90.0
    } else {
        90.0
    }
}

/// Record a mount command at the moment it is sent.
pub(crate) fn record_command(device_id: &str, kind: CommandKind) {
    let t = now();
    with_registry(|r| {
        let entry = r.mounts.entry(device_id.to_string()).or_default();
        let stop_command = match kind {
            CommandKind::Abort => true,
            CommandKind::MoveAxis { rate, .. } => rate == 0.0,
            _ => false,
        };
        if entry.responding && stop_command {
            return;
        }
        entry.ledger.record(t, kind);
    });
}

fn sample_of(status: &MountStatus, t: f64) -> Sample {
    Sample {
        t,
        ra_hours: status.right_ascension,
        dec_deg: status.declination,
        altitude_deg: status.altitude,
        slewing: status.slewing,
        tracking: status.tracking,
        parked: status.parked,
        at_home: status.at_home,
    }
}

/// Feed one status read to the guard. Called from every mount status read.
pub(crate) async fn observe_status<E>(device_id: &str, result: &Result<MountStatus, E>) {
    let cfg = config();
    if !cfg.enabled {
        return;
    }
    let run_active = run_is_active().await;
    let home_dec = home_dec_deg();
    let t = now();
    let findings = with_registry(|r| {
        let entry = r.mounts.entry(device_id.to_string()).or_default();
        entry.last_observed = Some(t);
        match result {
            Ok(status) if status.connected => {
                let ctx = detector::Context {
                    watch_position: run_active || entry.fault.is_some(),
                    home_dec_deg: home_dec,
                };
                let fault_recorded = entry.fault.is_some();
                let sample = sample_of(status, t);
                tracing::debug!(
                    device_id,
                    slewing = sample.slewing,
                    expected = entry.ledger.expects_motion(t),
                    moving = entry.detector.fault_moving(),
                    "motion guard reading"
                );
                let mut findings =
                    entry
                        .detector
                        .observe(sample, &mut entry.ledger, ctx, fault_recorded);
                if let Some(fault) = entry.fault.as_mut() {
                    fault.still_moving = entry.detector.fault_moving();
                }
                // Uncommanded motion heading below the altitude limit is the
                // one case the guard stops, run or no run.
                if entry.detector.fault_moving() && !entry.stopping {
                    if let Some(reason) = entry.detector.danger(cfg.min_altitude_deg) {
                        entry.stopping = true;
                        findings.push(Finding::Danger(reason));
                    }
                }
                findings
            }
            _ => {
                entry.detector.observe_failure(t);
                Vec::new()
            }
        }
    });
    for finding in findings {
        tracing::debug!(device_id, ?finding, run_active, "motion guard finding");
        response::handle_finding(device_id.to_string(), finding, run_active).await;
    }
}

/// Why a slew, park or home must not be sent to this mount now, or `None`.
pub(crate) fn block_reason(device_id: &str) -> Option<String> {
    with_registry(|r| {
        let entry = r.mounts.get(device_id)?;
        if let Some(lost) = &entry.lost {
            return Some(format!(
                "Skotiq is not moving the mount because its position is unknown: {} Recover the \
                 position first (re-home it and confirm, or plate solve and sync).",
                lost.message
            ));
        }
        if let Some(fault) = &entry.fault {
            return Some(format!(
                "Skotiq is not moving the mount because it moved on its own: {} Check the \
                 mount, then acknowledge the fault.",
                fault.message
            ));
        }
        None
    })
}

/// Whether any mount has an open fault or an unknown position, for refusing
/// to resume a run.
pub(crate) fn any_block_reason() -> Option<String> {
    let ids: Vec<String> = with_registry(|r| r.mounts.keys().cloned().collect());
    ids.iter().find_map(|id| block_reason(id))
}

/// Check a sync before it is sent. A sync this far from where the mount says
/// it points means its position model is wrong: the position is marked
/// unknown and the sync is refused, unless this is the operator's recovery.
pub(crate) async fn check_sync(
    device_id: &str,
    reported: (f64, f64),
    target: (f64, f64),
) -> Result<(), String> {
    let cfg = config();
    let recovery = with_registry(|r| {
        r.mounts
            .get_mut(device_id)
            .map(|e| std::mem::take(&mut e.recovery_sync))
            .unwrap_or(false)
    });
    if recovery || !cfg.enabled {
        return Ok(());
    }
    let degrees = detector::separation_deg(reported, target);
    if degrees <= cfg.solve_mismatch_deg {
        return Ok(());
    }
    let reason = LostReason::SolveDisagrees { degrees };
    let message = reason.describe();
    let run_active = run_is_active().await;
    response::handle_finding(
        device_id.to_string(),
        Finding::PositionLost(reason),
        run_active,
    )
    .await;
    Err(format!(
        "{message} The sync was not sent and the mount's position is marked unknown. Use \
         Recover position to plate solve and sync on purpose."
    ))
}

/// Mount ids the sampler should read: every connected mount plus every mount
/// the guard already knows (a disconnected one counts as silent).
async fn mounts_to_sample() -> Vec<(String, bool)> {
    let manager = crate::api::get_device_manager();
    let connected: Vec<String> = manager
        .get_connected_device_infos()
        .await
        .into_iter()
        .filter(|d| d.device_type == crate::device::DeviceType::Mount)
        .map(|d| d.id)
        .collect();
    let known: Vec<String> = with_registry(|r| r.mounts.keys().cloned().collect());
    let mut out: Vec<(String, bool)> = connected.iter().map(|id| (id.clone(), true)).collect();
    for id in known {
        if !connected.contains(&id) {
            out.push((id, false));
        }
    }
    out
}

static SAMPLER_STARTED: AtomicBool = AtomicBool::new(false);

/// Start the sampler once per process. Called when a mount connects.
pub(crate) fn ensure_sampler() {
    if SAMPLER_STARTED.swap(true, Ordering::SeqCst) {
        return;
    }
    let Ok(runtime) = crate::ensure_runtime() else {
        SAMPLER_STARTED.store(false, Ordering::SeqCst);
        return;
    };
    runtime.handle().spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_millis(250)).await;
            sampler_round().await;
        }
    });
}

async fn sampler_round() {
    if !config().enabled {
        return;
    }
    let interval = if run_is_active().await {
        RUN_SAMPLE_INTERVAL
    } else {
        IDLE_SAMPLE_INTERVAL
    }
    .as_secs_f64();
    let t = now();
    for (device_id, connected) in mounts_to_sample().await {
        let due = with_registry(|r| {
            r.mounts
                .get(&device_id)
                .and_then(|e| e.last_observed)
                .is_none_or(|last| t - last >= interval)
        });
        if !due {
            continue;
        }
        if connected {
            // The read feeds the guard through `mount_get_status`. A read that
            // hangs is the mount not answering.
            let read = tokio::time::timeout(
                Duration::from_secs(5),
                crate::api::get_device_manager().mount_get_status(&device_id),
            )
            .await;
            if read.is_err() {
                observe_status::<String>(&device_id, &Err("timed out".to_string())).await;
            }
        } else {
            observe_status::<String>(&device_id, &Err("not connected".to_string())).await;
        }
    }
    response::remind_open_faults().await;
}

/// Forget everything about a mount, for tests.
#[cfg(test)]
pub(crate) fn reset_for_tests() {
    with_registry(|r| {
        r.mounts.clear();
        r.config = None;
    });
}
