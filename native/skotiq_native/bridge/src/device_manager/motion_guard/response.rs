//! What the guard does about a finding, and the operator's ways out.

use std::time::Duration;

use super::{config, now, unix_now, with_registry, FaultRecord, LostRecord};
use crate::device_manager::motion_guard::detector::{Finding, LostReason, MotionKind};
use crate::event::equipment::EventSeverity;
use crate::event::system::SafetyEvent;

/// Rounds of stop commands the guard sends to a mount that keeps moving.
const STOP_ROUNDS: u32 = 3;

/// Time between stop rounds.
const STOP_ROUND_GAP: Duration = Duration::from_secs(4);

/// How often an open fault or unknown position is announced again.
const REMINDER_SECS: f64 = 15.0 * 60.0;

/// An automatic recovery waits this long after the mount has stopped.
const AUTO_RECOVERY_QUIET: Duration = Duration::from_secs(30);

fn publish(event: SafetyEvent, severity: EventSeverity) {
    crate::state::get_state().publish_safety_event(event, severity);
}

fn position_text(ra_hours: f64, dec_deg: f64, altitude_deg: Option<f64>) -> String {
    match altitude_deg {
        Some(alt) => format!("RA {ra_hours:.2}h, Dec {dec_deg:+.1}, altitude {alt:+.1}"),
        None => format!("RA {ra_hours:.2}h, Dec {dec_deg:+.1}"),
    }
}

fn motion_message(kind: MotionKind, rate: f64, position: &str) -> String {
    match kind {
        MotionKind::Runaway => format!(
            "The mount moved at {rate:.1} degrees per second with no command from Skotiq. When \
             it was caught it reported {position}."
        ),
        MotionKind::Slewing => format!(
            "The mount reported a slew Skotiq did not command. When it was caught it reported \
             {position}."
        ),
        MotionKind::BelowHorizon => format!(
            "The mount dropped below the horizon with no command from Skotiq. When it was \
             caught it reported {position}."
        ),
    }
}

