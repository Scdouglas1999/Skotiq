//! Dual-rig / multi-camera synchronized imaging.
//!
//! v1 scope: a SECONDARY camera (e.g. a widefield piggyback scope on the same
//! mount) runs its own exposure loop while the PRIMARY rig executes the main
//! sequence. The two share one mount, so when the primary dithers, the
//! secondary must not be mid-exposure — a dither moves the mount and would
//! trail the secondary frame. This module provides:
//!
//!   1. [`DitherBarrier`] — the shared coordination primitive. The primary
//!      announces "dither pending" before pulsing the guider; the secondary
//!      loop blocks NEW exposures while a dither is pending and reports
//!      whether it is currently mid-exposure. The primary waits (bounded by a
//!      configurable max-wait) for the secondary to be clear before pulsing,
//!      then releases the barrier after settle so the secondary resumes.
//!
//!   2. [`SecondaryRig`] — the background capture-loop driver. It owns a
//!      [`SecondaryRigConfig`] (camera id, exposure/gain/offset/binning/count
//!      or run-until-primary-ends) and drives the secondary camera through the
//!      shared [`crate::device_ops::DeviceOps`] handle, reusing the same
//!      capture + `save_fits` pipeline the primary uses. Frames are saved with
//!      the primary's target name but the secondary's own camera metadata and
//!      a rig tag.
//!
//! ## Explicit v1 NON-GOALS (do not "fix" these without a brief):
//!   * The secondary has NO independent guiding / dithering — it piggybacks on
//!     the primary's guider via the barrier. (`secondary` here means a second
//!     IMAGING camera, not a second guide camera.)
//!   * NO per-secondary plate solving / centering.
//!   * NO secondary autofocus / filter-wheel / rotator control.
//!   * SAME mount only (piggyback). No second-mount coordination.
//!   * The secondary does NOT participate in the primary's behavior-tree
//!     recovery / meridian-flip / safety logic beyond pausing during a dither.
//!     A mount slew (meridian flip, recenter) is not gated by this barrier in
//!     v1; the operator is expected to keep secondary exposures short relative
//!     to flip cadence. (Documented gap — see report.)

use crate::device_ops::SharedDeviceOps;
use crate::scheduling::FrameContext;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Notify;

/// Policy for what to do with an in-flight secondary exposure when the primary
/// announces a pending dither.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum InFlightDitherPolicy {
    /// Let the in-flight exposure FINISH if it will complete within the
    /// barrier's max-wait window; otherwise abort it. This is the default —
    /// short subs complete (no wasted frame), long subs get aborted so the
    /// primary is never stalled.
    #[default]
    CompleteIfShort,
    /// Always abort the in-flight secondary exposure immediately when a dither
    /// is announced. Maximizes primary throughput at the cost of discarding the
    /// partial secondary frame.
    AbortImmediately,
}

impl InFlightDitherPolicy {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::CompleteIfShort => "complete_if_short",
            Self::AbortImmediately => "abort_immediately",
        }
    }

    pub fn from_str_opt(s: &str) -> Option<Self> {
        match s {
            "complete_if_short" => Some(Self::CompleteIfShort),
            "abort_immediately" => Some(Self::AbortImmediately),
            _ => None,
        }
    }
}

/// Shared dither-coordination barrier between the primary sequence and the
/// secondary capture loop.
///
/// Lifecycle of a single dither, from the primary's side:
/// ```text
/// barrier.begin_dither()              // sets dither_pending = true
/// barrier.wait_for_secondary_clear()  // blocks until secondary not exposing
///                                      // OR max_wait elapses (then logs + proceeds)
/// <pulse the guider + settle>          // mount moves; secondary stays parked
/// barrier.end_dither()                 // clears dither_pending, wakes secondary
/// ```
///
/// From the secondary's side, before EACH exposure:
/// ```text
/// barrier.wait_until_clear_to_expose() // blocks while a dither is pending
/// barrier.mark_exposure_started()      // sets exposing = true
/// <capture>
/// barrier.mark_exposure_finished()     // sets exposing = false
/// ```
///
/// All flags are atomics + a `Notify` so neither side holds a lock across an
/// `.await`. A single barrier instance is shared via `Arc` between the
/// `ExecutionContext` (primary) and the `SecondaryRig` task.
#[derive(Debug)]
pub struct DitherBarrier {
    /// The primary has announced a dither and is about to (or is currently)
    /// pulsing the mount. While true the secondary must not START a new
    /// exposure.
    dither_pending: AtomicBool,
    /// The secondary currently has an exposure in flight.
    secondary_exposing: AtomicBool,
    /// When the in-flight secondary exposure is expected to finish, as a unix
    /// epoch in milliseconds. 0 = no in-flight exposure / unknown.
    secondary_expected_finish_ms: AtomicU64,
    /// Wakes the secondary loop when a dither completes (`end_dither`).
    resume_secondary: Notify,
    /// Wakes the primary when the secondary finishes its in-flight exposure.
    secondary_cleared: Notify,
    /// Maximum time (ms) the primary will wait for the secondary to clear
    /// before proceeding with the dither anyway. Guarantees a stuck secondary
    /// can never stall the primary indefinitely.
    max_wait_ms: AtomicU64,
    /// Policy for an in-flight exposure when a dither is announced.
    abort_in_flight: AtomicBool,
    /// Diagnostics: how many times the primary had to proceed past max-wait
    /// with the secondary still (apparently) exposing.
    forced_proceeds: AtomicU32,
    /// Diagnostics: how many in-flight secondary exposures were aborted for a
    /// dither.
    aborted_exposures: AtomicU32,
}

