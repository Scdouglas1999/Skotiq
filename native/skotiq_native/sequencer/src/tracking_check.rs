//! Whether the mount is really tracking and standing still against the sky.
//!
//! A mount's `Tracking` flag is what the driver last accepted, not what the
//! axes do: a mount stopped at its own limit can accept "tracking on", read it
//! back as on, and never move again. The only proof is the pointing. A
//! tracking mount holds its right ascension while the hour angle advances; a
//! stopped mount holds its hour angle while the right ascension climbs at the
//! sidereal rate.

use crate::device_ops::SharedDeviceOps;
use std::time::Duration;

/// Sidereal hours that pass per solar second.
const SIDEREAL_HOURS_PER_SECOND: f64 = 1.002_737_909_35 / 3600.0;

/// How long the tracking check watches the pointing. A stopped mount's right
/// ascension climbs by this many seconds of time over the window.
pub(crate) const TRACKING_CHECK_WINDOW: Duration = Duration::from_secs(8);

/// Fraction of the sidereal rate the right ascension may still climb at for
/// the mount to count as tracking. Leaves room for coarse read-back
/// resolution (some drivers report whole seconds of time).
const TRACKING_DRIFT_FRACTION: f64 = 0.25;

/// A move in declination larger than this during the check means the mount
/// is still moving, not tracking.
const DEC_MOTION_LIMIT_ARCSEC: f64 = 30.0;

/// Pointing samples closer than this (arcseconds on the sky) count as the
/// same pointing when waiting for the mount to settle.
const SETTLE_TOLERANCE_ARCSEC: f64 = 5.0;
/// Consecutive agreeing samples that make a settled mount.
const SETTLE_STABLE_SAMPLES: u32 = 3;
const SETTLE_POLL: Duration = Duration::from_secs(1);

fn wrap_hours(delta: f64) -> f64 {
    let wrapped = delta.rem_euclid(24.0);
    if wrapped > 12.0 {
        wrapped - 24.0
    } else {
        wrapped
    }
}

/// Why the mount does not count as tracking.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum NotTracking {
    /// The mount is still moving; ask again once it has come to rest.
    StillMoving(String),
    /// The axes do not follow the sky, whatever the tracking flag says.
    Stopped(String),
    /// The mount's state could not be read.
    Unreadable(String),
}

impl std::fmt::Display for NotTracking {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::StillMoving(why) | Self::Stopped(why) | Self::Unreadable(why) => f.write_str(why),
        }
    }
}

/// Confirm that the mount tracks: it is not slewing, it reports tracking, and
/// its right ascension stays put over `window`. The error says what failed in
/// words the operator can read.
pub(crate) async fn confirm_mount_tracks(
    device_ops: &SharedDeviceOps,
    mount_id: &str,
    window: Duration,
) -> Result<(), NotTracking> {
    if matches!(device_ops.mount_is_slewing(mount_id).await, Ok(true)) {
        return Err(NotTracking::StillMoving(
            "the mount is still slewing".to_string(),
        ));
    }
    match device_ops.mount_is_tracking(mount_id).await {
        Ok(true) => {}
        Ok(false) => {
            return Err(NotTracking::Stopped(
                "the mount reports tracking off".to_string(),
            ))
        }
        Err(error) => {
            return Err(NotTracking::Unreadable(format!(
                "the mount's tracking state could not be read: {error}"
            )))
        }
    }
    let unreadable = |error: String| {
        NotTracking::Unreadable(format!("the mount's position could not be read: {error}"))
    };
    let (ra0, dec0) = device_ops
        .mount_get_coordinates(mount_id)
        .await
        .map_err(unreadable)?;
    let started = tokio::time::Instant::now();
    tokio::time::sleep(window).await;
    let (ra1, dec1) = device_ops
        .mount_get_coordinates(mount_id)
        .await
        .map_err(unreadable)?;
    let elapsed = started.elapsed().as_secs_f64().max(1e-3);
    let dec_arcsec = (dec1 - dec0).abs() * 3600.0;
    if dec_arcsec > DEC_MOTION_LIMIT_ARCSEC {
        return Err(NotTracking::StillMoving(format!(
            "the mount moved {dec_arcsec:.0}\" in declination in {elapsed:.0} s, so it is still moving"
        )));
    }
    let ra_climb_secs = wrap_hours(ra1 - ra0) * 3600.0;
    let sidereal_secs = elapsed * SIDEREAL_HOURS_PER_SECOND * 3600.0;
    if ra_climb_secs.abs() > TRACKING_DRIFT_FRACTION * sidereal_secs {
        return Err(NotTracking::Stopped(format!(
            "the mount reports tracking on, but its right ascension moved {:.1} s of time in \
             {elapsed:.0} s, so the axes are not tracking",
            ra_climb_secs.abs()
        )));
    }
    Ok(())
}

/// How a wait for the mount to settle ended.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum SettleOutcome {
    /// Not slewing, tracking, and the pointing held still.
    Settled {
        after_secs: f64,
    },
    /// The bound ran out; the reason says what never settled.
    TimedOut {
        reason: String,
    },
    Cancelled,
}

