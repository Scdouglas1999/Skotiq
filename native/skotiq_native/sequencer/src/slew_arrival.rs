//! Deciding when a commanded slew is over.
//!
//! A driver accepting a slew says only that the slew has started: ASCOM
//! `SlewToCoordinatesAsync` and Alpaca return at once, and for a moment after
//! the call an ASCOM driver can still report `Slewing == false` because its
//! mount has not begun to move. A single read of that flag cannot tell "not
//! started yet" from "already finished". [`wait_for_slew_arrival`] therefore
//! needs evidence of motion and of a stop:
//!
//! 1. the slew is underway once `Slewing` has read true, or the mount has
//!    measurably closed on the target;
//! 2. it is over once `Slewing` reads false on
//!    [`SlewArrivalTimings::idle_confirm_polls`] reads in a row and the
//!    pointing has stopped changing;
//! 3. a mount that never reports moving is accepted only after
//!    [`SlewArrivalTimings::start_grace`] — when it sits on the target, or when
//!    there is no target to measure against — long enough for a lagging flag
//!    to have turned true;
//! 4. with a target, a mount that shows no motion within
//!    [`SlewArrivalTimings::motion_start_window`] did not move.
//!
//! The target and the position read-backs must be in the same frame; callers
//! convert the target with `DeviceOps::mount_readback_frame`.

use std::future::Future;
use std::time::Duration;

/// One read of the mount during a slew. `None` is a read that failed.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SlewSample {
    pub slewing: Option<bool>,
    /// RA hours, Dec degrees, in the mount's frame.
    pub position: Option<(f64, f64)>,
}

/// How a slew is watched.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SlewArrivalTimings {
    pub poll_interval: Duration,
    pub start_grace: Duration,
    pub motion_start_window: Duration,
    pub timeout: Duration,
    pub idle_confirm_polls: u32,
    pub arrival_tolerance_deg: f64,
    /// Failed reads in a row that end the watch. Zero never ends it.
    pub max_consecutive_failures: u32,
}

impl SlewArrivalTimings {
    /// A GoTo polled every 500 ms, given up after `timeout`.
    pub const fn goto(timeout: Duration) -> Self {
        Self {
            poll_interval: Duration::from_millis(500),
            start_grace: Duration::from_secs(2),
            motion_start_window: Duration::from_secs(15),
            timeout,
            idle_confirm_polls: 2,
            arrival_tolerance_deg: 0.25,
            max_consecutive_failures: 0,
        }
    }
}

/// Where the slew stood at the last read.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SlewProgress {
    /// Arc to the target in degrees, when there is a target and a position.
    pub remaining_deg: Option<f64>,
    /// Arc to the target at the first read that had one.
    pub initial_deg: Option<f64>,
    pub slewing: bool,
    pub elapsed: Duration,
    /// Whether the mount is within the arrival tolerance of the target.
    pub near_target: bool,
}

impl SlewProgress {
    /// Share of the arc covered, 0 to 1, when it can be measured.
    pub fn fraction(&self) -> Option<f64> {
        match (self.remaining_deg, self.initial_deg) {
            (Some(remaining), Some(initial)) if initial > 0.0 => {
                Some((1.0 - remaining / initial).clamp(0.0, 1.0))
            }
            _ => None,
        }
    }

    /// "Slewing, 12.3° to go", or the elapsed time when the distance is
    /// unknown.
    pub fn describe(&self) -> String {
        match self.remaining_deg {
            Some(deg) => format!("Slewing, {} to go", format_arc(deg)),
            None => format!("Slewing... ({}s)", self.elapsed.as_secs()),
        }
    }
}

/// An arc for a slew readout: degrees from one degree up, arcminutes below.
pub fn format_arc(degrees: f64) -> String {
    if degrees >= 1.0 {
        format!("{degrees:.1}°")
    } else {
        format!("{:.1}'", degrees * 60.0)
    }
}

/// Why a watched slew did not end with the mount stopped.
#[derive(Debug, Clone, PartialEq)]
pub enum SlewWaitError {
    Cancelled,
    DidNotMove,
    TimedOut(Duration),
    LostContact(u32),
}

impl std::fmt::Display for SlewWaitError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Cancelled => write!(f, "Operation cancelled"),
            Self::DidNotMove => {
                write!(
                    f,
                    "The mount's driver accepted the slew but the mount didn't move"
                )
            }
            Self::TimedOut(after) => {
                write!(f, "Mount slew timed out after {} seconds", after.as_secs())
            }
            Self::LostContact(reads) => write!(
                f,
                "Lost contact with the mount during the slew ({reads} status reads failed)"
            ),
        }
    }
}

