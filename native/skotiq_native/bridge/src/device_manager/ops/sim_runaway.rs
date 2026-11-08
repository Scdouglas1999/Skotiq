//! The simulated NYX-101 runaway, armed with
//! `SKOTIQ_SIM_FAULTS="mount.runaway=once:runaway(4.7,20,15,60)"`.
//!
//! The signature reproduced from the rig logs: the Dec axis alone runs at
//! about 4.7 deg/s with no command, through the pole, and no stop command
//! (Abort, MoveAxis 0, tracking off) touches it; then the mount stops
//! answering, as a rebooting controller does, and comes back reporting its
//! home position and tracking, wherever it really is.

use std::sync::Mutex;

use super::sim_faults;
use crate::api::devices::simulation::{cancel_sim_slew, get_sim_mount, sim_home_position};

const KEY: &str = "mount.runaway";

#[derive(Debug, Clone, Copy, PartialEq)]
enum Phase {
    Waiting,
    Running,
    Blackout,
    Done,
}

#[derive(Debug, Default)]
struct State {
    /// Pointing when the run started.
    start: Option<(f64, f64)>,
    /// The reboot has been applied.
    rebooted: bool,
}

static STATE: Mutex<State> = Mutex::new(State {
    start: None,
    rebooted: false,
});

/// Where the tube really points after the restart, in the mount's frame,
/// while the mount reports its home position. The simulated camera renders
/// the sky here, so a plate solve disagrees with the mount the way it would on
/// the rig. A sync or a home makes the two agree again.
static PHYSICAL: Mutex<Option<(f64, f64)>> = Mutex::new(None);

/// The real pointing when it differs from what the mount reports.
pub(crate) fn physical_pointing() -> Option<(f64, f64)> {
    *PHYSICAL.lock().unwrap_or_else(|p| p.into_inner())
}

/// The mount's model and the tube agree again (sync or home).
pub(crate) fn clear_physical_pointing() {
    *PHYSICAL.lock().unwrap_or_else(|p| p.into_inner()) = None;
}

/// A slew moves the tube by as much as it moves the reading.
pub(crate) fn shift_physical_pointing(from: (f64, f64), to: (f64, f64)) {
    let mut physical = PHYSICAL.lock().unwrap_or_else(|p| p.into_inner());
    if let Some((ra, dec)) = physical.as_mut() {
        *ra = (*ra + (to.0 - from.0)).rem_euclid(24.0);
        *dec = (*dec + (to.1 - from.1)).clamp(-90.0, 90.0);
    }
}

/// Where a Dec axis that has turned `degrees` from `start` points: past the
/// pole the declination falls again and RA is 12 h round.
fn dec_axis_position(start: (f64, f64), degrees: f64) -> (f64, f64) {
    let theta = (start.1 + degrees).rem_euclid(360.0);
    // theta in [-90, 90] reads as is; (90, 270] is over the pole.
    let (dec, over_pole) = if theta <= 90.0 {
        (theta, false)
    } else if theta <= 270.0 {
        (180.0 - theta, true)
    } else {
        (theta - 360.0, false)
    };
    let ra = if over_pole {
        (start.0 + 12.0).rem_euclid(24.0)
    } else {
        start.0
    };
    (ra, dec)
}

/// Bring the runaway up to now. `Err` while the mount is "rebooting".
///
/// Called by both simulator mount gates before anything else touches the
/// mount, so status reads and commands see the same thing.
pub(crate) async fn step() -> Result<(), String> {
    // Consulting the key is what latches the runaway once it is armed.
    sim_faults::check(KEY).await?;
    let Some((at, rate, run_secs, blackout_secs, delay_secs)) = sim_faults::runaway_latch(KEY)
    else {
        return Ok(());
    };
    let elapsed = at.elapsed().as_secs_f64();
    let phase = if elapsed < delay_secs {
        Phase::Waiting
    } else if elapsed < delay_secs + run_secs {
        Phase::Running
    } else if elapsed < delay_secs + run_secs + blackout_secs {
        Phase::Blackout
    } else {
        Phase::Done
    };
    match phase {
        Phase::Waiting => Ok(()),
        Phase::Running => {
            let start = {
                let current = {
                    let mount = get_sim_mount().read().await;
                    (mount.status.right_ascension, mount.status.declination)
                };
                *STATE
                    .lock()
                    .unwrap_or_else(|p| p.into_inner())
                    .start
                    .get_or_insert(current)
            };
            // Whatever the app commanded, the axis carries on.
            cancel_sim_slew().await;
            let (ra, dec) = dec_axis_position(start, rate * (elapsed - delay_secs));
            let mut mount = get_sim_mount().write().await;
            mount.status.right_ascension = ra;
            mount.status.declination = dec;
            mount.status.parked = false;
            mount.status.at_home = Some(false);
            Ok(())
        }
        Phase::Blackout => {
            Err("Simulated mount is not answering (the controller is restarting)".to_string())
        }
        Phase::Done => {
            let reboot = {
                let mut state = STATE.lock().unwrap_or_else(|p| p.into_inner());
                !std::mem::replace(&mut state.rebooted, true)
            };
            if reboot {
                tracing::warn!(
                    "simulator fault: the mount restarted and reports its home position"
                );
                cancel_sim_slew().await;
                let (ra, dec) = sim_home_position();
                let mut mount = get_sim_mount().write().await;
                *PHYSICAL.lock().unwrap_or_else(|p| p.into_inner()) =
                    Some((mount.status.right_ascension, mount.status.declination));
                mount.status.right_ascension = ra;
                mount.status.declination = dec;
                mount.status.at_home = Some(true);
                mount.status.tracking = true;
                mount.status.slewing = false;
                mount.status.parked = false;
            }
            Ok(())
        }
    }
}

/// Forget a finished runaway so a re-armed one starts fresh.
#[cfg(test)]
pub(crate) fn reset() {
    let mut state = STATE.lock().unwrap_or_else(|p| p.into_inner());
    state.start = None;
    state.rebooted = false;
    clear_physical_pointing();
}

#[cfg(test)]
mod tests {
    use super::dec_axis_position;

    #[test]
    fn a_dec_axis_run_goes_through_the_pole() {
        let (ra, dec) = dec_axis_position((3.0, 60.0), 20.0);
        assert!((ra - 3.0).abs() < 1e-9 && (dec - 80.0).abs() < 1e-9);
        let (ra, dec) = dec_axis_position((3.0, 60.0), 50.0);
        assert!((ra - 15.0).abs() < 1e-9, "past the pole RA turns 12 h");
        assert!((dec - 70.0).abs() < 1e-9);
        let (_, dec) = dec_axis_position((3.0, 60.0), 200.0);
        assert!(
            (dec + 80.0).abs() < 1e-9,
            "far enough round it points south"
        );
    }
}