/// Default ceiling on how long the primary waits for the secondary to clear.
pub const DEFAULT_DITHER_MAX_WAIT_SECS: f64 = 30.0;

impl DitherBarrier {
    /// Build a barrier. `max_wait_secs` bounds how long the primary blocks for
    /// the secondary; `policy` decides the in-flight-exposure handling.
    pub fn new(max_wait_secs: f64, policy: InFlightDitherPolicy) -> Self {
        let max_wait_ms = (max_wait_secs.max(0.0) * 1000.0) as u64;
        Self {
            dither_pending: AtomicBool::new(false),
            secondary_exposing: AtomicBool::new(false),
            secondary_expected_finish_ms: AtomicU64::new(0),
            resume_secondary: Notify::new(),
            secondary_cleared: Notify::new(),
            max_wait_ms: AtomicU64::new(max_wait_ms),
            abort_in_flight: AtomicBool::new(policy == InFlightDitherPolicy::AbortImmediately),
            forced_proceeds: AtomicU32::new(0),
            aborted_exposures: AtomicU32::new(0),
        }
    }

    pub fn max_wait_secs(&self) -> f64 {
        self.max_wait_ms.load(Ordering::Relaxed) as f64 / 1000.0
    }

    pub fn policy(&self) -> InFlightDitherPolicy {
        if self.abort_in_flight.load(Ordering::Relaxed) {
            InFlightDitherPolicy::AbortImmediately
        } else {
            InFlightDitherPolicy::CompleteIfShort
        }
    }

    pub fn is_dither_pending(&self) -> bool {
        self.dither_pending.load(Ordering::Acquire)
    }

    pub fn is_secondary_exposing(&self) -> bool {
        self.secondary_exposing.load(Ordering::Acquire)
    }

    pub fn forced_proceed_count(&self) -> u32 {
        self.forced_proceeds.load(Ordering::Relaxed)
    }

    pub fn aborted_exposure_count(&self) -> u32 {
        self.aborted_exposures.load(Ordering::Relaxed)
    }

