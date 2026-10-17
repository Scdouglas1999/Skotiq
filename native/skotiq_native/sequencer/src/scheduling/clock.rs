//! `Clock` abstraction for deterministic time injection.
//!
//! Until the scheduler / target-header / per-target altitude logic all
//! reached for `chrono::Utc::now()` directly. That made any test whose
//! outcome depended on time-of-day flaky (see 's report — the
//! `no_runnable_target_returns_skipped` test had to be rewritten with a
//! synthetic Antarctic target just to dodge the wall-clock).
//!
//! Production replaces every load-bearing `Utc::now()` call in the scheduling
//! module / target header / target scheduler / per-target trigger evaluator
//! with `ctx.clock.now_utc()`. The default constructor seeds [`WallClock`]
//! so behaviour is unchanged outside tests; tests inject [`MockClock`] to
//! pin the wall clock to a specific instant.
//!
//! ### Why parking_lot, not std::sync
//!
//! `MockClock::now` lives behind a `RwLock` so a test can `advance()` the
//! clock mid-run from another task. `parking_lot::RwLock` is already a
//! workspace dependency (see `node::context::skip_to_node`) and its lock
//! operations are panic-safe — `chrono::DateTime<Utc>` is `Copy`, so the
//! Clone cost is irrelevant either way.

use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, Utc};

/// Wall-clock abstraction shared across the scheduler / target-header /
/// per-target altitude trigger evaluator. Implementations are object-safe
/// (`dyn Clock`) so the executor can swap WallClock for MockClock at test
/// boundaries without monomorphising the entire sequencer crate against a
/// generic.
pub trait Clock: Send + Sync + std::fmt::Debug {
    /// Current UTC instant. Returning `DateTime<Utc>` (not `i64` timestamps)
    /// matches how the scheduling layer represents time everywhere else and
    /// keeps tz-aware arithmetic on the call-site.
    fn now_utc(&self) -> DateTime<Utc>;

    /// Convenience wrapper so call sites that only need a Unix timestamp
    /// don't have to repeat `.timestamp()` everywhere.
    fn now_timestamp(&self) -> i64 {
        self.now_utc().timestamp()
    }
}

/// Production clock: just delegates to `chrono::Utc::now()`. Cheap to clone
/// — it's a zero-sized type.
#[derive(Debug, Clone, Copy, Default)]
pub struct WallClock;

impl Clock for WallClock {
    fn now_utc(&self) -> DateTime<Utc> {
        Utc::now()
    }
}

/// Construct a shared `Arc<dyn Clock>` pointing at the production wall clock.
/// Used by `ExecutionContext::new` and other "default" entry points so the
/// production path stays a one-liner.
pub fn default_clock() -> Arc<dyn Clock> {
    Arc::new(WallClock)
}

/// Test clock — the wall clock is pinned to a single instant and only moves
/// when the test explicitly calls [`MockClock::advance`] or
/// [`MockClock::set`].
///
/// Constructed via [`MockClock::at`] / [`MockClock::epoch`] and wrapped in
/// an `Arc` so it can be installed onto an `ExecutionContext::clock` slot
/// without a `Box::leak` dance. Internally the time is behind a
/// `parking_lot::RwLock<DateTime<Utc>>` so the test can advance time
/// asynchronously from another task while the system-under-test reads it.
#[derive(Debug)]
pub struct MockClock {
    now: parking_lot::RwLock<DateTime<Utc>>,
}

impl MockClock {
    /// Build a MockClock pinned to the given RFC3339 / ISO-8601 instant.
    /// Panics on a malformed input — this is a test-only helper, so a
    /// parse failure is a programmer error, not a runtime fallback.
    pub fn at(time_iso: &str) -> Arc<Self> {
        let parsed = DateTime::parse_from_rfc3339(time_iso)
            .unwrap_or_else(|err| {
                panic!("MockClock::at — input {time_iso:?} is not RFC3339: {err}")
            })
            .with_timezone(&Utc);
        Arc::new(Self {
            now: parking_lot::RwLock::new(parsed),
        })
    }

    /// Build a MockClock pinned to the given UTC `DateTime`. Useful when
    /// the test already has a `DateTime<Utc>` in hand (e.g., from
    /// `Utc.with_ymd_and_hms`).
    pub fn from_datetime(when: DateTime<Utc>) -> Arc<Self> {
        Arc::new(Self {
            now: parking_lot::RwLock::new(when),
        })
    }

    /// Build a MockClock at the Unix epoch — handy when the test only cares
    /// about relative time and not the absolute instant.
    pub fn epoch() -> Arc<Self> {
        Self::from_datetime(DateTime::<Utc>::from_timestamp(0, 0).expect("epoch is valid"))
    }

    /// Advance the mock clock by the given duration. The duration is added
    /// using `chrono::Duration::from_std`; durations larger than
    /// `i64::MAX` nanoseconds will panic — fine for tests, which never go
    /// near that.
    pub fn advance(&self, duration: Duration) {
        let mut guard = self.now.write();
        let chrono_dur = chrono::Duration::from_std(duration)
            .expect("MockClock::advance — duration overflowed chrono::Duration");
        *guard += chrono_dur;
    }

    /// Set the mock clock to a specific instant.
    pub fn set(&self, when: DateTime<Utc>) {
        *self.now.write() = when;
    }
}

impl Clock for MockClock {
    fn now_utc(&self) -> DateTime<Utc> {
        *self.now.read()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wall_clock_advances() {
        let c = WallClock;
        let t0 = c.now_utc();
        std::thread::sleep(std::time::Duration::from_millis(2));
        let t1 = c.now_utc();
        assert!(t1 >= t0);
    }

    #[test]
    fn mock_clock_pins_and_advances() {
        let c = MockClock::at("2026-01-15T22:00:00Z");
        let t0 = c.now_utc();
        // Don't hard-code the timestamp — DST and epoch-conversion are
        // exactly the kind of brittleness MockClock is meant to dodge.
        // Assert the relative semantics: advance by 3600s, timestamp goes
        // up by 3600.
        c.advance(Duration::from_secs(3600));
        let t1 = c.now_utc();
        assert_eq!(t1.timestamp(), t0.timestamp() + 3600);
        // And the pinned start matches our ISO string: parse the ISO
        // ourselves, confirm we landed on the same instant.
        let expected = chrono::DateTime::parse_from_rfc3339("2026-01-15T22:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        assert_eq!(t0, expected);
    }

    #[test]
    fn mock_clock_set() {
        let c = MockClock::epoch();
        assert_eq!(c.now_utc().timestamp(), 0);
        let later = DateTime::<Utc>::from_timestamp(1_700_000_000, 0).unwrap();
        c.set(later);
        assert_eq!(c.now_utc().timestamp(), 1_700_000_000);
    }

    #[test]
    fn dyn_clock_is_object_safe() {
        // Compile-time check that `dyn Clock` is usable behind an Arc.
        let _arc: Arc<dyn Clock> = default_clock();
        let _arc2: Arc<dyn Clock> = MockClock::epoch();
    }
}