/// Great-circle separation between two RA (hours) / Dec (degrees) points.
pub fn separation_deg(a: (f64, f64), b: (f64, f64)) -> f64 {
    let (ra1, dec1) = ((a.0 * 15.0).to_radians(), a.1.to_radians());
    let (ra2, dec2) = ((b.0 * 15.0).to_radians(), b.1.to_radians());
    let cos_sep = dec1.sin() * dec2.sin() + dec1.cos() * dec2.cos() * (ra2 - ra1).cos();
    cos_sep.clamp(-1.0, 1.0).acos().to_degrees()
}

/// How far the mount must close on the target to count as moving.
const MOTION_THRESHOLD_DEG: f64 = 0.1;

/// Largest change in distance between two reads of a stopped mount; an
/// untracked mount drifts with the sky by about 0.002° per half second.
const STILL_THRESHOLD_DEG: f64 = 0.01;

/// Watch a slew that the driver has accepted until the mount has stopped.
///
/// Returns the last [`SlewProgress`] once the mount is stopped — on the target
/// or not; callers that care where it stopped check
/// [`SlewProgress::near_target`] or re-read and validate the position.
pub async fn wait_for_slew_arrival<P, F, C, G>(
    target: Option<(f64, f64)>,
    timings: &SlewArrivalTimings,
    mut probe: P,
    is_cancelled: C,
    mut on_progress: G,
) -> Result<SlewProgress, SlewWaitError>
where
    P: FnMut() -> F,
    F: Future<Output = SlewSample>,
    C: Fn() -> bool,
    G: FnMut(&SlewProgress),
{
    let start = tokio::time::Instant::now();
    let mut seen_slewing = false;
    let mut idle_polls = 0u32;
    let mut failures = 0u32;
    let mut initial: Option<f64> = None;
    let mut previous: Option<f64> = None;

    loop {
        if is_cancelled() {
            return Err(SlewWaitError::Cancelled);
        }
        let sample = probe().await;
        if is_cancelled() {
            return Err(SlewWaitError::Cancelled);
        }
        let elapsed = start.elapsed();

        match sample.slewing {
            Some(true) => {
                failures = 0;
                seen_slewing = true;
                idle_polls = 0;
            }
            Some(false) => {
                failures = 0;
                idle_polls += 1;
            }
            None => {
                failures += 1;
                if timings.max_consecutive_failures > 0
                    && failures >= timings.max_consecutive_failures
                {
                    return Err(SlewWaitError::LostContact(failures));
                }
            }
        }

        let remaining = target
            .zip(sample.position)
            .map(|(t, p)| separation_deg(t, p));
        if initial.is_none() {
            initial = remaining;
        }
        let near = remaining.is_some_and(|r| r <= timings.arrival_tolerance_deg);
        let moved =
            matches!((remaining, initial), (Some(r), Some(i)) if r < i - MOTION_THRESHOLD_DEG);
        let still = match (remaining, previous) {
            (Some(r), Some(p)) => (r - p).abs() < STILL_THRESHOLD_DEG,
            (None, _) => true,
            (Some(_), None) => false,
        };
        if remaining.is_some() {
            previous = remaining;
        }

        let progress = SlewProgress {
            remaining_deg: remaining,
            initial_deg: initial,
            slewing: sample.slewing.unwrap_or(false),
            elapsed,
            near_target: near,
        };
        on_progress(&progress);

        if sample.slewing.is_some() && idle_polls >= timings.idle_confirm_polls && still {
            let past_grace = elapsed >= timings.start_grace;
            let done = if remaining.is_some() {
                seen_slewing || moved || (near && past_grace)
            } else {
                seen_slewing || past_grace
            };
            if done {
                return Ok(progress);
            }
        }

        if remaining.is_some()
            && !seen_slewing
            && !moved
            && !near
            && elapsed >= timings.motion_start_window
        {
            return Err(SlewWaitError::DidNotMove);
        }
        if elapsed >= timings.timeout {
            return Err(SlewWaitError::TimedOut(timings.timeout));
        }
        tokio::time::sleep(timings.poll_interval).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    const FROM: (f64, f64) = (0.0, 0.0);
    const TO: (f64, f64) = (6.0, 60.0);

    /// An ASCOM-like mount on the paused tokio clock: idle at the start for
    /// `lag`, slewing toward `to` for `travel`, then idle on `to`.
    fn lagging(lag: Duration, travel: Duration, to: (f64, f64)) -> impl Fn(Duration) -> SlewSample {
        move |t| {
            if t < lag {
                return SlewSample {
                    slewing: Some(false),
                    position: Some(FROM),
                };
            }
            let f = ((t - lag).as_secs_f64() / travel.as_secs_f64()).min(1.0);
            SlewSample {
                slewing: Some(f < 1.0),
                position: Some((FROM.0 + (to.0 - FROM.0) * f, FROM.1 + (to.1 - FROM.1) * f)),
            }
        }
    }

    async fn run(
        target: Option<(f64, f64)>,
        script: impl Fn(Duration) -> SlewSample,
        cancel_after: Option<Duration>,
    ) -> (
        Result<SlewProgress, SlewWaitError>,
        Duration,
        Vec<SlewProgress>,
    ) {
        let start = tokio::time::Instant::now();
        let log = Arc::new(Mutex::new(Vec::new()));
        let sink = log.clone();
        let result = wait_for_slew_arrival(
            target,
            &SlewArrivalTimings::goto(Duration::from_secs(300)),
            || {
                let sample = script(start.elapsed());
                async move { sample }
            },
            || cancel_after.is_some_and(|after| start.elapsed() >= after),
            |p| sink.lock().unwrap().push(*p),
        )
        .await;
        let log = log.lock().unwrap().clone();
        (result, start.elapsed(), log)
    }

    #[tokio::test(start_paused = true)]
    async fn a_lagging_slewing_flag_does_not_end_the_slew() {
        let (result, elapsed, log) = run(
            Some(TO),
            lagging(Duration::from_millis(1500), Duration::from_secs(20), TO),
            None,
        )
        .await;
        let done = result.expect("the slew arrives");
        assert!(done.near_target);
        assert!(!log[0].slewing, "the first reads were the lag");
        assert!(
            elapsed >= Duration::from_millis(21_500),
            "returned at {elapsed:?}"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn without_a_target_a_lagging_flag_is_waited_out() {
        let (result, elapsed, _) = run(
            None,
            lagging(Duration::from_millis(1500), Duration::from_secs(20), TO),
            None,
        )
        .await;
        result.expect("the slew stops");
        assert!(
            elapsed >= Duration::from_millis(21_500),
            "returned at {elapsed:?}"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_mount_already_on_target_waits_out_the_grace() {
        let (result, elapsed, _) = run(
            Some(TO),
            |_| SlewSample {
                slewing: Some(false),
                position: Some(TO),
            },
            None,
        )
        .await;
        assert!(result.unwrap().near_target);
        assert!(elapsed >= Duration::from_secs(2));
    }

    #[tokio::test(start_paused = true)]
    async fn a_mount_that_never_moves_is_reported() {
        let (result, elapsed, _) = run(
            Some(TO),
            |_| SlewSample {
                slewing: Some(false),
                position: Some(FROM),
            },
            None,
        )
        .await;
        assert_eq!(result.unwrap_err(), SlewWaitError::DidNotMove);
        assert!(elapsed >= Duration::from_secs(15));
    }

    #[tokio::test(start_paused = true)]
    async fn a_mount_that_stops_short_returns_stopped_off_target() {
        let short = (6.0, 50.0);
        let (result, _, _) = run(
            Some(TO),
            lagging(Duration::from_millis(500), Duration::from_secs(10), short),
            None,
        )
        .await;
        let done = result.expect("the mount stopped");
        assert!(!done.near_target);
        assert!((done.remaining_deg.unwrap() - 10.0).abs() < 1e-6);
    }

    #[tokio::test(start_paused = true)]
    async fn cancellation_ends_the_watch() {
        let (result, _, log) = run(
            Some(TO),
            lagging(Duration::from_millis(500), Duration::from_secs(20), TO),
            Some(Duration::from_secs(5)),
        )
        .await;
        assert_eq!(result.unwrap_err(), SlewWaitError::Cancelled);
        assert!(log.last().unwrap().slewing);
    }

    #[tokio::test(start_paused = true)]
    async fn a_mount_still_moving_at_the_timeout_times_out() {
        let (result, _, _) = run(
            Some(TO),
            |_| SlewSample {
                slewing: Some(true),
                position: Some(FROM),
            },
            None,
        )
        .await;
        assert_eq!(
            result.unwrap_err(),
            SlewWaitError::TimedOut(Duration::from_secs(300))
        );
    }

    #[tokio::test(start_paused = true)]
    async fn progress_counts_down_the_arc() {
        let (_, _, log) = run(
            Some(TO),
            lagging(Duration::from_millis(1500), Duration::from_secs(20), TO),
            None,
        )
        .await;
        let moving: Vec<f64> = log
            .iter()
            .filter(|p| p.slewing)
            .map(|p| p.remaining_deg.unwrap())
            .collect();
        assert!(moving.windows(2).all(|w| w[1] <= w[0]));
        assert!(log.last().unwrap().fraction().unwrap() > 0.999);
        assert!(log[0].describe().starts_with("Slewing, "));
    }

    #[test]
    fn arcs_below_a_degree_read_in_arcminutes() {
        assert_eq!(format_arc(12.34), "12.3°");
        assert_eq!(format_arc(0.07), "4.2'");
    }
}