    fn now_ms() -> u64 {
        use std::time::{SystemTime, UNIX_EPOCH};
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0)
    }

    // Primary side

    /// PRIMARY: announce that a dither is about to happen. Returns immediately;
    /// after this the secondary will not start a new exposure until
    /// [`Self::end_dither`].
    pub fn begin_dither(&self) {
        self.dither_pending.store(true, Ordering::Release);
    }

    /// PRIMARY: wait for the secondary to be clear of any in-flight exposure
    /// before pulsing the mount. Returns `true` if the secondary cleared
    /// cleanly, `false` if the max-wait elapsed and the primary is proceeding
    /// anyway (logged by the caller). Honors the in-flight policy: under
    /// [`InFlightDitherPolicy::AbortImmediately`] this requests an abort and
    /// returns as soon as the secondary acknowledges (or max-wait).
    ///
    /// Must be called AFTER [`Self::begin_dither`] so the secondary has already
    /// stopped launching new exposures.
    pub async fn wait_for_secondary_clear(&self) -> bool {
        if !self.secondary_exposing.load(Ordering::Acquire) {
            return true;
        }

        let abort = self.abort_in_flight.load(Ordering::Relaxed);
        let max_wait_ms = self.max_wait_ms.load(Ordering::Relaxed);

        // Under CompleteIfShort, if the in-flight exposure will not finish
        // within the remaining budget, fall through to an abort request so the
        // primary is not stalled. The secondary loop checks `dither_pending`
        // when deciding whether to honor the abort.
        let deadline_ms = Self::now_ms().saturating_add(max_wait_ms);

        loop {
            if !self.secondary_exposing.load(Ordering::Acquire) {
                return true;
            }

            let now = Self::now_ms();
            if now >= deadline_ms {
                // Bounded wait exhausted — proceed regardless. A stuck
                // secondary can NEVER stall the primary indefinitely.
                self.forced_proceeds.fetch_add(1, Ordering::Relaxed);
                return false;
            }

            let remaining = Duration::from_millis(deadline_ms - now);

            if abort {
                // Signal the secondary loop to abort its current exposure. The
                // loop polls `should_abort_in_flight()` between download steps;
                // we just wait for it to flip `secondary_exposing` to false.
                self.aborted_exposures.fetch_add(1, Ordering::Relaxed);
            } else {
                // CompleteIfShort: if the expected finish is past our deadline,
                // request an abort instead of waiting the full sub out.
                let expected = self.secondary_expected_finish_ms.load(Ordering::Relaxed);
                if expected != 0 && expected > deadline_ms {
                    self.aborted_exposures.fetch_add(1, Ordering::Relaxed);
                }
            }

            // Wait for the secondary to announce it cleared, bounded by the
            // remaining budget so a missed notification still times out.
            let _ = tokio::time::timeout(remaining, self.secondary_cleared.notified()).await;
        }
    }

    /// PRIMARY: dither + settle is complete; release the secondary so it can
    /// resume its loop.
    pub fn end_dither(&self) {
        self.dither_pending.store(false, Ordering::Release);
        self.resume_secondary.notify_waiters();
    }

    // Secondary side

    /// SECONDARY: block until it is safe to start a new exposure (no dither
    /// pending). Also returns early if `cancel` flips true.
    pub async fn wait_until_clear_to_expose(&self, cancel: &AtomicBool) {
        while self.dither_pending.load(Ordering::Acquire) && !cancel.load(Ordering::Relaxed) {
            // Re-check after registering the waiter to avoid a lost wakeup.
            let notified = self.resume_secondary.notified();
            if !self.dither_pending.load(Ordering::Acquire) || cancel.load(Ordering::Relaxed) {
                break;
            }
            // Bounded so a cancel that races `end_dither` still wakes us.
            let _ = tokio::time::timeout(Duration::from_millis(250), notified).await;
        }
    }

    /// SECONDARY: mark an exposure as started. `expected_duration_secs` lets
    /// the primary's CompleteIfShort policy decide whether to wait it out.
    pub fn mark_exposure_started(&self, expected_duration_secs: f64) {
        let finish_ms =
            Self::now_ms().saturating_add((expected_duration_secs.max(0.0) * 1000.0) as u64);
        self.secondary_expected_finish_ms
            .store(finish_ms, Ordering::Relaxed);
        self.secondary_exposing.store(true, Ordering::Release);
    }

    /// SECONDARY: mark the in-flight exposure as finished (or aborted). Wakes
    /// any primary waiting in [`Self::wait_for_secondary_clear`].
    pub fn mark_exposure_finished(&self) {
        self.secondary_expected_finish_ms
            .store(0, Ordering::Relaxed);
        self.secondary_exposing.store(false, Ordering::Release);
        self.secondary_cleared.notify_waiters();
    }

    /// SECONDARY: should the in-flight exposure be aborted right now to let the
    /// primary dither? True when a dither is pending AND either the policy is
    /// AbortImmediately or the (already-started) sub will run past the primary's
    /// patience window.
    pub fn should_abort_in_flight(&self) -> bool {
        if !self.dither_pending.load(Ordering::Acquire) {
            return false;
        }
        if self.abort_in_flight.load(Ordering::Relaxed) {
            return true;
        }
        // CompleteIfShort: abort only if the sub will overshoot max-wait.
        let max_wait_ms = self.max_wait_ms.load(Ordering::Relaxed);
        let expected = self.secondary_expected_finish_ms.load(Ordering::Relaxed);
        expected != 0 && expected > Self::now_ms().saturating_add(max_wait_ms)
    }
}

// Process-wide active-barrier slot.
//
// The bridge's secondary-rig manager installs a barrier here when a secondary
// rig is armed; the executor's `start()` reads it when building the
// `ExecutionContext` so the primary's dither call sites coordinate with the
// secondary loop. Mirrors the `crate::broadcast` single-slot pattern: only one
// secondary rig can be active at a time (one mount, one barrier). `None` =
// single-rig (the common case) and every dither is a plain pass-through.