/// Act on one finding from the detector.
///
/// Boxed because the response sends mount commands, whose status reads feed
/// the guard again: the future type would otherwise contain itself.
pub(crate) fn handle_finding(
    device_id: String,
    finding: Finding,
    run_active: bool,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> {
    Box::pin(async move {
        match finding {
            Finding::Motion {
                kind,
                rate_deg_per_sec,
            } => on_motion(&device_id, kind, rate_deg_per_sec, run_active).await,
            Finding::Stopped => on_stopped(&device_id),
            Finding::Danger(reason) => on_danger(&device_id, reason, run_active).await,
            Finding::PositionLost(reason) => on_position_lost(&device_id, reason, run_active).await,
        }
    })
}

/// Uncommanded motion started. With no run active it is left alone and not
/// announced: it may be someone using the mount's own software or hand
/// controller, and Skotiq does not know why the mount is moving. During a run
/// it pauses the run (frames from a moving mount are worthless) and is
/// announced. Neither case sends stop commands; only a dive below the altitude
/// limit does (see [`on_danger`]).
async fn on_motion(device_id: &str, kind: MotionKind, rate: f64, run_active: bool) {
    if !run_active {
        with_registry(|r| {
            r.mounts
                .entry(device_id.to_string())
                .or_default()
                .unrecorded_motion = Some((kind, rate));
        });
        tracing::info!(
            "[MOTION GUARD] {device_id}: moving with no command from Skotiq at {rate:.1} deg/s \
             and no run is active; left alone unless it heads below the altitude limit"
        );
        return;
    }
    let Some(message) = record_fault(device_id, kind, rate) else {
        return;
    };
    let device_id = device_id.to_string();
    tokio::spawn(async move {
        let paused = hold_run_or_stop_guiding(&message).await;
        with_registry(|r| {
            if let Some(fault) = r.mounts.get_mut(&device_id).and_then(|e| e.fault.as_mut()) {
                fault.run_paused = paused;
            }
        });
        announce_fault_update(&device_id);
        if paused {
            maybe_auto_recover(device_id).await;
        }
    });
}

/// Record a motion fault and announce it. Returns the message for a new
/// fault, `None` when one was already open.
fn record_fault(device_id: &str, kind: MotionKind, rate: f64) -> Option<String> {
    let sample = with_registry(|r| r.mounts.get(device_id).and_then(|e| e.detector.last()))?;
    let position = position_text(sample.ra_hours, sample.dec_deg, sample.altitude_deg);
    let message = motion_message(kind, rate, &position);
    let first = with_registry(|r| {
        let entry = r.mounts.entry(device_id.to_string()).or_default();
        if entry.fault.is_some() {
            return false;
        }
        entry.unrecorded_motion = None;
        entry.fault = Some(FaultRecord {
            kind,
            message: message.clone(),
            detected_at_unix: unix_now(),
            rate_deg_per_sec: rate,
            ra_hours: sample.ra_hours,
            dec_deg: sample.dec_deg,
            altitude_deg: sample.altitude_deg,
            still_moving: true,
            stop_attempts: Vec::new(),
            run_paused: false,
        });
        entry.last_reminder = Some(now());
        true
    });
    if !first {
        return None;
    }
    tracing::error!("[MOTION GUARD] {device_id}: {message}");
    publish(
        SafetyEvent::MountMotionFault {
            device_id: device_id.to_string(),
            kind: kind.as_wire().to_string(),
            message: message.clone(),
        },
        EventSeverity::Critical,
    );
    Some(message)
}

/// Uncommanded motion is taking the mount below its altitude limit: the one
/// case Skotiq stops a mount it did not command, run or no run.
async fn on_danger(device_id: &str, reason: String, run_active: bool) {
    // Motion left alone while idle becomes a fault now.
    let pending = with_registry(|r| {
        r.mounts
            .get_mut(device_id)
            .and_then(|e| e.unrecorded_motion.take())
    });
    let new_fault = match pending {
        Some((kind, rate)) => record_fault(device_id, kind, rate),
        None => None,
    };
    with_registry(|r| {
        if let Some(fault) = r.mounts.get_mut(device_id).and_then(|e| e.fault.as_mut()) {
            fault.message = format!("{} {reason}", fault.message);
        }
    });
    tracing::error!("[MOTION GUARD] {device_id}: heading below the altitude limit: {reason}");
    let device_id = device_id.to_string();
    tokio::spawn(async move {
        stop_round(&device_id, 1).await;
        if new_fault.is_some() {
            let paused = if run_active {
                hold_run_or_stop_guiding(&reason).await
            } else {
                stop_guiding().await;
                false
            };
            with_registry(|r| {
                if let Some(fault) = r.mounts.get_mut(&device_id).and_then(|e| e.fault.as_mut()) {
                    fault.run_paused = paused;
                }
            });
        }
        for round in 2..=STOP_ROUNDS {
            tokio::time::sleep(STOP_ROUND_GAP).await;
            if !still_moving(&device_id) {
                break;
            }
            stop_round(&device_id, round).await;
        }
        announce_fault_update(&device_id);
    });
}

fn still_moving(device_id: &str) -> bool {
    with_registry(|r| {
        r.mounts
            .get(device_id)
            .is_some_and(|e| e.detector.fault_moving())
    })
}

/// Send every stop command a mount understands and record how each went.
/// The mount's own `Abort` and MoveAxis 0 did not stop the NYX-101, so all of
/// them are sent, tracking off last.
async fn stop_round(device_id: &str, round: u32) {
    with_registry(|r| {
        if let Some(entry) = r.mounts.get_mut(device_id) {
            entry.responding = true;
        }
    });
    let manager = crate::device_manager::get_device_manager();
    let mut results = Vec::new();
    let mut note = |what: &str, result: Result<(), String>| {
        results.push(match result {
            Ok(()) => format!("Round {round}: {what} sent"),
            Err(e) => format!("Round {round}: {what} failed: {e}"),
        });
    };
    note("Abort slew", bounded(manager.mount_abort(device_id)).await);
    note(
        "MoveAxis 0 on RA",
        bounded(manager.mount_move_axis(device_id, 0, 0.0)).await,
    );
    note(
        "MoveAxis 0 on Dec",
        bounded(manager.mount_move_axis(device_id, 1, 0.0)).await,
    );
    note(
        "Tracking off",
        bounded(manager.mount_set_tracking(device_id, false)).await,
    );
    tracing::warn!("[MOTION GUARD] {device_id}: {}", results.join("; "));
    with_registry(|r| {
        if let Some(entry) = r.mounts.get_mut(device_id) {
            entry.responding = false;
            if let Some(fault) = entry.fault.as_mut() {
                fault.stop_attempts.extend(results);
            }
        }
    });
}

/// A stop command that gets five seconds to answer.
async fn bounded<E: std::fmt::Display>(
    command: impl std::future::Future<Output = Result<(), E>>,
) -> Result<(), String> {
    match tokio::time::timeout(Duration::from_secs(5), command).await {
        Ok(Ok(())) => Ok(()),
        Ok(Err(e)) => Err(e.to_string()),
        Err(_) => Err("no answer in 5 s".to_string()),
    }
}

/// Pause the run for the fault, which also stops its guiding; with no run,
/// stop the guider directly. Returns whether a run was paused. The run
/// announces its own pause when its state turns Paused.
async fn hold_run_or_stop_guiding(message: &str) -> bool {
    let held = {
        let executor = skotiq_sequencer::get_executor().read().await;
        executor.hold_for_mount_fault(message).await
    };
    match held {
        Ok(true) => true,
        Ok(false) => {
            stop_guiding().await;
            false
        }
        Err(e) => {
            tracing::error!("[MOTION GUARD] Could not pause the run: {e}");
            stop_guiding().await;
            false
        }
    }
}

async fn stop_guiding() {
    let ops = crate::unified_device_ops::create_unified_device_ops();
    if matches!(ops.guider_is_active().await, Ok(true)) {
        ops.guider_note_stop_reason(Some(skotiq_sequencer::GuidingStopReason::MountFault))
            .await;
        if let Err(e) = ops.guider_stop().await {
            tracing::warn!("[MOTION GUARD] The guider did not stop: {e}");
        }
    }
}

fn announce_fault_update(device_id: &str) {
    let Some(fault) = with_registry(|r| r.mounts.get(device_id).and_then(|e| e.fault.clone()))
    else {
        return;
    };
    let mut message = fault.message.clone();
    match (fault.still_moving, fault.stop_attempts.is_empty()) {
        (true, false) => {
            message.push_str(" It was still moving after every stop command Skotiq has.")
        }
        (true, true) => message.push_str(
            " Skotiq has not tried to stop it: it is not heading below the altitude limit, and \
             it may be someone moving the mount from outside Skotiq.",
        ),
        (false, _) => message.push_str(" It has stopped."),
    }
    if fault.run_paused {
        message.push_str(" The run is paused.");
    }
    publish(
        SafetyEvent::MountMotionFault {
            device_id: device_id.to_string(),
            kind: fault.kind.as_wire().to_string(),
            message,
        },
        EventSeverity::Critical,
    );
}

fn on_stopped(device_id: &str) {
    let stopped = with_registry(|r| {
        let Some(entry) = r.mounts.get_mut(device_id) else {
            return false;
        };
        entry.stopping = false;
        entry.unrecorded_motion = None;
        entry
            .fault
            .as_mut()
            .map(|f| {
                f.still_moving = false;
            })
            .is_some()
    });
    if stopped {
        tracing::warn!("[MOTION GUARD] {device_id}: the uncommanded motion has stopped");
        announce_fault_update(device_id);
    }
}

async fn on_position_lost(device_id: &str, reason: LostReason, run_active: bool) {
    let message = reason.describe();
    let first = with_registry(|r| {
        let entry = r.mounts.entry(device_id.to_string()).or_default();
        if entry.lost.is_some() {
            return false;
        }
        entry.lost = Some(LostRecord {
            reason: reason.clone(),
            message: message.clone(),
            flagged_at_unix: unix_now(),
            run_paused: false,
        });
        entry.last_reminder = Some(now());
        true
    });
    if !first {
        return;
    }
    tracing::error!("[MOTION GUARD] {device_id}: position unknown: {message}");
    publish(
        SafetyEvent::MountPositionUnknown {
            device_id: device_id.to_string(),
            reason: reason.as_wire().to_string(),
            message: message.clone(),
        },
        EventSeverity::Critical,
    );
    let device_id = device_id.to_string();
    tokio::spawn(async move {
        let paused = if run_active {
            hold_run_or_stop_guiding(&format!("The mount's position is unknown. {message}")).await
        } else {
            false
        };
        with_registry(|r| {
            if let Some(lost) = r.mounts.get_mut(&device_id).and_then(|e| e.lost.as_mut()) {
                lost.run_paused = paused;
            }
        });
        if paused {
            maybe_auto_recover(device_id).await;
        }
    });
}

/// Announce open faults and unknown positions again on a slow cadence, so an
/// operator who missed the first alarm still hears about it.
pub(crate) async fn remind_open_faults() {
    let t = now();
    let due: Vec<(String, Option<FaultRecord>, Option<LostRecord>)> = with_registry(|r| {
        r.mounts
            .iter_mut()
            .filter(|(_, e)| e.fault.is_some() || e.lost.is_some())
            .filter(|(_, e)| e.last_reminder.is_none_or(|at| t - at >= REMINDER_SECS))
            .map(|(id, e)| {
                e.last_reminder = Some(t);
                (id.clone(), e.fault.clone(), e.lost.clone())
            })
            .collect()
    });
    for (device_id, fault, lost) in due {
        if let Some(lost) = lost {
            publish(
                SafetyEvent::MountPositionUnknown {
                    device_id: device_id.clone(),
                    reason: lost.reason.as_wire().to_string(),
                    message: format!("Still unknown. {}", lost.message),
                },
                EventSeverity::Critical,
            );
        } else if fault.is_some() {
            announce_fault_update(&device_id);
        }
    }
}

// The operator's ways out.

/// The operator has looked at the mount after a motion fault.
pub fn acknowledge_fault(device_id: &str) -> Result<(), String> {
    let result = with_registry(|r| {
        let Some(entry) = r.mounts.get_mut(device_id) else {
            return Ok(false);
        };
        if entry.detector.fault_moving() {
            return Err(
                "The mount is still moving. Stop it at the mount or cut its power first."
                    .to_string(),
            );
        }
        entry.detector.clear_fault();
        entry.stopping = false;
        Ok(entry.fault.take().is_some())
    })?;
    if result {
        publish(
            SafetyEvent::MountGuardCleared {
                device_id: device_id.to_string(),
                message: "The operator acknowledged the motion fault.".to_string(),
            },
            EventSeverity::Info,
        );
    }
    Ok(())
}

fn clear_position(device_id: &str, how: &str) {
    let cleared = with_registry(|r| {
        let Some(entry) = r.mounts.get_mut(device_id) else {
            return false;
        };
        let had = entry.lost.take().is_some() || entry.fault.is_some();
        entry.detector.clear_fault();
        entry.fault = None;
        entry.stopping = false;
        entry.unrecorded_motion = None;
        had
    });
    if cleared {
        tracing::info!("[MOTION GUARD] {device_id}: {how}");
        publish(
            SafetyEvent::MountGuardCleared {
                device_id: device_id.to_string(),
                message: how.to_string(),
            },
            EventSeverity::Info,
        );
    }
}

/// The operator has put the mount at its home position (by hand or in the
/// mount's own software) and says so. The mount's model is trusted again.
pub fn confirm_rehomed(device_id: &str) -> Result<(), String> {
    if with_registry(|r| {
        r.mounts
            .get(device_id)
            .is_some_and(|e| e.detector.fault_moving())
    }) {
        return Err("The mount is still moving.".to_string());
    }
    clear_position(
        device_id,
        "The operator confirmed the mount is at its home position.",
    );
    Ok(())
}

/// Sync the mount to a solved J2000 position as the recovery, then trust its
/// position again.
pub async fn recovery_sync(device_id: &str, ra_hours: f64, dec_deg: f64) -> Result<(), String> {
    if with_registry(|r| {
        r.mounts
            .get(device_id)
            .is_some_and(|e| e.detector.fault_moving())
    }) {
        return Err("The mount is still moving.".to_string());
    }
    with_registry(|r| {
        r.mounts
            .entry(device_id.to_string())
            .or_default()
            .recovery_sync = true;
    });
    let result = crate::device_manager::get_device_manager()
        .mount_sync(device_id, ra_hours, dec_deg)
        .await
        .map_err(|e| format!("The sync failed: {e}"));
    with_registry(|r| {
        if let Some(entry) = r.mounts.get_mut(device_id) {
            entry.recovery_sync = false;
        }
    });
    result?;
    clear_position(
        device_id,
        &format!(
            "The mount was synced to a plate solve (RA {ra_hours:.3}h, Dec {dec_deg:+.2}) and \
             its position is trusted again."
        ),
    );
    Ok(())
}

/// A plate solve taken for a recovery.
#[derive(Debug, Clone, PartialEq)]
pub struct RecoverySolve {
    pub ra_hours: f64,
    pub dec_deg: f64,
    pub mount_ra_hours: f64,
    pub mount_dec_deg: f64,
    pub separation_deg: f64,
}

/// The camera a recovery frame is taken with: the one asked for, the run's,
/// the profile's, or the only connected camera.
async fn recovery_camera(camera_id: Option<String>) -> Option<String> {
    if camera_id.is_some() {
        return camera_id;
    }
    let run_camera = skotiq_sequencer::get_executor().read().await.camera_id.clone();
    if run_camera.is_some() {
        return run_camera;
    }
    if let Some(id) = crate::state::get_state()
        .get_profile_device_id(crate::device::DeviceType::Camera)
        .await
    {
        return Some(id);
    }
    crate::device_manager::get_device_manager()
        .first_connected_device_id(crate::device::DeviceType::Camera)
        .await
}

/// Take a frame and plate solve it with no position hint (the mount's own
/// position is the thing in doubt).
pub async fn solve_for_recovery(
    device_id: &str,
    camera_id: Option<String>,
    exposure_secs: f64,
) -> Result<RecoverySolve, String> {
    let camera = recovery_camera(camera_id)
        .await
        .ok_or_else(|| "No camera is connected to take the recovery frame.".to_string())?;
    let ops = crate::unified_device_ops::create_unified_device_ops();
    let exposure = exposure_secs.clamp(0.5, 60.0);
    let image = ops
        .camera_start_exposure(skotiq_sequencer::ExposureRequest::new(&camera, exposure))
        .await
        .map_err(|e| format!("The recovery frame failed: {e}"))?;
    let solved = tokio::time::timeout(
        Duration::from_secs(180),
        ops.plate_solve(&image, None, None, None),
    )
    .await
    .map_err(|_| "The plate solve took longer than 3 minutes.".to_string())?
    .map_err(|e| format!("The plate solve failed: {e}"))?;
    if !solved.success {
        return Err("The frame did not plate solve. Check the sky and the focus.".to_string());
    }
    let status = crate::device_manager::get_device_manager()
        .mount_get_status(device_id)
        .await
        .map_err(|e| format!("The mount did not report its position: {e}"))?;
    let ra_hours = solved.ra_degrees / 15.0;
    let separation_deg = super::detector::separation_deg(
        (status.right_ascension, status.declination),
        (ra_hours, solved.dec_degrees),
    );
    Ok(RecoverySolve {
        ra_hours,
        dec_deg: solved.dec_degrees,
        mount_ra_hours: status.right_ascension,
        mount_dec_deg: status.declination,
        separation_deg,
    })
}

/// With the setting on, recover a held run without the operator: wait for the
/// mount to stay still, solve, sync, and resume.
async fn maybe_auto_recover(device_id: String) {
    if !config().auto_sync_resume {
        return;
    }
    let start = with_registry(|r| {
        let entry = r.mounts.entry(device_id.clone()).or_default();
        if entry.auto_recovering {
            false
        } else {
            entry.auto_recovering = true;
            true
        }
    });
    if !start {
        return;
    }
    let outcome = auto_recover(&device_id).await;
    with_registry(|r| {
        if let Some(entry) = r.mounts.get_mut(&device_id) {
            entry.auto_recovering = false;
        }
    });
    if let Err(message) = outcome {
        tracing::error!(
            "[MOTION GUARD] Automatic recovery of {device_id} did not finish: {message}"
        );
        publish(
            SafetyEvent::MountPositionUnknown {
                device_id: device_id.clone(),
                reason: "auto_recovery_failed".to_string(),
                message: format!(
                    "Automatic recovery did not finish: {message} The run stays paused."
                ),
            },
            EventSeverity::Critical,
        );
    }
}

async fn auto_recover(device_id: &str) -> Result<(), String> {
    // The mount has to stay still before anything is trusted.
    let mut quiet_since = tokio::time::Instant::now();
    loop {
        tokio::time::sleep(Duration::from_secs(1)).await;
        if still_moving(device_id) {
            quiet_since = tokio::time::Instant::now();
        }
        if quiet_since.elapsed() >= AUTO_RECOVERY_QUIET {
            break;
        }
        if with_registry(|r| {
            r.mounts
                .get(device_id)
                .is_none_or(|e| e.fault.is_none() && e.lost.is_none())
        }) {
            // The operator dealt with it first.
            return Ok(());
        }
    }
    let solve = solve_for_recovery(device_id, None, 5.0).await?;
    tracing::info!(
        "[MOTION GUARD] Automatic recovery solved RA {:.3}h Dec {:+.2}; the mount read RA {:.3}h \
         Dec {:+.2} ({:.1} degrees apart)",
        solve.ra_hours,
        solve.dec_deg,
        solve.mount_ra_hours,
        solve.mount_dec_deg,
        solve.separation_deg
    );
    recovery_sync(device_id, solve.ra_hours, solve.dec_deg).await?;
    crate::api::sequencer::lifecycle::api_sequencer_resume()
        .await
        .map_err(|e| format!("The run did not resume: {e}"))?;
    Ok(())
}

#[cfg(test)]
mod hold_tests {
    
    use super::hold_run_or_stop_guiding;
    use crate::state::get_state;
    use crate::api::sequencer::event_bridge::run_sequencer_event_loop;
    use crate::api::sequencer::get_sequence_executor;
    use crate::api::sequencer::lifecycle::api_sequencer_start;
    use crate::event::bus::EventPayload;
    use crate::event::sequencer::SequencerEvent;

    /// The guard asks the run to pause and the run announces it when its
    /// state turns Paused. The guard used to publish a Paused of its own as
    /// well, so one mount fault logged "Sequence paused" twice.
    #[tokio::test]
    async fn a_mount_fault_hold_puts_one_paused_on_the_wire() {
        let _serialized = crate::simulator::sim_singleton_test_lock()
            .lock()
            .await;
        let mut sequence = skotiq_sequencer::SequenceDefinition::new("Long wait".to_string());
        sequence.nodes.push(skotiq_sequencer::NodeDefinition {
            id: "wait".to_string(),
            name: "Wait".to_string(),
            node_type: skotiq_sequencer::NodeType::Delay(skotiq_sequencer::DelayConfig {
                seconds: 120.0,
            }),
            enabled: true,
            children: vec![],
        });
        sequence.root_node_id = Some("wait".to_string());
        crate::api::sequencer::event_bridge::wait_for_no_event_listeners().await;
        let mut run_events = {
            let mut executor = get_sequence_executor().write().await;
            executor.set_device_ops(std::sync::Arc::new(
                skotiq_sequencer::device_ops::NullDeviceOps,
            ));
            executor.load_sequence(sequence).expect("sequence loads");
            executor.subscribe()
        };
        let bridge = tokio::spawn(async move {
            run_sequencer_event_loop(&mut run_events, get_state()).await;
        });
        api_sequencer_start().await.expect("run starts");
        let mut events = get_state().event_bus.subscribe();

        let first = hold_run_or_stop_guiding("the mount moved on its own").await;
        let second = hold_run_or_stop_guiding("the mount lost its position").await;

        let mut paused = 0;
        while let Ok(Ok(event)) =
            tokio::time::timeout(std::time::Duration::from_millis(500), events.recv()).await
        {
            if matches!(
                event.payload,
                EventPayload::Sequencer(SequencerEvent::Paused)
            ) {
                paused += 1;
            }
        }
        get_sequence_executor()
            .write()
            .await
            .stop()
            .await
            .expect("the held run stops");
        bridge.abort();

        assert!(first && second, "the run was held both times");
        assert_eq!(paused, 1, "one fault is one Paused on the wire");
    }
}
