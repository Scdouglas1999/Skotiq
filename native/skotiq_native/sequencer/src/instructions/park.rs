//! `park.rs` — moved verbatim out of the former single-file `instructions.rs`
//! (release-pass C3 mechanical split). No logic changed; private items were
//! widened to `pub(crate)` so the sibling modules and the tests module still
//! see them, and `super::*` supplies the imports the original file had.

use super::*;

// PARK/UNPARK instructions

/// Execute park
pub async fn execute_park(ctx: &InstructionContext) -> InstructionResult {
    let mount_id = match ctx.mount_id() {
        Ok(id) => id.to_string(),
        Err(e) => return e,
    };

    tracing::info!("Parking mount");

    if let Err(e) = ctx.device_ops.mount_park(&mount_id).await {
        return InstructionResult::failure(format!("Park failed: {}", e));
    }

    // mount_park only ISSUES the park on most drivers (ASCOM/Alpaca/INDI return
    // as soon as the command is acknowledged); a park slew takes 30-90 s.
    // Returning success immediately would let an automated end-of-night
    // shutdown advance to the next step (close dome / cut power) while the OTA
    // is still swinging, and would report success even for a park the driver
    // silently rejected (e.g. CanPark=false). Wait for the mount to report
    // PARKED — the authoritative completion signal across all driver types
    // (mount_is_slewing is unreliable for INDI parking, which uses a separate
    // property) — and fail closed if it never does.
    let park_deadline = tokio::time::Instant::now() + Duration::from_secs(300);
    loop {
        if let Some(result) = ctx.check_cancelled() {
            return result;
        }
        match ctx.device_ops.mount_is_parked(&mount_id).await {
            Ok(true) => {
                return InstructionResult::success_with_message("Mount parked");
            }
            Ok(false) => {
                // Still parking.
            }
            Err(e) => {
                tracing::warn!("Park: is_parked read failed ({}); retrying", e);
            }
        }
        if tokio::time::Instant::now() > park_deadline {
            return InstructionResult::failure(
                "Mount did not report parked within 300s of issuing Park. The driver may not \
                 support Park (CanPark=false), the park was rejected, or the mount is stuck \
                 mid-slew — NOT safe to assume parked."
                    .to_string(),
            );
        }
        sleep(Duration::from_millis(500)).await;
    }
}

/// Execute unpark
pub async fn execute_unpark(ctx: &InstructionContext) -> InstructionResult {
    let mount_id = match ctx.mount_id() {
        Ok(id) => id.to_string(),
        Err(e) => return e,
    };

    // Owner decision (2026-08-14): unpark only when the mount actually reports
    // PARKED. The autopilot puts an `Unpark` at the head of every dispatched
    // sequence, so a mount that is already tracking a target gets the command
    // mid-run; several drivers treat Unpark as "release the axes", which drops
    // tracking (and on some ASCOM mounts re-homes) under an in-flight target.
    // Not parked is not an error — there is simply nothing to do, and saying so
    // in the log keeps the no-op visible instead of silent.
    //
    // A parked-state read that FAILS is not a licence to skip: an unpark on an
    // already-unparked mount is the milder outcome, so fall through and issue
    // it (this is the pre-decision behaviour).
    match ctx.device_ops.mount_is_parked(&mount_id).await {
        Ok(false) => {
            tracing::info!("Unpark: mount already reports unparked; nothing to do");
            return InstructionResult::success_with_message("Mount already unparked");
        }
        Ok(true) => {}
        Err(e) => {
            tracing::warn!("Unpark: is_parked read failed ({}); unparking anyway", e);
        }
    }

    tracing::info!("Unparking mount");

    match ctx.device_ops.mount_unpark(&mount_id).await {
        Ok(_) => InstructionResult::success_with_message("Mount unparked"),
        Err(e) => InstructionResult::failure(format!("Unpark failed: {}", e)),
    }
}

// HOME instruction

/// How long a home may take, from the command to the mount coming to rest.
const HOME_TIMEOUT: Duration = Duration::from_secs(300);

/// How long after the home command the mount must show it is moving.
///
/// A PegasusAstro NYX-101 over ASCOM reported CanFindHome=True and returned
/// from FindHome in 0.2 s, then never moved: Slewing stayed false, Dec did not
/// change for four minutes and AtHome stayed false. A driver that accepts the
/// command is therefore not proof that anything happened. Real homes start
/// within a couple of seconds; 15 s leaves room for slow drivers and serial
/// latency.
pub(crate) const HOME_MOTION_START_WINDOW: Duration = Duration::from_secs(15);

/// How often the home is polled.
const HOME_POLL_INTERVAL: Duration = Duration::from_millis(500);

/// Pointing change, in degrees, that counts as the mount moving.
const HOME_MOTION_THRESHOLD_DEG: f64 = 0.1;

/// Sidereal hours that pass per solar second.
const SIDEREAL_HOURS_PER_SECOND: f64 = 1.002_737_909_35 / 3600.0;

/// Timing for [`execute_home_mount_with`], separate so tests can shrink it.
#[derive(Debug, Clone, Copy)]
pub(crate) struct HomeTiming {
    pub(crate) motion_start_window: Duration,
    pub(crate) timeout: Duration,
    pub(crate) poll_interval: Duration,
}