fn barrier_slot() -> &'static parking_lot::Mutex<Option<Arc<DitherBarrier>>> {
    static SLOT: std::sync::OnceLock<parking_lot::Mutex<Option<Arc<DitherBarrier>>>> =
        std::sync::OnceLock::new();
    SLOT.get_or_init(|| parking_lot::Mutex::new(None))
}

/// Install (or replace) the process-wide active dither barrier. Returns the
/// previously-active barrier, if any.
pub fn install_active_barrier(barrier: Arc<DitherBarrier>) -> Option<Arc<DitherBarrier>> {
    let mut g = barrier_slot().lock();
    g.replace(barrier)
}

/// Snapshot the currently-active dither barrier, or `None` (single-rig).
pub fn active_barrier() -> Option<Arc<DitherBarrier>> {
    barrier_slot().lock().clone()
}

/// Tear down the active barrier (called when the secondary rig stops or the
/// sequence ends). Returns the removed barrier, if any.
pub fn clear_active_barrier() -> Option<Arc<DitherBarrier>> {
    barrier_slot().lock().take()
}

/// Configuration for the secondary capture loop.
#[derive(Debug, Clone)]
pub struct SecondaryRigConfig {
    /// Device id of the secondary camera (a SECOND, already-connected camera —
    /// distinct from the primary's `camera_id`).
    pub camera_id: String,
    /// Exposure duration per secondary sub, in seconds.
    pub exposure_secs: f64,
    pub gain: Option<i32>,
    pub offset: Option<i32>,
    pub bin_x: i32,
    pub bin_y: i32,
    /// Number of frames to capture. `None` => run until the primary sequence
    /// ends (the loop is stopped externally via the cancel flag).
    pub frame_count: Option<u32>,
    /// Optional fixed filter name to stamp into the secondary frames' metadata.
    /// The secondary has no filter wheel control in v1, so this is descriptive
    /// only.
    pub filter_name: Option<String>,
    /// Cooler target temperature (°C). `None` => leave cooler as-is.
    pub target_temp_c: Option<f64>,
    /// Human label for this rig, used in the saved sub-folder + FITS log line.
    pub rig_label: String,
    /// Secondary camera identification, stamped into FITS so subs are
    /// attributable to the right optical train.
    pub camera_make: Option<String>,
    pub camera_model: Option<String>,
    pub telescope_name: Option<String>,
    pub telescope_focal_length_mm: Option<f64>,
    pub telescope_aperture_mm: Option<f64>,
}

impl SecondaryRigConfig {
    pub fn new(camera_id: impl Into<String>, exposure_secs: f64) -> Self {
        Self {
            camera_id: camera_id.into(),
            exposure_secs,
            gain: None,
            offset: None,
            bin_x: 1,
            bin_y: 1,
            frame_count: None,
            filter_name: None,
            target_temp_c: None,
            rig_label: "Secondary".to_string(),
            camera_make: None,
            camera_model: None,
            telescope_name: None,
            telescope_focal_length_mm: None,
            telescope_aperture_mm: None,
        }
    }
}

/// Live status snapshot of the secondary rig, surfaced to the UI / headless API.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SecondaryRigStatus {
    pub running: bool,
    pub camera_id: Option<String>,
    pub rig_label: String,
    pub frames_captured: u32,
    pub frames_aborted: u32,
    pub planned_frames: Option<u32>,
    /// True while parked waiting for a primary dither to finish.
    pub waiting_for_dither: bool,
    /// True while an exposure is in flight.
    pub exposing: bool,
    pub last_error: Option<String>,
}

/// Shared, observable state owned by a running [`SecondaryRig`] loop.
#[derive(Debug)]
pub struct SecondaryRigState {
    pub running: AtomicBool,
    pub cancel: AtomicBool,
    pub frames_captured: AtomicU32,
    pub frames_aborted: AtomicU32,
    pub exposing: AtomicBool,
    pub waiting_for_dither: AtomicBool,
    pub last_error: parking_lot::Mutex<Option<String>>,
    pub config: SecondaryRigConfig,
}

impl SecondaryRigState {
    fn new(config: SecondaryRigConfig) -> Self {
        Self {
            running: AtomicBool::new(false),
            cancel: AtomicBool::new(false),
            frames_captured: AtomicU32::new(0),
            frames_aborted: AtomicU32::new(0),
            exposing: AtomicBool::new(false),
            waiting_for_dither: AtomicBool::new(false),
            last_error: parking_lot::Mutex::new(None),
            config,
        }
    }

