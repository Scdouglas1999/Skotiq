//! Connection health monitoring for ASCOM devices.
//!
//! # `unwrap_or` policy
//!
//! All `unwrap_or(0)` sites in this file follow a `SystemTime::now()
//! .duration_since(UNIX_EPOCH)` chain that only fails if the system clock
//! is set to before 1970-01-01 — a configuration we have classified as
//! "user has chosen to break Unix time, accept degraded health metrics".
//! Returning `0` produces a timestamp before the connection was opened,
//! which the `time_since_last_success()` `saturating_sub` already handles
//! by clamping to `0` (treated as "no successful op yet").
//! The same `0` fallback is used in `get_health()` — `now == 0` and
//! `last_success == 0` are handled by the `last_success == 0 → Unknown`
//! early return immediately after, so no degraded false-positive is
//! reported either.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

/// Health status of an ASCOM device connection
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectionHealth {
    /// Device is healthy and responding
    Healthy,
    /// Device is not responding but may recover
    Degraded,
    /// Device connection has failed
    Failed,
    /// Device health is unknown (not yet checked)
    Unknown,
}

/// Tracks connection health for an ASCOM device
#[derive(Debug)]
pub struct HealthMonitor {
    /// Last successful communication timestamp (epoch ms)
    last_success: AtomicU64,
    /// Last failed communication timestamp (epoch ms)
    last_failure: AtomicU64,
    /// Consecutive failure count
    failure_count: std::sync::atomic::AtomicU32,
    /// Whether the connection is considered healthy
    is_healthy: AtomicBool,
    /// Maximum time between health checks before considering connection degraded (ms)
    health_check_interval_ms: u64,
    /// Number of consecutive failures before marking connection as failed
    max_failures: u32,
}

impl Default for HealthMonitor {
    fn default() -> Self {
        Self {
            last_success: AtomicU64::new(0),
            last_failure: AtomicU64::new(0),
            failure_count: std::sync::atomic::AtomicU32::new(0),
            is_healthy: AtomicBool::new(true),
            health_check_interval_ms: 30_000, // 30 seconds
            max_failures: 3,
        }
    }
}

impl HealthMonitor {
    /// Create a new health monitor with custom settings
    pub fn new(health_check_interval_ms: u64, max_failures: u32) -> Self {
        Self {
            health_check_interval_ms,
            max_failures,
            ..Default::default()
        }
    }

    /// Record a successful operation
    pub fn record_success(&self) {
        // Why: `Duration::as_millis()` returns u128. u64 ms since
        // 1970 overflows in year ~584,554,531 AD; until then the cast is a pure
        // truncation-of-leading-zeros widening-narrowing. Falling back to u64::MAX
        // post-overflow keeps `time_since_last_success()` saturating-correct without
        // panicking the health monitor.
        let now = u64::try_from(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis())
                .unwrap_or(0),
        )
        .unwrap_or(u64::MAX);
        self.last_success.store(now, Ordering::SeqCst);
        self.failure_count.store(0, Ordering::SeqCst);
        self.is_healthy.store(true, Ordering::SeqCst);
    }

    /// Record a failed operation
    pub fn record_failure(&self) {
        // Why: see `record_success` — `as_millis()` u128 → u64
        // safe until year 584 million AD; saturate on overflow rather than panic.
        let now = u64::try_from(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis())
                .unwrap_or(0),
        )
        .unwrap_or(u64::MAX);
        self.last_failure.store(now, Ordering::SeqCst);
        let failures = self.failure_count.fetch_add(1, Ordering::SeqCst) + 1;
        if failures >= self.max_failures {
            self.is_healthy.store(false, Ordering::SeqCst);
        }
    }

    /// Mark the connection failed outright, without waiting for `max_failures`.
    ///
    /// `record_failure` is built for *heartbeats*, where one missed poll is
    /// noise and only a run of them means anything — so it needs three strikes
    /// before it flips `is_healthy`. A refused connect is not noise: the driver
    /// has already been given the full read-back budget and did not come up.
    /// Routing that through `record_failure` leaves `failure_count = 1` of 3
    /// and `is_healthy = true`, and because `connect()` calls [`Self::reset`]
    /// on entry (which zeroes `last_success`), `get_health()` then answers
    /// `Unknown` — which `AscomDeviceConnection::is_healthy` treats as fine.
    /// Measured against the phantom `ASCOM.ASIMount.Telescope` on 2026-08-09:
    /// after a connect that was correctly refused, `is_healthy()` still
    /// returned `true`.
    pub fn mark_failed(&self) {
        self.record_failure();
        self.is_healthy.store(false, Ordering::SeqCst);
    }

    /// Get the current health status
    pub fn get_health(&self) -> ConnectionHealth {
        if !self.is_healthy.load(Ordering::SeqCst) {
            return ConnectionHealth::Failed;
        }

        // Why: see `record_success` — `as_millis()` u128 → u64
        // safe until year 584 million AD; saturate on overflow rather than panic.
        let now = u64::try_from(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis())
                .unwrap_or(0),
        )
        .unwrap_or(u64::MAX);
        let last_success = self.last_success.load(Ordering::SeqCst);

        if last_success == 0 {
            return ConnectionHealth::Unknown;
        }

        let elapsed = now.saturating_sub(last_success);
        if elapsed > self.health_check_interval_ms {
            ConnectionHealth::Degraded
        } else {
            ConnectionHealth::Healthy
        }
    }

    /// Reset the health monitor (e.g., on reconnection)
    pub fn reset(&self) {
        self.last_success.store(0, Ordering::SeqCst);
        self.last_failure.store(0, Ordering::SeqCst);
        self.failure_count.store(0, Ordering::SeqCst);
        self.is_healthy.store(true, Ordering::SeqCst);
    }

    /// Get time since last successful operation in milliseconds
    pub fn time_since_last_success(&self) -> Option<u64> {
        let last = self.last_success.load(Ordering::SeqCst);
        if last == 0 {
            return None;
        }
        // Why: see `record_success` — `as_millis()` u128 → u64
        // safe until year 584 million AD; saturate on overflow rather than panic.
        let now = u64::try_from(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis())
                .unwrap_or(0),
        )
        .unwrap_or(u64::MAX);
        Some(now.saturating_sub(last))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The shape `AscomDeviceConnection::connect` takes on a refused connect:
    /// `reset()` on entry, then one failure. `record_failure` alone is not
    /// enough to make the monitor stop vouching for the device.
    #[test]
    fn one_record_failure_after_reset_still_reports_healthy() {
        let health = HealthMonitor::default();
        health.reset();
        health.record_failure();

        // Documents WHY `mark_failed` has to exist. If this ever starts
        // failing, `record_failure` has become conclusive on its own and
        // `mark_failed` can collapse into it.
        assert_eq!(health.get_health(), ConnectionHealth::Unknown);
    }

    #[test]
    fn mark_failed_is_conclusive_on_the_first_call() {
        let health = HealthMonitor::default();
        health.reset();
        health.mark_failed();

        assert_eq!(
            health.get_health(),
            ConnectionHealth::Failed,
            "a refused connect must leave the monitor reporting Failed, not Unknown"
        );
    }

    /// `mark_failed` must not weaken the heartbeat path it shares state with:
    /// a later success is still allowed to bring the device back.
    #[test]
    fn a_later_success_clears_a_marked_failure() {
        let health = HealthMonitor::default();
        health.mark_failed();
        health.record_success();

        assert_eq!(health.get_health(), ConnectionHealth::Healthy);
    }
}
