//! The pre-meridian hold: stop tracking some minutes before the target reaches
//! the meridian, take no frames, and flip once it is the configured minutes
//! past it (N.I.N.A.'s "pause before meridian").
//!
//! Some rigs cannot track through the meridian at all: on the owner's NYX-101
//! the tube hits the tripod there. On 2026-10-21 that was worked around with
//! scheduled scripts that paused the run, stopped the guider and switched
//! tracking off 20 minutes before transit, then switched it back on and
//! resumed 20 minutes after. No flip ever ran and 3.5 hours were lost: the
//! flip fired only under the pause, the guide-star trigger took the resumed
//! run into a recovery that stopped tracking again, and the flip trigger does
//! not flip a mount that is not tracking. The hold lives here, inside the run,
//! so the run knows the mount is standing still on purpose.

use super::*;

/// Margin between the predicted end of a frame and the moment tracking stops,
/// the same margin the flip gate keeps before a flip.
const FRAME_MARGIN_SECS: f64 = 30.0;
const POLL_INTERVAL: Duration = Duration::from_secs(5);
/// How long the hold may outlast its own prediction before it gives up on the
/// hour angle ever arriving.
const OVERRUN_ALLOWANCE_MINUTES: f64 = 15.0;
/// Hour angle advances this many sidereal minutes per solar minute.
const SIDEREAL_RATE: f64 = 1.002_737_909;

/// Hold before the meridian when the next `exposure_secs` frame would still be
/// exposing at the moment tracking is due to stop.
///
/// Returns `Ok(None)` when no hold applies (or one gave up and restored
/// tracking), and `Ok(Some(motion))` when the target has reached the flip
/// threshold with tracking back on: the caller then waits for the flip the
/// trigger fires next, and ends `motion` once it has. The move is held for the
/// whole hold and flip, so the guider stays stopped and the guiding triggers
/// and the recovery leave the mount alone. `Err` is a cancelled run or a mount
/// that would not stop or restart tracking.
///
/// `hour_angle` is the target's hour angle now, in hours; tests drive it from
/// a paused clock.
pub(crate) async fn hold_before_meridian(
    ctx: &InstructionContext,
    exposure_secs: f64,
    control: &BurstControl<'_>,
    hour_angle: &(dyn Fn() -> Option<f64> + Send + Sync),
) -> Result<Option<MountMotion>, InstructionResult> {
    let (Some(lock), Some(mount_id)) = (ctx.trigger_state.as_ref(), ctx.mount_id.as_deref()) else {
        return Ok(None);
    };
    let (pause_before, threshold_min) = {
        let state = lock.read().await;
        let (Some(pause_before), Some(threshold_min)) = (
            state.meridian_pause_before_minutes,
            state.meridian_flip_minutes_past,
        ) else {
            return Ok(None);
        };
        // The flip trigger's own preconditions, on the side a flip leaves. A
        // mount the operator left untracked is not ours to hold.
        if state
            .flip_blocked(crate::MeridianTriggerMethod::MinutesPastMeridian)
            .is_some()
            || matches!(state.pier_side, Some(crate::PierSide::East))
        {
            return Ok(None);
        }
        (pause_before, threshold_min)
    };
    let Some(entry_ha_min) = hour_angle().map(|ha| ha * 60.0) else {
        return Ok(None);
    };
    // Already due: the flip trigger fires on its own, as it always has.
    if entry_ha_min >= threshold_min {
        return Ok(None);
    }
    // The frame ends before tracking is due to stop.
    if entry_ha_min + (exposure_secs + FRAME_MARGIN_SECS) / 60.0 < -pause_before {
        return Ok(None);
    }

    let target = ctx
        .target_name
        .clone()
        .unwrap_or_else(|| "the target".to_string());
    let motion = MountMotion::begin(ctx, "pre-meridian hold").await;
    {
        let mut state = lock.write().await;
        state.run.begin_hold(crate::triggers::RunHold::PreMeridian);
        state.set_mount_tracking_expected(false);
    }
    if let Err(error) = ctx.device_ops.mount_set_tracking(mount_id, false).await {
        lock.write().await.run.end_hold();
        motion.end().await;
        let message = format!(
            "Could not stop tracking {} for the pre-meridian hold: {error}",
            relative_to_meridian(entry_ha_min)
        );
        tracing::error!("[MERIDIAN] {}", message);
        control.report(&message);
        return Err(InstructionResult::failure(message));
    }
    lock.write().await.mount_is_tracking = Some(false);

    let minutes_to_flip = threshold_min - entry_ha_min;
    let flip_at = chrono::Local::now()
        + chrono::Duration::seconds((minutes_to_flip * 60.0 / SIDEREAL_RATE).round() as i64);
    let message = format!(
        "Stopped tracking {}; the flip runs when {target} is {threshold_min:.0} min past it \
         (at about {}).",
        relative_to_meridian(entry_ha_min),
        flip_at.format("%H:%M")
    );
    tracing::info!("[MERIDIAN] {}", message);
    control.report(&message);

    // Its own bound, not the flip gate's 30 minutes: the hold is as long as the
    // operator made it, and only an hour angle that never arrives overruns it.
    let bound = Duration::from_secs_f64(
        (minutes_to_flip.max(0.0) / SIDEREAL_RATE + OVERRUN_ALLOWANCE_MINUTES) * 60.0,
    );
    let started = tokio::time::Instant::now();
    loop {
        if ctx.check_cancelled().is_some() {
            return Err(end_hold_on_cancel(ctx, lock, motion, control).await);
        }
        // An operator pause during the hold is left alone: the mount is already
        // standing still, and the hold keeps counting towards the flip.
        if hour_angle().is_some_and(|ha| ha * 60.0 >= threshold_min) {
            break;
        }
        if started.elapsed() > bound {
            let restored = ctx.device_ops.mount_set_tracking(mount_id, true).await;
            {
                let mut state = lock.write().await;
                state.run.end_hold();
                if restored.is_ok() {
                    state.mount_is_tracking = Some(true);
                }
            }
            motion.end().await;
            let message = match restored {
                Ok(()) => format!(
                    "Held {} min before the meridian flip without {target} reaching {:.0} min \
                     past the meridian; tracking is back on and the run carries on.",
                    started.elapsed().as_secs() / 60,
                    threshold_min
                ),
                Err(error) => format!(
                    "Held {} min before the meridian flip without {target} reaching {:.0} min \
                     past the meridian, and tracking could not be restarted: {error}",
                    started.elapsed().as_secs() / 60,
                    threshold_min
                ),
            };
            tracing::warn!("[MERIDIAN] {}", message);
            control.report(&message);
            return Ok(None);
        }
        tokio::select! {
            _ = sleep(POLL_INTERVAL) => {}
            _ = wait_for_cancellation(ctx.cancellation_token.clone()) => {
                return Err(end_hold_on_cancel(ctx, lock, motion, control).await);
            }
        }
    }

    // A run the operator paused stays still until it is resumed: tracking
    // coming back on moves the telescope, and the flip after it moves it a lot.
    if !control
        .pause
        .wait_while_paused(&ctx.cancellation_token)
        .await
    {
        return Err(end_hold_on_cancel(ctx, lock, motion, control).await);
    }

    if let Err(error) = ctx.device_ops.mount_set_tracking(mount_id, true).await {
        lock.write().await.run.end_hold();
        motion.end().await;
        let message = format!("Could not restart tracking for the meridian flip: {error}");
        tracing::error!("[MERIDIAN] {}", message);
        control.report(&message);
        return Err(InstructionResult::failure(message));
    }
    // Written now rather than left to the next mount poll, so the flip
    // trigger, which does not flip a mount that is not tracking, can fire on
    // its next tick. The loss baseline re-arms on the poll's own `true`.
    {
        let mut state = lock.write().await;
        state.run.end_hold();
        state.mount_is_tracking = Some(true);
    }
    let message = format!(
        "{} is {threshold_min:.0} min past the meridian; tracking is back on and the flip \
         starts.",
        capitalize_first(&target)
    );
    tracing::info!("[MERIDIAN] {}", message);
    control.report(&message);
    Ok(Some(motion))
}

