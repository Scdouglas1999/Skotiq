//! When a Fujifilm body's live view runs. Pure rules, so they are tested on
//! every platform; the SDK calls are in `camera.rs` (Windows only).
//!
//! Live view starts with the first preview request, because a preview is all
//! the app's live view asks a camera for. It stops before a still exposure
//! (the owner's NINA plugin 3.0.2.0), at disconnect, and once previews stop
//! coming: a body left in live view keeps its sensor powered and warm.

use std::time::{Duration, Instant};

/// Previews arrive at the slowest stream rate (0.1 frames per second) at
/// least every 10 s, so 30 s without one means nobody is watching.
pub(crate) const IDLE_STOP: Duration = Duration::from_secs(30);

/// How long a preview request waits for a frame: one comes every 55-65 ms at
/// the Large size (NINA plugin 3.1.0.0, GFX100S II), and the first one after
/// a start takes longer.
pub(crate) const FRAME_WAIT: Duration = Duration::from_millis(1500);

/// Older frames dropped at most per request, so a stalled queue cannot hold
/// the SDK lock for long.
const MOST_SKIPPED: i32 = 8;

#[derive(Debug, Default)]
pub(crate) struct LiveViewDemand {
    running: bool,
    last_request: Option<Instant>,
    /// Counts starts, so the idle watch of an earlier start ends when live
    /// view was stopped and started again in between its checks.
    starts: u64,
}

impl LiveViewDemand {
    pub(crate) fn is_running(&self) -> bool {
        self.running
    }

    /// Record a preview request. Returns whether live view must be started.
    pub(crate) fn request(&mut self, now: Instant) -> bool {
        self.last_request = Some(now);
        !self.running
    }

    /// Live view is running; returns the start's number for [`Self::watches`].
    pub(crate) fn started(&mut self) -> u64 {
        self.running = true;
        self.starts += 1;
        self.starts
    }

    /// Whether the watch of start `start` still has a live view to watch.
    pub(crate) fn watches(&self, start: u64) -> bool {
        self.running && self.starts == start
    }

    pub(crate) fn stopped(&mut self) {
        self.running = false;
    }

    /// Whether running live view has gone unwatched long enough to stop.
    pub(crate) fn idle(&self, now: Instant) -> bool {
        self.running
            && self
                .last_request
                .is_none_or(|at| now.duration_since(at) >= IDLE_STOP)
    }
}

/// How many of the frames waiting in the buffer to drop so the one read is
/// the newest: the camera streams faster than previews are asked for.
pub(crate) fn frames_to_skip(waiting: i32) -> i32 {
    (waiting - 1).clamp(0, MOST_SKIPPED)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_first_request_starts_live_view_and_later_ones_do_not() {
        let now = Instant::now();
        let mut demand = LiveViewDemand::default();
        assert!(demand.request(now));
        demand.started();
        assert!(!demand.request(now));
        demand.stopped();
        assert!(demand.request(now));
    }

    #[test]
    fn live_view_is_idle_after_thirty_seconds_without_a_request() {
        let t0 = Instant::now();
        let mut demand = LiveViewDemand::default();
        demand.request(t0);
        assert!(!demand.idle(t0 + IDLE_STOP), "not running yet");
        demand.started();
        assert!(!demand.idle(t0 + Duration::from_secs(29)));
        demand.request(t0 + Duration::from_secs(29));
        assert!(!demand.idle(t0 + Duration::from_secs(58)));
        assert!(demand.idle(t0 + Duration::from_secs(59)));
    }

    #[test]
    fn a_watch_ends_once_live_view_was_stopped_even_if_it_runs_again() {
        let mut demand = LiveViewDemand::default();
        let first = demand.started();
        assert!(demand.watches(first));
        demand.stopped();
        let second = demand.started();
        assert!(!demand.watches(first));
        assert!(demand.watches(second));
        demand.stopped();
        assert!(!demand.watches(second));
    }

    #[test]
    fn only_older_frames_are_skipped_and_never_more_than_eight() {
        assert_eq!(frames_to_skip(0), 0);
        assert_eq!(frames_to_skip(1), 0);
        assert_eq!(frames_to_skip(4), 3);
        assert_eq!(frames_to_skip(40), 8);
    }
}