    pub fn snapshot(&self) -> SecondaryRigStatus {
        SecondaryRigStatus {
            running: self.running.load(Ordering::Acquire),
            camera_id: Some(self.config.camera_id.clone()),
            rig_label: self.config.rig_label.clone(),
            frames_captured: self.frames_captured.load(Ordering::Relaxed),
            frames_aborted: self.frames_aborted.load(Ordering::Relaxed),
            planned_frames: self.config.frame_count,
            waiting_for_dither: self.waiting_for_dither.load(Ordering::Acquire),
            exposing: self.exposing.load(Ordering::Acquire),
            last_error: self.last_error.lock().clone(),
        }
    }
}

/// The secondary capture-loop driver.
///
/// Construct with [`SecondaryRig::start`], which spawns the loop on the current
/// tokio runtime and returns a handle whose [`SecondaryRig::state`] is the live
/// observable state. Stop with [`SecondaryRig::stop`] (cooperative cancel).
pub struct SecondaryRig {
    state: Arc<SecondaryRigState>,
    handle: tokio::task::JoinHandle<Result<(), String>>,
}

/// Metadata the primary passes to the secondary so frames inherit the right
/// target identity + save location.
#[derive(Debug, Clone, Default)]
pub struct SecondaryFrameMeta {
    pub session_id: String,
    pub target_name: Option<String>,
    pub target_id: Option<String>,
    pub target_ra_hours: Option<f64>,
    pub target_dec_degrees: Option<f64>,
    pub observer_name: Option<String>,
    pub site_latitude_deg: Option<f64>,
    pub site_longitude_deg: Option<f64>,
    pub site_elevation_m: Option<f64>,
    /// Base directory the primary is saving into. The secondary saves into a
    /// `<base>/<rig_label>/` subfolder so the two rigs' subs never collide.
    pub save_base: Option<std::path::PathBuf>,
}

impl SecondaryRig {
    /// Spawn the secondary capture loop. The loop runs until the frame count is
    /// reached, the cancel flag is set, or a fatal device error occurs.
    pub fn start(
        config: SecondaryRigConfig,
        device_ops: SharedDeviceOps,
        barrier: Arc<DitherBarrier>,
        meta: SecondaryFrameMeta,
    ) -> Self {
        let state = Arc::new(SecondaryRigState::new(config));
        let loop_state = state.clone();
        let handle = tokio::spawn(async move {
            loop_state.running.store(true, Ordering::Release);
            let result = run_secondary_loop(loop_state.clone(), device_ops, barrier, meta).await;
            if let Err(error) = &result {
                *loop_state.last_error.lock() = Some(error.clone());
            }
            loop_state.running.store(false, Ordering::Release);
            loop_state.exposing.store(false, Ordering::Release);
            loop_state
                .waiting_for_dither
                .store(false, Ordering::Release);
            result
        });
        Self { state, handle }
    }

    pub fn state(&self) -> Arc<SecondaryRigState> {
        self.state.clone()
    }

    pub fn status(&self) -> SecondaryRigStatus {
        self.state.snapshot()
    }

    /// Request a cooperative stop. Returns the JoinHandle so the caller can
    /// await full teardown if desired.
    pub fn stop(self) -> tokio::task::JoinHandle<Result<(), String>> {
        self.state.cancel.store(true, Ordering::Release);
        self.handle
    }
}

