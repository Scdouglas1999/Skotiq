//! The slew waits each caller states, and how the shared wait reads them.

use super::*;
use crate::meridian_flip_executor::{FLIP_CENTERING_SLEW, FLIP_SLEW};

/// Every slew wait in the run, with the bounds it had when each caller kept
/// its own loop.
#[test]
fn the_slew_waits_and_their_bounds() {
    let ms = Duration::from_millis;
    let s = Duration::from_secs;
    let table = [
        (
            "flip slew",
            FLIP_SLEW,
            SlewWaitBounds {
                start: Some(SlewStartBound {
                    within: s(15),
                    poll: ms(200),
                    proceed_if_never: true,
                }),
                complete: s(600),
                poll: ms(500),
                deadline_inclusive: false,
                read_errors: SlewReadErrors::Fail,
            },
        ),
        (
            "post-flip centering correction",
            FLIP_CENTERING_SLEW,
            SlewWaitBounds {
                start: None,
                complete: s(300),
                poll: ms(500),
                deadline_inclusive: false,
                read_errors: SlewReadErrors::Fail,
            },
        ),
        (
            "Center correction",
            CENTER_CORRECTION_SLEW,
            SlewWaitBounds {
                start: Some(SlewStartBound {
                    within: s(5),
                    poll: ms(500),
                    proceed_if_never: false,
                }),
                complete: s(300),
                poll: ms(500),
                deadline_inclusive: true,
                read_errors: SlewReadErrors::Retry { label: "Centering" },
            },
        ),
        (
            "slew in progress when a Center starts",
            CENTER_SLEW_IN_PROGRESS,
            SlewWaitBounds {
                start: None,
                complete: s(300),
                poll: ms(500),
                deadline_inclusive: true,
                read_errors: SlewReadErrors::Retry { label: "Centering" },
            },
        ),
    ];
    for (site, actual, expected) in table {
        assert_eq!(actual, expected, "{site}");
    }
}

/// A mount that never reports moving: the flip waits on and finds it still,
/// a Center correction gives up at the bound.
#[tokio::test(start_paused = true)]
async fn a_mount_that_never_reports_moving() {
    for (bounds, done) in [(FLIP_SLEW, true), (CENTER_CORRECTION_SLEW, false)] {
        let ops: SharedDeviceOps =
            Arc::new(ScriptedDomeRotatorOps::new().with_mount_slewing_states(vec![false; 200]));
        let started = tokio::time::Instant::now();
        let outcome = wait_for_slew(&ops, "mount-1", bounds, &|| None::<()>).await;
        assert_eq!(matches!(outcome, SlewWait::Done), done, "{outcome:?}");
        assert_eq!(
            matches!(outcome, SlewWait::NeverStarted { .. }),
            !done,
            "{outcome:?}"
        );
        let within = bounds.start.unwrap().within;
        assert!(started.elapsed() >= within, "{:?}", started.elapsed());
    }
}

/// A stop asked for while the mount moves aborts the slew and names the
/// phase.
#[tokio::test(start_paused = true)]
async fn a_stop_aborts_the_slew() {
    let ops: SharedDeviceOps =
        Arc::new(ScriptedDomeRotatorOps::new().with_mount_slewing_states(vec![true; 20]));
    let polls = std::sync::atomic::AtomicU32::new(0);
    let stop = || (polls.fetch_add(1, Ordering::SeqCst) >= 3).then_some("stop");
    let outcome = wait_for_slew(&ops, "mount-1", FLIP_SLEW, &stop).await;
    assert!(
        matches!(
            outcome,
            SlewWait::Stopped {
                reason: "stop",
                phase: SlewPhase::Moving,
                abort: Ok(()),
            }
        ),
        "{outcome:?}"
    );
}