/// Wait until the mount has come to rest after a slew: not slewing, tracking,
/// and [`SETTLE_STABLE_SAMPLES`] consecutive pointing samples agree within
/// [`SETTLE_TOLERANCE_ARCSEC`]. Waits at least `min` and at most `max`.
pub(crate) async fn wait_until_mount_settled(
    device_ops: &SharedDeviceOps,
    mount_id: &str,
    min: Duration,
    max: Duration,
    is_cancelled: &(dyn Fn() -> bool + Send + Sync),
) -> SettleOutcome {
    let started = tokio::time::Instant::now();
    let mut previous: Option<(f64, f64)> = None;
    let mut stable = 0u32;
    let mut reason = "the mount did not report its position".to_string();
    loop {
        if is_cancelled() {
            return SettleOutcome::Cancelled;
        }
        let slewing = matches!(device_ops.mount_is_slewing(mount_id).await, Ok(true));
        let tracking = matches!(device_ops.mount_is_tracking(mount_id).await, Ok(true));
        let pointing = match device_ops.mount_get_coordinates(mount_id).await {
            Ok(pointing) => Some(pointing),
            Err(error) => {
                reason = format!("the mount's position could not be read: {error}");
                None
            }
        };
        if slewing {
            reason = "the mount still reports slewing".to_string();
            stable = 0;
        } else if !tracking {
            reason = "the mount reports tracking off".to_string();
            stable = 0;
        } else {
            match (previous, pointing) {
                (Some((ra0, dec0)), Some((ra1, dec1))) => {
                    let ra_arcsec = wrap_hours(ra1 - ra0) * 15.0 * 3600.0 * dec1.to_radians().cos();
                    let dec_arcsec = (dec1 - dec0) * 3600.0;
                    let moved = ra_arcsec.hypot(dec_arcsec);
                    if moved <= SETTLE_TOLERANCE_ARCSEC {
                        stable += 1;
                    } else {
                        reason = format!("the pointing was still moving ({moved:.0}\" per second)");
                        stable = 0;
                    }
                }
                _ => stable = 0,
            }
        }
        previous = pointing;
        let elapsed = started.elapsed();
        if stable >= SETTLE_STABLE_SAMPLES && elapsed >= min {
            return SettleOutcome::Settled {
                after_secs: elapsed.as_secs_f64(),
            };
        }
        if elapsed >= max {
            return SettleOutcome::TimedOut { reason };
        }
        tokio::time::sleep(SETTLE_POLL).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::executor::scenario_sim_tests::{ScriptedDeviceOps, SimMount};
    use std::sync::Arc;

    #[tokio::test(start_paused = true)]
    async fn a_tracking_mount_is_confirmed() {
        let ops = Arc::new(ScriptedDeviceOps::new());
        ops.attach_sim_mount(SimMount::tracking_at(2.37, 42.35));
        let shared: SharedDeviceOps = ops.clone();
        assert_eq!(
            confirm_mount_tracks(&shared, "mount", TRACKING_CHECK_WINDOW).await,
            Ok(())
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_mount_that_reads_tracking_but_does_not_move_is_caught() {
        let ops = Arc::new(ScriptedDeviceOps::new());
        let mut mount = SimMount::stopped_at(2.37, 42.35);
        mount.ignore_tracking_on = 1;
        ops.attach_sim_mount(mount);
        let shared: SharedDeviceOps = ops.clone();
        shared.mount_set_tracking("mount", true).await.unwrap();
        assert_eq!(shared.mount_is_tracking("mount").await, Ok(true));
        let error = confirm_mount_tracks(&shared, "mount", TRACKING_CHECK_WINDOW)
            .await
            .unwrap_err();
        assert!(matches!(error, NotTracking::Stopped(_)), "{error}");
        assert!(error.to_string().contains("not tracking"), "{error}");
        // The second command takes.
        shared.mount_set_tracking("mount", true).await.unwrap();
        assert_eq!(
            confirm_mount_tracks(&shared, "mount", TRACKING_CHECK_WINDOW).await,
            Ok(())
        );
    }

    #[tokio::test(start_paused = true)]
    async fn the_settle_wait_outlasts_a_mount_still_moving_after_its_slew() {
        let ops = Arc::new(ScriptedDeviceOps::new());
        let mut mount = SimMount::tracking_at(2.37, 42.35);
        mount.settle_secs = 20.0;
        ops.attach_sim_mount(mount);
        let shared: SharedDeviceOps = ops.clone();
        shared
            .mount_slew_to_coordinates("mount", 2.40, 42.35)
            .await
            .unwrap();
        let outcome = wait_until_mount_settled(
            &shared,
            "mount",
            Duration::ZERO,
            Duration::from_secs(60),
            &|| false,
        )
        .await;
        match outcome {
            SettleOutcome::Settled { after_secs } => assert!(after_secs >= 20.0, "{after_secs}"),
            other => panic!("{other:?}"),
        }
    }

    #[tokio::test(start_paused = true)]
    async fn the_settle_wait_is_bounded_on_a_stopped_mount() {
        let ops = Arc::new(ScriptedDeviceOps::new());
        ops.attach_sim_mount(SimMount::stopped_at(2.37, 42.35));
        let shared: SharedDeviceOps = ops.clone();
        let outcome = wait_until_mount_settled(
            &shared,
            "mount",
            Duration::ZERO,
            Duration::from_secs(30),
            &|| false,
        )
        .await;
        assert!(
            matches!(&outcome, SettleOutcome::TimedOut { reason } if reason.contains("tracking off")),
            "{outcome:?}"
        );
    }
}