impl Default for HomeTiming {
    fn default() -> Self {
        Self {
            motion_start_window: HOME_MOTION_START_WINDOW,
            timeout: HOME_TIMEOUT,
            poll_interval: HOME_POLL_INTERVAL,
        }
    }
}

/// Wrap an hour difference into (-12, 12].
fn wrap_hours(delta: f64) -> f64 {
    let wrapped = delta.rem_euclid(24.0);
    if wrapped > 12.0 {
        wrapped - 24.0
    } else {
        wrapped
    }
}

/// Whether the pointing changed in a way only a moving mount can produce.
///
/// A stopped mount either tracks (RA fixed, hour angle advancing) or does not
/// (hour angle fixed, RA advancing with sidereal time), so a change in RA alone
/// or in hour angle alone proves nothing. Motion is a Dec change, or RA and
/// hour angle changing together.
pub(crate) fn pointing_moved(start: (f64, f64), now: (f64, f64), elapsed_secs: f64) -> bool {
    let delta_dec_deg = (now.1 - start.1).abs();
    if delta_dec_deg > HOME_MOTION_THRESHOLD_DEG {
        return true;
    }
    let delta_ra_hours = wrap_hours(now.0 - start.0);
    let elapsed_sidereal_hours = elapsed_secs * SIDEREAL_HOURS_PER_SECOND;
    let delta_ha_hours = wrap_hours(elapsed_sidereal_hours - delta_ra_hours);
    delta_ra_hours.abs() * 15.0 > HOME_MOTION_THRESHOLD_DEG
        && delta_ha_hours.abs() * 15.0 > HOME_MOTION_THRESHOLD_DEG
}

/// Execute home mount.
///
/// Sends the mount to its mechanical home position. This never parks the
/// mount, never unparks it and never touches tracking: a parked mount fails the
/// node, because silently unparking would release a mount the operator put
/// away on purpose.
pub async fn execute_home_mount(ctx: &InstructionContext) -> InstructionResult {
    execute_home_mount_with(ctx, HomeTiming::default()).await
}

pub(crate) async fn execute_home_mount_with(
    ctx: &InstructionContext,
    timing: HomeTiming,
) -> InstructionResult {
    let mount_id = match ctx.mount_id() {
        Ok(id) => id.to_string(),
        Err(e) => return e,
    };

    match ctx.device_ops.mount_is_parked(&mount_id).await {
        Ok(true) => {
            return InstructionResult::failure(
                "Mount is parked. Unpark it before sending it home.".to_string(),
            );
        }
        Ok(false) => {}
        Err(e) => {
            // The driver will refuse a home on a parked mount itself; a failed
            // read is not a reason to skip the command.
            tracing::warn!("Home: is_parked read failed ({}); homing anyway", e);
        }
    }

    let start_pointing = match ctx.device_ops.mount_get_coordinates(&mount_id).await {
        Ok(pointing) => Some(pointing),
        Err(e) => {
            tracing::warn!(
                "Home: pointing read failed ({}); motion is judged on Slewing alone",
                e
            );
            None
        }
    };

    tracing::info!("Homing mount");

    if let Err(e) = ctx.device_ops.mount_find_home(&mount_id).await {
        return InstructionResult::failure(format!("Home failed: {}", e));
    }
    let issued_at = tokio::time::Instant::now();

    // Most drivers only ISSUE the home and return while the axes are still
    // moving, and some accept it and never move at all. Require evidence of
    // motion first, then wait for the mount to come to rest.
    let mut motion_seen = false;
    loop {
        if let Some(result) = ctx.check_cancelled() {
            if let Err(e) = ctx.device_ops.mount_abort_slew(&mount_id).await {
                tracing::warn!("Home: abort after cancellation failed: {}", e);
            }
            return result;
        }

        let slewing = ctx.device_ops.mount_is_slewing(&mount_id).await;
        if let Err(e) = &slewing {
            tracing::warn!("Home: is_slewing read failed ({}); retrying", e);
        }

        if !motion_seen {
            if matches!(slewing, Ok(true)) {
                motion_seen = true;
            } else if let Some(start) = start_pointing {
                if let Ok(now) = ctx.device_ops.mount_get_coordinates(&mount_id).await {
                    motion_seen = pointing_moved(start, now, issued_at.elapsed().as_secs_f64());
                }
            }
            if !motion_seen && issued_at.elapsed() > timing.motion_start_window {
                if let Err(e) = ctx.device_ops.mount_abort_slew(&mount_id).await {
                    tracing::warn!("Home: abort after a home that never started failed: {}", e);
                }
                return InstructionResult::failure(
                    "The mount's driver accepted Home but the mount didn't move.".to_string(),
                );
            }
        }

        if motion_seen && matches!(slewing, Ok(false)) {
            return match ctx.device_ops.mount_is_at_home(&mount_id).await {
                Ok(true) => InstructionResult::success_with_message("Mount at home"),
                Ok(false) => InstructionResult::failure(
                    "The mount stopped but does not report being at home".to_string(),
                ),
                Err(e) => {
                    tracing::info!("Home: mount does not report AtHome ({})", e);
                    InstructionResult::success_with_message(
                        "Mount stopped after homing; the driver cannot confirm it is at home",
                    )
                }
            };
        }

        if issued_at.elapsed() > timing.timeout {
            return InstructionResult::failure(format!(
                "Mount did not finish homing within {}s of issuing the home command.",
                timing.timeout.as_secs()
            ));
        }
        sleep(timing.poll_interval).await;
    }
}
