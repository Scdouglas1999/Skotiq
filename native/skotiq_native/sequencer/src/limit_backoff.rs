//! Freeing a mount that has stopped at an axis limit.
//!
//! A mount that tracked or slewed into its RA limit can accept every slew,
//! home and park command and not move (a PegasusAstro NYX-101 does this). A
//! short move of the RA axis away from the limit frees it, after which the
//! same commands work. The move here is bounded (a few degrees at most),
//! verified by the pointing actually changing, and reversed once if the axis
//! turned out to run the other way.

use crate::device_ops::{DeviceResult, MountOps, OperatorNotifyOps};
use crate::meridian::{wrap_hours, PierSide, SIDEREAL_PER_SOLAR};
use std::time::Duration;

/// Rate of the back-off move, degrees per second.
pub(crate) const BACKOFF_RATE_DEG_PER_SEC: f64 = 1.0;

/// How long the back-off move runs; at [`BACKOFF_RATE_DEG_PER_SEC`] that is
/// three degrees of RA axis.
pub(crate) const BACKOFF_DURATION: Duration = Duration::from_secs(3);

/// How long after a command a mount must show it is moving.
pub(crate) const RESPONSE_WINDOW: Duration = Duration::from_secs(15);

/// Hour-angle change, in hours, that counts as the axis having moved (0.75°).
const MIN_MOVE_HOURS: f64 = 0.05;

/// Which way the hour angle must change to leave a limit: toward the middle
/// of the hour-angle range the pier side can reach (about -3 h on the west
/// side of the pier, +3 h on the east side). With the pier side unknown the
/// limit is taken to be the one tracking runs into, so the hour angle goes
/// back down. Returns +1.0 or -1.0.
pub(crate) fn backoff_ha_direction(hour_angle_hours: f64, pier: PierSide) -> f64 {
    let middle = match pier {
        PierSide::West => -3.0,
        PierSide::East => 3.0,
        PierSide::Unknown => return -1.0,
    };
    if middle >= hour_angle_hours {
        1.0
    } else {
        -1.0
    }
}

/// MoveAxis rate on the primary axis for an hour-angle change in `direction`.
/// A positive primary rate moves the axis east, raising RA and lowering the
/// hour angle.
fn primary_rate_for(direction: f64) -> f64 {
    -direction * BACKOFF_RATE_DEG_PER_SEC
}

/// Hour-angle change between two RA read-backs `elapsed` apart.
fn hour_angle_change(start_ra: f64, end_ra: f64, elapsed: Duration) -> f64 {
    wrap_hours(elapsed.as_secs_f64() / 3600.0 * SIDEREAL_PER_SOLAR - wrap_hours(end_ra - start_ra))
}

/// Run the primary axis at `rate` for `duration`, then stop it. The stop is
/// sent even when the start failed.
async fn pulse(
    device_ops: &(impl MountOps + ?Sized),
    mount_id: &str,
    rate: f64,
    duration: Duration,
) -> DeviceResult<()> {
    let started = device_ops.mount_move_axis(mount_id, 0, rate).await;
    if started.is_ok() {
        tokio::time::sleep(duration).await;
    }
    let stopped = device_ops.mount_move_axis(mount_id, 0, 0.0).await;
    started.and(stopped)
}