/// The actual secondary capture loop body. Extracted as a free fn so it is
/// directly unit-testable with a mock `DeviceOps`.
pub async fn run_secondary_loop(
    state: Arc<SecondaryRigState>,
    device_ops: SharedDeviceOps,
    barrier: Arc<DitherBarrier>,
    meta: SecondaryFrameMeta,
) -> Result<(), String> {
    let config = state.config.clone();

    // One-time cooler set, best-effort. A cooler failure is non-fatal for the
    // secondary — log it and keep going (uncooled subs are still usable).
    if let Some(target) = config.target_temp_c {
        if let Err(e) = device_ops
            .camera_set_cooler(&config.camera_id, true, target)
            .await
        {
            tracing::warn!(
                "Secondary rig '{}': cooler set failed (continuing uncooled): {}",
                config.rig_label,
                e
            );
            *state.last_error.lock() = Some(format!("cooler: {e}"));
        }
    }

    let save_base = meta.save_base.as_ref().ok_or_else(|| {
        "secondary rig has no save directory; refusing to write into the process directory"
            .to_string()
    })?;
    let safe_rig_dir = sanitize_component(&config.rig_label);
    let save_dir = save_base.join(if safe_rig_dir.is_empty() {
        "Secondary"
    } else {
        &safe_rig_dir
    });
    tokio::fs::create_dir_all(&save_dir).await.map_err(|e| {
        format!(
            "cannot create secondary-rig save directory {}: {e}",
            save_dir.display()
        )
    })?;

    let mut frame_index: u32 = 0;
    let mut consecutive_failures: u8 = 0;
    loop {
        if state.cancel.load(Ordering::Relaxed) {
            break;
        }
        if let Some(total) = config.frame_count {
            if frame_index >= total {
                break;
            }
        }

        // Barrier gate: do not start a new exposure while a primary dither is
        // pending. The secondary parks here until the primary releases it.
        state.waiting_for_dither.store(true, Ordering::Release);
        barrier.wait_until_clear_to_expose(&state.cancel).await;
        state.waiting_for_dither.store(false, Ordering::Release);
        if state.cancel.load(Ordering::Relaxed) {
            break;
        }

        frame_index += 1;
        barrier.mark_exposure_started(config.exposure_secs);
        state.exposing.store(true, Ordering::Release);

        let result = capture_secondary_frame(
            &config,
            &device_ops,
            &barrier,
            &state.cancel,
            &meta,
            &save_dir,
            frame_index,
        )
        .await;

        state.exposing.store(false, Ordering::Release);
        barrier.mark_exposure_finished();

        match result {
            Ok(SecondaryFrameOutcome::Saved) => {
                state.frames_captured.fetch_add(1, Ordering::Relaxed);
                consecutive_failures = 0;
            }
            Ok(SecondaryFrameOutcome::Aborted) => {
                state.frames_aborted.fetch_add(1, Ordering::Relaxed);
                // The aborted frame still counts against an explicit frame
                // budget? No — re-take it so `frame_count` means "good subs".
                frame_index = frame_index.saturating_sub(1);
            }
            Ok(SecondaryFrameOutcome::Cancelled) => {
                state.frames_aborted.fetch_add(1, Ordering::Relaxed);
                break;
            }
            Err(e) => {
                tracing::error!(
                    "Secondary rig '{}': capture failed (frame {}): {}",
                    config.rig_label,
                    frame_index,
                    e
                );
                *state.last_error.lock() = Some(e.clone());
                frame_index = frame_index.saturating_sub(1);
                consecutive_failures = consecutive_failures.saturating_add(1);
                if state.cancel.load(Ordering::Relaxed) {
                    return Err(e);
                }
                if consecutive_failures >= 3 {
                    return Err(format!(
                        "secondary capture failed {consecutive_failures} consecutive times: {e}"
                    ));
                }
                // Back off briefly before retrying the same frame. A cancel
                // breaks the wait promptly.
                let _ = tokio::time::timeout(
                    Duration::from_secs(2),
                    barrier_or_cancel_wait(&state.cancel),
                )
                .await;
            }
        }
    }

    tracing::info!(
        "Secondary rig '{}' loop ended: {} captured, {} aborted",
        config.rig_label,
        state.frames_captured.load(Ordering::Relaxed),
        state.frames_aborted.load(Ordering::Relaxed)
    );
    Ok(())
}

