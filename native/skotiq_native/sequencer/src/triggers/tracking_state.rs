//! The tracking-loss latch the Mount Tracking Lost and On Tracking Limit Hit
//! triggers read.
//!
//! The baseline is armed only once the mount has been seen tracking, so a mount
//! that has not started tracking yet cannot read as a loss. A loss is an edge
//! against that baseline, and the moment it was first seen starts the
//! tracking-limit wait.

/// Tracking-loss bookkeeping for the run.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TrackingLossState {
    /// The mount has been seen tracking, so a stop is a loss.
    expected: bool,
    /// A loss has been seen against the armed baseline.
    lost: bool,
    /// Unix seconds when a tracking loss was first seen, which the
    /// tracking-limit wait is measured from.
    limit_detected_at: Option<i64>,
}

impl TrackingLossState {
    pub fn is_expected(&self) -> bool {
        self.expected
    }

    pub fn is_lost(&self) -> bool {
        self.lost
    }

    /// Whether a loss has been seen against an armed baseline.
    pub fn expected_and_lost(&self) -> bool {
        self.expected && self.lost
    }

    pub fn limit_detected_at(&self) -> Option<i64> {
        self.limit_detected_at
    }

    /// Arm or disarm the baseline. Either way a recorded loss is forgotten.
    pub fn set_expected(&mut self, expected: bool) {
        self.expected = expected;
        self.lost = false;
    }

    /// Record a loss seen at `now` (Unix seconds). Returns whether this loss
    /// started the tracking-limit wait; an earlier, unresolved detection keeps
    /// its own start.
    pub fn record_loss(&mut self, now: i64) -> bool {
        self.lost = true;
        if self.limit_detected_at.is_some() {
            return false;
        }
        self.limit_detected_at = Some(now);
        true
    }

    /// Record a loss without touching the tracking-limit wait.
    pub fn mark_lost(&mut self) {
        self.lost = true;
    }

    /// Set when the loss was first seen, for a caller that knows it better
    /// than the poll (a restored run, a test).
    pub fn set_limit_detected_at(&mut self, at: Option<i64>) {
        self.limit_detected_at = at;
    }

    /// Forget the recorded loss but not when it was first seen.
    pub fn clear_lost(&mut self) {
        self.lost = false;
    }

    /// Tracking resumed or the flip ran: no loss and no wait in progress.
    pub fn clear_limit_detection(&mut self) {
        self.limit_detected_at = None;
        self.lost = false;
    }

    /// The target changed: its tracking-limit wait no longer applies.
    pub fn forget_limit_detection(&mut self) {
        self.limit_detected_at = None;
    }

    /// Set every latch at once, as a checkpoint recorded them.
    pub fn restore(&mut self, expected: bool, lost: bool, limit_detected_at: Option<i64>) {
        *self = Self {
            expected,
            lost,
            limit_detected_at,
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_first_loss_starts_the_wait_and_a_later_one_keeps_it() {
        let mut tracking = TrackingLossState::default();
        tracking.set_expected(true);
        assert!(tracking.record_loss(100));
        assert!(tracking.expected_and_lost());
        tracking.clear_lost();
        assert!(!tracking.record_loss(200));
        assert_eq!(tracking.limit_detected_at(), Some(100));
        tracking.clear_limit_detection();
        assert!(!tracking.is_lost());
        assert_eq!(tracking.limit_detected_at(), None);
        assert!(tracking.record_loss(300));
    }

    #[test]
    fn re_arming_the_baseline_forgets_the_loss_but_not_the_wait() {
        let mut tracking = TrackingLossState::default();
        tracking.set_expected(true);
        tracking.record_loss(100);
        tracking.set_expected(false);
        assert!(!tracking.is_lost());
        assert!(!tracking.expected_and_lost());
        assert_eq!(tracking.limit_detected_at(), Some(100));
        tracking.forget_limit_detection();
        assert_eq!(tracking.limit_detected_at(), None);
    }
}
