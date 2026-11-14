//! Status polls that slow down while nothing changes.
//!
//! [`AdaptivePoller`] waits its base interval after a poll whose value changed and
//! multiplies the wait (up to a cap) after each poll that saw the same value, so a
//! long exposure is polled often at its start and end without hammering the device
//! in between. [`ConsecutiveFailureBackoff`] spaces out retries of a poll that keeps
//! failing.

use std::time::{Duration, Instant};

/// Backs off a poll interval while the polled value stays the same.
#[derive(Debug)]
pub struct AdaptivePoller<T: PartialEq + Clone> {
    base_interval: Duration,
    max_interval: Duration,
    backoff_multiplier: f64,
    current_interval: Duration,
    last_value: Option<T>,
}

impl<T: PartialEq + Clone> AdaptivePoller<T> {
    fn new(base_interval: Duration, max_interval: Duration, backoff_multiplier: f64) -> Self {
        Self {
            base_interval,
            max_interval,
            backoff_multiplier,
            current_interval: base_interval,
            last_value: None,
        }
    }

    /// The poll of an exposure in progress: 200 ms, growing by half up to 2 s.
    pub fn exposure() -> Self {
        Self::new(Duration::from_millis(200), Duration::from_millis(2000), 1.5)
    }

    /// Takes the value just polled and returns how long to wait before the next poll.
    pub fn tick(&mut self, current_value: &T) -> Duration {
        let unchanged = self.last_value.as_ref() == Some(current_value);
        self.current_interval = if unchanged {
            self.current_interval
                .mul_f64(self.backoff_multiplier)
                .min(self.max_interval)
        } else {
            self.base_interval
        };
        self.last_value = Some(current_value.clone());
        self.current_interval
    }

    /// Starts over from the base interval, as if nothing had been polled yet.
    pub fn reset(&mut self) {
        self.current_interval = self.base_interval;
        self.last_value = None;
    }
}

// Consecutive failure backoff

/// Exponential retry gate for a poll that should remain fail-loud until its
/// failures are demonstrably sustained.
///
/// Calls are not delayed or suppressed before `failure_threshold`. Once the
/// threshold is reached, [`record_failure`](Self::record_failure) arms a retry
/// deadline. A successful attempt fully resets the gate.
#[derive(Debug, Clone)]
#[flutter_rust_bridge::frb(ignore)]
pub struct ConsecutiveFailureBackoff {
    failure_threshold: u32,
    base_delay: Duration,
    max_delay: Duration,
    backoff_multiplier: f64,
    consecutive_failures: u32,
    current_delay: Duration,
    retry_not_before: Option<Instant>,
}

impl ConsecutiveFailureBackoff {
    pub fn new(
        failure_threshold: u32,
        base_delay: Duration,
        max_delay: Duration,
        backoff_multiplier: f64,
    ) -> Self {
        Self {
            failure_threshold: failure_threshold.max(1),
            base_delay,
            max_delay,
            backoff_multiplier,
            consecutive_failures: 0,
            current_delay: base_delay,
            retry_not_before: None,
        }
    }

    /// Whether the protected poll should touch the device now.
    pub fn should_attempt(&self, now: Instant) -> bool {
        self.retry_not_before
            .map_or(true, |retry_not_before| now >= retry_not_before)
    }

    /// Record a successful device call and restore the unthrottled state.
    pub fn record_success(&mut self) {
        self.consecutive_failures = 0;
        self.current_delay = self.base_delay;
        self.retry_not_before = None;
    }

    /// Record a failed device call.
    ///
    /// Returns the armed delay only once the configured consecutive-failure
    /// threshold has been reached. Earlier failures remain visible and do not
    /// suppress the next poll.
    pub fn record_failure(&mut self, now: Instant) -> Option<Duration> {
        self.consecutive_failures = self.consecutive_failures.saturating_add(1);
        if self.consecutive_failures < self.failure_threshold {
            return None;
        }

        if self.consecutive_failures > self.failure_threshold {
            let next_delay =
                Duration::from_secs_f64(self.current_delay.as_secs_f64() * self.backoff_multiplier);
            self.current_delay = next_delay.min(self.max_delay);
        } else {
            self.current_delay = self.base_delay.min(self.max_delay);
        }

        self.retry_not_before = now.checked_add(self.current_delay);
        Some(self.current_delay)
    }

    /// Number of failures recorded since the last success.
    pub fn consecutive_failures(&self) -> u32 {
        self.consecutive_failures
    }

    /// Remaining delay before the next device attempt, if backoff is armed.
    pub fn retry_after(&self, now: Instant) -> Option<Duration> {
        self.retry_not_before
            .map(|retry_not_before| retry_not_before.saturating_duration_since(now))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unchanged_value_backs_off_and_a_change_returns_to_the_base_interval() {
        let mut poller: AdaptivePoller<i32> = AdaptivePoller::exposure();

        assert_eq!(poller.tick(&1), Duration::from_millis(200));
        assert_eq!(poller.tick(&1), Duration::from_millis(300));
        assert_eq!(poller.tick(&1), Duration::from_millis(450));
        assert_eq!(poller.tick(&2), Duration::from_millis(200));
    }

    #[test]
    fn the_backoff_stops_at_the_cap() {
        let mut poller: AdaptivePoller<i32> = AdaptivePoller::exposure();

        let mut interval = Duration::ZERO;
        for _ in 0..20 {
            interval = poller.tick(&42);
        }

        assert_eq!(interval, Duration::from_millis(2000));
    }

    #[test]
    fn consecutive_failure_backoff_waits_for_threshold() {
        let now = Instant::now();
        let mut backoff = ConsecutiveFailureBackoff::new(
            3,
            Duration::from_secs(10),
            Duration::from_secs(40),
            2.0,
        );

        assert_eq!(backoff.record_failure(now), None);
        assert!(backoff.should_attempt(now));
        assert_eq!(backoff.record_failure(now), None);
        assert!(backoff.should_attempt(now));
        assert_eq!(backoff.record_failure(now), Some(Duration::from_secs(10)));
        assert!(!backoff.should_attempt(now));
    }

    #[test]
    fn consecutive_failure_backoff_resets_after_success() {
        let now = Instant::now();
        let mut backoff = ConsecutiveFailureBackoff::new(
            1,
            Duration::from_secs(10),
            Duration::from_secs(40),
            2.0,
        );

        assert_eq!(backoff.record_failure(now), Some(Duration::from_secs(10)));
        backoff.record_success();

        assert_eq!(backoff.consecutive_failures(), 0);
        assert!(backoff.should_attempt(now));
    }
}