async fn barrier_or_cancel_wait(cancel: &AtomicBool) {
    while !cancel.load(Ordering::Relaxed) {
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

enum SecondaryFrameOutcome {
    Saved,
    Aborted,
    Cancelled,
}

/// Capture + save one secondary frame. Honors the dither-abort policy: if a
/// dither is announced and the sub must be cut short, the exposure is aborted
/// and `Aborted` is returned (no frame written).
async fn capture_secondary_frame(
    config: &SecondaryRigConfig,
    device_ops: &SharedDeviceOps,
    barrier: &DitherBarrier,
    cancel: &AtomicBool,
    meta: &SecondaryFrameMeta,
    save_dir: &std::path::Path,
    frame_index: u32,
) -> Result<SecondaryFrameOutcome, String> {
    if cancel.load(Ordering::Acquire) {
        return Ok(SecondaryFrameOutcome::Cancelled);
    }
    // If a dither got announced between the gate check and here (race), and the
    // policy says abort, bail before even starting.
    if barrier.should_abort_in_flight() {
        return Ok(SecondaryFrameOutcome::Aborted);
    }

    // Start the exposure. `camera_start_exposure` blocks until the frame is
    // downloaded; for an abort we race it against an abort watcher.
    let exposure = device_ops.camera_start_exposure(
        &config.camera_id,
        config.exposure_secs,
        config.gain,
        config.offset,
        config.bin_x,
        config.bin_y,
    );
    tokio::pin!(exposure);

    let image = loop {
        tokio::select! {
            res = &mut exposure => {
                break res.map_err(|e| format!("exposure failed: {e}"))?;
            }
            _ = tokio::time::sleep(Duration::from_millis(100)) => {
                if cancel.load(Ordering::Acquire) {
                    device_ops
                        .camera_abort_exposure(&config.camera_id)
                        .await
                        .map_err(|e| format!("failed to abort exposure while stopping: {e}"))?;
                    return Ok(SecondaryFrameOutcome::Cancelled);
                }
                if barrier.should_abort_in_flight() {
                    // Cut the sub short so the primary can dither. Best-effort
                    // abort; we still return Aborted regardless.
                    let _ = device_ops.camera_abort_exposure(&config.camera_id).await;
                    return Ok(SecondaryFrameOutcome::Aborted);
                }
            }
        }
    };

    // Build the frame context: primary's target identity + secondary's own
    // camera/optics metadata + a rig tag so frames are attributable.
    let mut ctx = FrameContext::new_light(
        meta.session_id.clone(),
        image.width.max(1),
        image.height.max(1),
        config.exposure_secs,
        frame_index,
    );
    ctx.binning_x = config.bin_x.max(1) as u32;
    ctx.binning_y = config.bin_y.max(1) as u32;
    ctx.gain = config.gain.or(image.gain);
    ctx.offset = config.offset.or(image.offset);
    ctx.total_planned_frames = config.frame_count;
    ctx.target_name = meta.target_name.clone();
    ctx.target_id = meta.target_id.clone();
    ctx.target_ra_hours = meta.target_ra_hours;
    ctx.target_dec_degrees = meta.target_dec_degrees;
    ctx.filter_name = config.filter_name.clone().or_else(|| image.filter.clone());
    ctx.sensor_temp_c = image.temperature;
    ctx.set_temp_c = config.target_temp_c;
    ctx.bayer_pattern = image
        .bayer_offset
        .and(image.sensor_type.clone())
        .filter(|_| image.sensor_type.as_deref() == Some("Color"))
        .map(|_| "RGGB".to_string());
    ctx.observer_name = meta.observer_name.clone();
    ctx.site_latitude_deg = meta.site_latitude_deg;
    ctx.site_longitude_deg = meta.site_longitude_deg;
    ctx.site_elevation_m = meta.site_elevation_m;
    ctx.camera_make = config.camera_make.clone();
    ctx.camera_model = config.camera_model.clone();
    ctx.telescope_name = config.telescope_name.clone();
    ctx.telescope_focal_length_mm = config.telescope_focal_length_mm;
    ctx.telescope_aperture_mm = config.telescope_aperture_mm;
    // Frame attribution: tag the rig so multi-rig sessions can split subs.
    ctx.rig_label = Some(config.rig_label.clone());

    let file_name =
        secondary_file_name(meta.target_name.as_deref(), &config.rig_label, frame_index);
    let full_path = save_dir.join(&file_name);
    let path_str = full_path.to_string_lossy().to_string();

    device_ops
        .save_fits(&image, &path_str, &ctx)
        .await
        .map_err(|e| format!("save_fits failed: {e}"))?;

    tracing::info!(
        "Secondary rig '{}' saved frame {} -> {}",
        config.rig_label,
        frame_index,
        path_str
    );
    Ok(SecondaryFrameOutcome::Saved)
}

fn secondary_file_name(target: Option<&str>, rig_label: &str, frame_index: u32) -> String {
    let safe_target = target
        .map(sanitize_component)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "Untitled".to_string());
    let safe_rig = sanitize_component(rig_label);
    format!("{safe_target}_{safe_rig}_{frame_index:04}.fits")
}

fn sanitize_component(s: &str) -> String {
    s.chars()
        .map(|c| {
            if c.is_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    #[tokio::test]
    async fn barrier_blocks_secondary_while_dither_pending() {
        let barrier = Arc::new(DitherBarrier::new(
            30.0,
            InFlightDitherPolicy::CompleteIfShort,
        ));
        let cancel = AtomicBool::new(false);
        barrier.begin_dither();

        // The secondary should block in wait_until_clear_to_expose until the
        // primary calls end_dither.
        let b2 = barrier.clone();
        let waiter = tokio::spawn(async move {
            let cancel = AtomicBool::new(false);
            let start = Instant::now();
            b2.wait_until_clear_to_expose(&cancel).await;
            start.elapsed()
        });

        tokio::time::sleep(Duration::from_millis(150)).await;
        assert!(
            !waiter.is_finished(),
            "secondary must stay blocked during dither"
        );
        barrier.end_dither();

        let elapsed = waiter.await.unwrap();
        assert!(elapsed >= Duration::from_millis(100));
        let _ = cancel;
    }

    #[tokio::test]
    async fn primary_proceeds_immediately_when_secondary_idle() {
        let barrier = DitherBarrier::new(30.0, InFlightDitherPolicy::CompleteIfShort);
        barrier.begin_dither();
        let cleared = barrier.wait_for_secondary_clear().await;
        assert!(cleared, "idle secondary => clear immediately");
        assert_eq!(barrier.forced_proceed_count(), 0);
        barrier.end_dither();
    }

    #[tokio::test]
    async fn in_flight_short_exposure_completes_before_dither() {
        let barrier = Arc::new(DitherBarrier::new(
            30.0,
            InFlightDitherPolicy::CompleteIfShort,
        ));
        // Secondary starts a 0.2s sub that will finish well within max-wait.
        barrier.mark_exposure_started(0.2);

        let b2 = barrier.clone();
        let finisher = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(200)).await;
            b2.mark_exposure_finished();
        });

        barrier.begin_dither();
        let start = Instant::now();
        let cleared = barrier.wait_for_secondary_clear().await;
        let waited = start.elapsed();
        finisher.await.unwrap();

        assert!(cleared, "short sub should clear within max-wait");
        assert_eq!(barrier.forced_proceed_count(), 0);
        // It actually waited for the sub to finish (~200ms), not proceeded early.
        assert!(waited >= Duration::from_millis(150));
        barrier.end_dither();
    }

    #[tokio::test]
    async fn primary_never_waits_beyond_max_wait_for_stuck_secondary() {
        // Short max-wait; secondary "stuck" (never finishes).
        let barrier = DitherBarrier::new(0.3, InFlightDitherPolicy::CompleteIfShort);
        barrier.mark_exposure_started(3600.0); // pretends to be a very long sub
        barrier.begin_dither();

        let start = Instant::now();
        let cleared = barrier.wait_for_secondary_clear().await;
        let waited = start.elapsed();

        assert!(
            !cleared,
            "must report forced-proceed when secondary never clears"
        );
        assert_eq!(barrier.forced_proceed_count(), 1);
        // Bounded: it gave up close to max_wait (0.3s), nowhere near 3600s.
        assert!(waited < Duration::from_secs(2), "waited {waited:?}");
    }

    #[tokio::test]
    async fn abort_immediately_policy_requests_abort_of_in_flight() {
        let barrier = DitherBarrier::new(30.0, InFlightDitherPolicy::AbortImmediately);
        barrier.mark_exposure_started(600.0);
        barrier.begin_dither();
        assert!(
            barrier.should_abort_in_flight(),
            "abort-immediately must request abort while dither pending"
        );
    }

    #[tokio::test]
    async fn complete_if_short_aborts_only_overshooting_subs() {
        let barrier = DitherBarrier::new(5.0, InFlightDitherPolicy::CompleteIfShort);
        // Sub finishes in 1s, well inside the 5s window: do NOT abort.
        barrier.mark_exposure_started(1.0);
        barrier.begin_dither();
        assert!(!barrier.should_abort_in_flight());

        // A 600s sub overshoots the 5s window: DO abort.
        barrier.mark_exposure_finished();
        barrier.mark_exposure_started(600.0);
        assert!(barrier.should_abort_in_flight());
    }

    #[test]
    fn file_name_is_sanitized_and_indexed() {
        let n = secondary_file_name(Some("M 31 / Andromeda"), "Wide Field", 7);
        assert_eq!(n, "M_31___Andromeda_Wide_Field_0007.fits");
    }

    #[test]
    fn policy_round_trips_through_string() {
        for p in [
            InFlightDitherPolicy::CompleteIfShort,
            InFlightDitherPolicy::AbortImmediately,
        ] {
            assert_eq!(InFlightDitherPolicy::from_str_opt(p.as_str()), Some(p));
        }
        assert_eq!(InFlightDitherPolicy::from_str_opt("nonsense"), None);
    }
}