/// Move the RA axis off the limit it is stuck at. Returns what was done, for
/// the operator, or why the mount could not be freed.
pub(crate) async fn back_off_limit(
    device_ops: &(impl MountOps + ?Sized),
    mount_id: &str,
    site_longitude: Option<f64>,
) -> Result<String, String> {
    let (start_ra, _) = device_ops
        .mount_get_coordinates(mount_id)
        .await
        .map_err(|e| format!("its position could not be read: {e}"))?;
    let pier = device_ops
        .mount_side_of_pier(mount_id)
        .await
        .unwrap_or(PierSide::Unknown);
    let start_ha = site_longitude.map(|lon| {
        let now = chrono::Utc::now();
        let lst = crate::meridian::local_sidereal_time(crate::meridian::julian_day(&now), lon);
        crate::meridian::hour_angle(start_ra, lst)
    });
    let direction = start_ha.map_or(-1.0, |ha| backoff_ha_direction(ha, pier));
    let rate = primary_rate_for(direction);

    let started = tokio::time::Instant::now();
    pulse(device_ops, mount_id, rate, BACKOFF_DURATION)
        .await
        .map_err(|e| format!("the move off the limit was refused: {e}"))?;
    let (ra, _) = device_ops
        .mount_get_coordinates(mount_id)
        .await
        .map_err(|e| format!("its position could not be read after the move: {e}"))?;
    let mut moved = hour_angle_change(start_ra, ra, started.elapsed());
    if moved.abs() < MIN_MOVE_HOURS {
        return Err("the RA axis did not move when driven directly either".to_string());
    }
    if moved.signum() != direction {
        // The axis ran toward the limit: undo that and go as far the other way.
        pulse(device_ops, mount_id, -rate, BACKOFF_DURATION * 2)
            .await
            .map_err(|e| format!("the move off the limit was refused: {e}"))?;
        let (ra, _) = device_ops
            .mount_get_coordinates(mount_id)
            .await
            .map_err(|e| format!("its position could not be read after the move: {e}"))?;
        moved = hour_angle_change(start_ra, ra, started.elapsed());
        if moved.signum() != direction || moved.abs() < MIN_MOVE_HOURS {
            return Err("the RA axis would not move away from the limit".to_string());
        }
    }
    Ok(format!(
        "moved the RA axis {:.1}° off its limit (hour angle {})",
        moved.abs() * 15.0,
        match start_ha {
            Some(ha) => format!("{:+.2} h to {:+.2} h", ha, ha + moved),
            None => format!("changed by {:+.2} h", moved),
        }
    ))
}

/// Whether the mount shows it is carrying out a command within `window`: it
/// reports slewing, reports parked (when `parked_counts`), or its pointing
/// changes in a way only a moving mount produces.
pub(crate) async fn mount_responds(
    device_ops: &(impl MountOps + ?Sized),
    mount_id: &str,
    start: Option<(f64, f64)>,
    issued_at: tokio::time::Instant,
    window: Duration,
    parked_counts: bool,
) -> bool {
    loop {
        if matches!(device_ops.mount_is_slewing(mount_id).await, Ok(true)) {
            return true;
        }
        if parked_counts && matches!(device_ops.mount_is_parked(mount_id).await, Ok(true)) {
            return true;
        }
        if let Some(start) = start {
            if let Ok(now) = device_ops.mount_get_coordinates(mount_id).await {
                if crate::instructions::pointing_moved(
                    start,
                    now,
                    issued_at.elapsed().as_secs_f64(),
                ) {
                    return true;
                }
            }
        }
        if issued_at.elapsed() >= window {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

/// Tell the operator the mount was stuck at a limit and what was done.
pub(crate) async fn notify(
    device_ops: &(impl OperatorNotifyOps + ?Sized),
    command: &str,
    outcome: &Result<String, String>,
) {
    let (level, message) = match outcome {
        Ok(done) => (
            "warning",
            format!(
                "The mount accepted the {command} but did not move; it was stopped at an axis \
                 limit. Skotiq {done} and sent the {command} again."
            ),
        ),
        Err(why) => (
            "error",
            format!(
                "The mount accepted the {command} but did not move, and could not be freed from \
                 its axis limit: {why}. Check the mount."
            ),
        ),
    };
    tracing::warn!("[MOUNT LIMIT] {message}");
    if let Err(e) = device_ops
        .send_notification(level, "Mount at its limit", &message, None)
        .await
    {
        tracing::warn!("Mount limit notification not sent: {e}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_back_off_heads_for_the_middle_of_the_pier_sides_range() {
        // The rig: pier West, stuck near the meridian, freed by +1 deg/s.
        assert_eq!(backoff_ha_direction(-0.52, PierSide::West), -1.0);
        assert_eq!(primary_rate_for(-1.0), 1.0);
        assert_eq!(backoff_ha_direction(-5.8, PierSide::West), 1.0);
        assert_eq!(backoff_ha_direction(5.9, PierSide::East), -1.0);
        assert_eq!(backoff_ha_direction(-0.4, PierSide::East), 1.0);
        assert_eq!(backoff_ha_direction(0.3, PierSide::Unknown), -1.0);
    }

    #[test]
    fn a_stopped_mount_has_its_hour_angle_change_with_time() {
        // Not tracking: RA fixed would mean HA advanced with time; tracking
        // (RA fixed) over 3 s advances HA by about 3 sidereal seconds only.
        let change = hour_angle_change(2.0, 2.0, Duration::from_secs(3));
        assert!(change.abs() < MIN_MOVE_HOURS);
        // RA up 0.2 h (moved east) lowers the hour angle.
        assert!(hour_angle_change(2.0, 2.2, Duration::from_secs(3)) < -0.19);
    }
}