/// Pick up guiding after the hold and its flip.
///
/// The hold's move stopped the guiding the run had started. A flip set to
/// resume guiding has already started it again by now, outside the run's
/// guiding bookkeeping, so it is only armed again; otherwise it is started on
/// a fresh star, as after any other move.
pub(crate) async fn pick_up_guiding_after_hold(
    ctx: &InstructionContext,
) -> Option<InstructionResult> {
    let trigger_state = ctx.trigger_state.as_ref()?;
    if !trigger_state.read().await.guiding.resume_pending() {
        return None;
    }
    let guiding_now = ctx
        .device_ops
        .guider_get_status()
        .await
        .is_ok_and(|status| status.is_guiding);
    if guiding_now {
        let mut state = trigger_state.write().await;
        state.guiding.set_resume_pending(false);
        state.set_guiding_enabled(true);
        return None;
    }
    resume_guiding_after_motion(ctx).await
}

/// End the hold for a cancelled run. Tracking is left off: on a rig that holds
/// before the meridian because it cannot track through it, switching tracking
/// on for a run that is ending would drive the telescope towards the tripod
/// with nobody watching.
async fn end_hold_on_cancel(
    ctx: &InstructionContext,
    lock: &tokio::sync::RwLock<crate::triggers::TriggerState>,
    motion: MountMotion,
    control: &BurstControl<'_>,
) -> InstructionResult {
    lock.write().await.run.end_hold();
    motion.end().await;
    let message = "The run stopped during the pre-meridian hold; mount tracking is left off.";
    tracing::info!("[MERIDIAN] {}", message);
    control.report(message);
    ctx.check_cancelled()
        .unwrap_or_else(|| InstructionResult::cancelled("Exposure cancelled"))
}

fn relative_to_meridian(ha_min: f64) -> String {
    if ha_min < 0.0 {
        format!("{:.0} min before the meridian", -ha_min)
    } else {
        format!("{:.0} min after the meridian", ha_min)
    }
}

fn capitalize_first(text: &str) -> String {
    let mut chars = text.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}
