//! Adaptive Polling with Exponential Backoff
//!
//! This module provides utilities for adaptive status polling during long-running
//! operations. Instead of using fixed polling intervals, the `AdaptivePoller` adjusts
//! its interval based on whether status changes are detected.
//!
//! # `as`-cast policy
//!
//! All `as` casts in this file operate on poll-interval timings in
//! milliseconds:
//! - **u32 → u64 ratio** (lines 225, 234): metric counters in [0, 2^32);
//!   f64 widening exact for any realistic count of poll ticks.
//! - **Duration::as_millis() u128 → u64** (lines 323, 334, 335, 494, 516,
//!   539, 549): poll intervals are configured ≤ minutes; u128 → u64 SAFE
//!   for any value < ~584 million years. Rust 1.45+ saturating semantics
//!   would catch absurd configs.
//! - **u64 → f64 → u64 backoff multiplication** (line 334, 538): f64
//!   precision-loss at the millisecond level is invisible to polling.
//! - **u32 → u64** (line 531): max-ticks reset threshold widening, exact.
//!
//! # Use Cases
//!
//! - **Exposure monitoring**: Start with fast polling (200ms), back off to 2s when
//!   no progress changes are detected
//! - **Mount slews**: Monitor position updates, backing off during smooth movement
//! - **Idle heartbeat**: Low-frequency polling to detect device disconnections
//!
//! # Algorithm
//!
//! 1. Start with a base interval (e.g., 200ms)
//! 2. If the polled value hasn't changed since last tick, multiply interval by backoff factor
//! 3. Cap the interval at a maximum value
//! 4. If the value changes, reset to base interval
//!
//! # Example
//!
//! ```rust
//! use skotiq_bridge::adaptive_polling::{AdaptivePoller, PollerPreset};
//!
//! let mut poller = AdaptivePoller::from_preset(PollerPreset::Exposure);
//!
//! loop {
//!     let current_progress = get_exposure_progress(); // e.g., "0.45"
//!     let next_wait = poller.tick(&current_progress);
//!
//!     tokio::time::sleep(next_wait).await;
//! }
//! ```

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

// Poller configuration

/// Configuration for adaptive polling behavior
#[derive(Debug, Clone)]
pub struct PollerConfig {
    /// Base (minimum) polling interval
    pub base_interval: Duration,
    /// Maximum polling interval (cap for exponential backoff)
    pub max_interval: Duration,
    /// Multiplier applied when value hasn't changed (e.g., 2.0 for doubling)
    pub backoff_multiplier: f64,
    /// Optional: Reset to base interval after this many consecutive backoffs
    /// without any value change (None = never auto-reset)
    pub auto_reset_after: Option<u32>,
    /// Description for debugging/logging
    pub name: &'static str,
}

impl PollerConfig {
    /// Create a new poller configuration
    pub fn new(base_interval: Duration, max_interval: Duration, backoff_multiplier: f64) -> Self {
        Self {
            base_interval,
            max_interval,
            backoff_multiplier,
            auto_reset_after: None,
            name: "custom",
        }
    }

    /// Set optional auto-reset behavior
    pub fn with_auto_reset(mut self, after_ticks: u32) -> Self {
        self.auto_reset_after = Some(after_ticks);
        self
    }

    /// Set a name for debugging
    pub fn with_name(mut self, name: &'static str) -> Self {
        self.name = name;
        self
    }
}

// Preset configurations

/// Preset polling configurations for common use cases
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PollerPreset {
    /// Exposure monitoring: needs progress updates but not excessively
    /// Base: 200ms, Max: 2000ms, Multiplier: 1.5
    Exposure,

    /// Mount slew monitoring: position updates during slews
    /// Base: 500ms, Max: 3000ms, Multiplier: 1.5
    Slew,

    /// Idle device heartbeat: just checking device is alive
    /// Base: 1000ms, Max: 5000ms, Multiplier: 2.0
    Idle,

    /// Fast status polling: for operations that complete quickly
    /// Base: 100ms, Max: 500ms, Multiplier: 1.5
    Fast,

    /// Focuser movement: needs updates but focusers move slowly
    /// Base: 300ms, Max: 2000ms, Multiplier: 1.5
    Focuser,

    /// Filter wheel rotation: short operation with distinct states
    /// Base: 200ms, Max: 1000ms, Multiplier: 1.5
    FilterWheel,

    /// Dome operations: slow movements, infrequent updates needed
    /// Base: 500ms, Max: 5000ms, Multiplier: 2.0
    Dome,

    /// Image download: can be slow but need progress
    /// Base: 100ms, Max: 1000ms, Multiplier: 1.5
    Download,
}

impl PollerPreset {
    /// Convert preset to full configuration
    pub fn to_config(self) -> PollerConfig {
        match self {
            PollerPreset::Exposure => PollerConfig {
                base_interval: Duration::from_millis(200),
                max_interval: Duration::from_millis(2000),
                backoff_multiplier: 1.5,
                auto_reset_after: None,
                name: "exposure",
            },
            PollerPreset::Slew => PollerConfig {
                base_interval: Duration::from_millis(500),
                max_interval: Duration::from_millis(3000),
                backoff_multiplier: 1.5,
                auto_reset_after: None,
                name: "slew",
            },
            PollerPreset::Idle => PollerConfig {
                base_interval: Duration::from_millis(1000),
                max_interval: Duration::from_millis(5000),
                backoff_multiplier: 2.0,
                auto_reset_after: Some(10), // Reset every ~50s if no changes
                name: "idle",
            },
            PollerPreset::Fast => PollerConfig {
                base_interval: Duration::from_millis(100),
                max_interval: Duration::from_millis(500),
                backoff_multiplier: 1.5,
                auto_reset_after: None,
                name: "fast",
            },
            PollerPreset::Focuser => PollerConfig {
                base_interval: Duration::from_millis(300),
                max_interval: Duration::from_millis(2000),
                backoff_multiplier: 1.5,
                auto_reset_after: None,
                name: "focuser",
            },
            PollerPreset::FilterWheel => PollerConfig {
                base_interval: Duration::from_millis(200),
                max_interval: Duration::from_millis(1000),
                backoff_multiplier: 1.5,
                auto_reset_after: None,
                name: "filterwheel",
            },
            PollerPreset::Dome => PollerConfig {
                base_interval: Duration::from_millis(500),
                max_interval: Duration::from_millis(5000),
                backoff_multiplier: 2.0,
                auto_reset_after: None,
                name: "dome",
            },
            PollerPreset::Download => PollerConfig {
                base_interval: Duration::from_millis(100),
                max_interval: Duration::from_millis(1000),
                backoff_multiplier: 1.5,
                auto_reset_after: None,
                name: "download",
            },
        }
    }
}

// Polling metrics

/// Metrics tracked by the adaptive poller
#[derive(Debug, Clone, Default)]
pub struct PollerMetrics {
    /// Total number of ticks (poll cycles)
    pub total_ticks: u64,
    /// Number of times the interval was increased (backed off)
    pub backoff_count: u64,
    /// Number of times the interval was reset to base
    pub reset_count: u64,
    /// Sum of all intervals in milliseconds (for computing average)
    pub total_interval_ms: u64,
    /// Longest interval used
    pub max_interval_used: Duration,
    /// Number of value changes detected
    pub value_changes: u64,
}

impl PollerMetrics {
    /// Get the average polling interval
    pub fn average_interval(&self) -> Duration {
        self.total_interval_ms
            .checked_div(self.total_ticks)
            .map_or(Duration::ZERO, Duration::from_millis)
    }

    /// Get the backoff ratio (how often we backed off vs total ticks)
    pub fn backoff_ratio(&self) -> f64 {
        if self.total_ticks == 0 {
            0.0
        } else {
            self.backoff_count as f64 / self.total_ticks as f64
        }
    }

    /// Get the value change ratio
    pub fn change_ratio(&self) -> f64 {
        if self.total_ticks == 0 {
            0.0
        } else {
            self.value_changes as f64 / self.total_ticks as f64
        }
    }
}

// Adaptive poller (non-thread-safe version)

/// Adaptive poller that adjusts polling interval based on value changes.
///
/// This is the basic, non-thread-safe version suitable for single-threaded use
/// or when wrapped in external synchronization.
///
/// # Type Parameter
///
/// - `T`: The type of value being polled. Must implement `PartialEq` for comparison.
#[derive(Debug)]
pub struct AdaptivePoller<T: PartialEq + Clone> {
    config: PollerConfig,
    current_interval: Duration,
    last_value: Option<T>,
    consecutive_no_change: u32,
    metrics: PollerMetrics,
}

impl<T: PartialEq + Clone> AdaptivePoller<T> {
    /// Create a new adaptive poller with custom configuration
    pub fn new(config: PollerConfig) -> Self {
        Self {
            current_interval: config.base_interval,
            config,
            last_value: None,
            consecutive_no_change: 0,
            metrics: PollerMetrics::default(),
        }
    }

    /// Create a new adaptive poller from a preset
    pub fn from_preset(preset: PollerPreset) -> Self {
        Self::new(preset.to_config())
    }

    /// Process a polled value and return how long to wait before the next poll.
    pub fn tick(&mut self, current_value: &T) -> Duration {
        self.metrics.total_ticks += 1;

        let value_changed = match &self.last_value {
            Some(last) => last != current_value,
            None => true, // First tick is considered a "change"
        };

        let interval = if value_changed {
            // Value changed - reset to base interval
            self.metrics.reset_count += 1;
            self.metrics.value_changes += 1;
            self.consecutive_no_change = 0;
            self.config.base_interval
        } else {
            // No change - apply backoff
            self.metrics.backoff_count += 1;
            self.consecutive_no_change += 1;

            // Check for auto-reset
            if let Some(reset_after) = self.config.auto_reset_after {
                if self.consecutive_no_change >= reset_after {
                    self.consecutive_no_change = 0;
                    self.metrics.reset_count += 1;
                    self.config.base_interval
                } else {
                    self.calculate_backoff()
                }
            } else {
                self.calculate_backoff()
            }
        };

        self.current_interval = interval;
        self.last_value = Some(current_value.clone());

        // Update metrics
        self.metrics.total_interval_ms += interval.as_millis() as u64;
        if interval > self.metrics.max_interval_used {
            self.metrics.max_interval_used = interval;
        }

        interval
    }

    /// Calculate the backed-off interval
    fn calculate_backoff(&self) -> Duration {
        let new_ms =
            (self.current_interval.as_millis() as f64 * self.config.backoff_multiplier) as u64;
        let max_ms = self.config.max_interval.as_millis() as u64;
        Duration::from_millis(new_ms.min(max_ms))
    }

    /// Force reset to base interval (useful when operation starts/restarts)
    pub fn reset(&mut self) {
        self.current_interval = self.config.base_interval;
        self.last_value = None;
        self.consecutive_no_change = 0;
        self.metrics.reset_count += 1;
    }

    /// Get the current polling interval (without ticking)
    pub fn current_interval(&self) -> Duration {
        self.current_interval
    }

    /// Get a snapshot of the metrics
    pub fn metrics(&self) -> &PollerMetrics {
        &self.metrics
    }

    /// Get the configuration
    pub fn config(&self) -> &PollerConfig {
        &self.config
    }

    /// Check if the poller is currently at max backoff
    pub fn is_at_max(&self) -> bool {
        self.current_interval >= self.config.max_interval
    }
}

// Thread-safe adaptive poller

/// Thread-safe adaptive poller using atomic operations and mutex.
///
/// This version can be safely shared across threads and used from async contexts.
/// It wraps the core AdaptivePoller with synchronization primitives.
#[derive(Debug)]
pub struct SyncAdaptivePoller<T: PartialEq + Clone + Send> {
    inner: Mutex<AdaptivePoller<T>>,
}

impl<T: PartialEq + Clone + Send> SyncAdaptivePoller<T> {
    /// Create a new thread-safe adaptive poller with custom configuration
    pub fn new(config: PollerConfig) -> Self {
        Self {
            inner: Mutex::new(AdaptivePoller::new(config)),
        }
    }

    /// Create a new thread-safe adaptive poller from a preset
    pub fn from_preset(preset: PollerPreset) -> Self {
        Self::new(preset.to_config())
    }

    /// Process a polled value and return the next wait duration (thread-safe)
    pub fn tick(&self, current_value: &T) -> Duration {
        let mut guard = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        guard.tick(current_value)
    }

    /// Force reset to base interval (thread-safe)
    pub fn reset(&self) {
        let mut guard = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        guard.reset();
    }

    /// Get the current polling interval (thread-safe)
    pub fn current_interval(&self) -> Duration {
        let guard = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        guard.current_interval()
    }

    /// Get a snapshot of the metrics (thread-safe)
    pub fn metrics(&self) -> PollerMetrics {
        let guard = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        guard.metrics().clone()
    }

    /// Check if the poller is currently at max backoff (thread-safe)
    pub fn is_at_max(&self) -> bool {
        let guard = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        guard.is_at_max()
    }
}

// String-based poller (convenience type)

/// Type alias for the common case of polling string-based status values
pub type StringPoller = AdaptivePoller<String>;

/// Type alias for thread-safe string-based polling
pub type SyncStringPoller = SyncAdaptivePoller<String>;

// Numeric tolerance poller

/// A wrapper type for floating-point values that compares with tolerance.
///
/// This is useful when polling values like position or temperature where
/// small fluctuations should not be considered "changes".
#[derive(Debug, Clone)]
pub struct ToleranceValue {
    pub value: f64,
    pub tolerance: f64,
}

impl ToleranceValue {
    /// Create a new tolerance value
    pub fn new(value: f64, tolerance: f64) -> Self {
        Self { value, tolerance }
    }

    /// Create with default tolerance of 0.001
    pub fn default_tolerance(value: f64) -> Self {
        Self::new(value, 0.001)
    }
}

impl PartialEq for ToleranceValue {
    fn eq(&self, other: &Self) -> bool {
        (self.value - other.value).abs() <= self.tolerance
    }
}

/// Type alias for tolerance-based numeric polling
pub type TolerancePoller = AdaptivePoller<ToleranceValue>;

/// Type alias for thread-safe tolerance-based polling
pub type SyncTolerancePoller = SyncAdaptivePoller<ToleranceValue>;

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

// Lightweight atomic poller (no value tracking)

/// A lightweight poller that doesn't track values, only time-based backoff.
///
/// Use this when you just need exponential backoff without value comparison,
/// or when comparing values externally.
#[derive(Debug)]
pub struct AtomicPoller {
    config: PollerConfig,
    current_interval_ms: AtomicU64,
    consecutive_no_change: AtomicU64,
    total_ticks: AtomicU64,
    backoff_count: AtomicU64,
    reset_count: AtomicU64,
}

impl AtomicPoller {
    /// Create a new atomic poller
    pub fn new(config: PollerConfig) -> Self {
        let base_ms = config.base_interval.as_millis() as u64;
        Self {
            config,
            current_interval_ms: AtomicU64::new(base_ms),
            consecutive_no_change: AtomicU64::new(0),
            total_ticks: AtomicU64::new(0),
            backoff_count: AtomicU64::new(0),
            reset_count: AtomicU64::new(0),
        }
    }

    /// Create from preset
    pub fn from_preset(preset: PollerPreset) -> Self {
        Self::new(preset.to_config())
    }

    /// Signal that the value changed - reset to base interval
    pub fn signal_change(&self) -> Duration {
        self.total_ticks.fetch_add(1, Ordering::Relaxed);
        self.reset_count.fetch_add(1, Ordering::Relaxed);
        self.consecutive_no_change.store(0, Ordering::Relaxed);

        let base_ms = self.config.base_interval.as_millis() as u64;
        self.current_interval_ms.store(base_ms, Ordering::Relaxed);

        self.config.base_interval
    }

    /// Signal that the value stayed the same - apply backoff
    pub fn signal_no_change(&self) -> Duration {
        self.total_ticks.fetch_add(1, Ordering::Relaxed);
        self.backoff_count.fetch_add(1, Ordering::Relaxed);

        let no_change = self.consecutive_no_change.fetch_add(1, Ordering::Relaxed) + 1;

        // Check auto-reset
        if let Some(reset_after) = self.config.auto_reset_after {
            if no_change >= reset_after as u64 {
                return self.signal_change();
            }
        }

        // Apply backoff
        let current_ms = self.current_interval_ms.load(Ordering::Relaxed);
        let new_ms = (current_ms as f64 * self.config.backoff_multiplier) as u64;
        let max_ms = self.config.max_interval.as_millis() as u64;
        let capped_ms = new_ms.min(max_ms);

        self.current_interval_ms.store(capped_ms, Ordering::Relaxed);

        Duration::from_millis(capped_ms)
    }

    /// Force reset to base interval
    pub fn reset(&self) {
        let base_ms = self.config.base_interval.as_millis() as u64;
        self.current_interval_ms.store(base_ms, Ordering::Relaxed);
        self.consecutive_no_change.store(0, Ordering::Relaxed);
        self.reset_count.fetch_add(1, Ordering::Relaxed);
    }

    /// Get current interval
    pub fn current_interval(&self) -> Duration {
        Duration::from_millis(self.current_interval_ms.load(Ordering::Relaxed))
    }

    /// Get basic metrics snapshot
    pub fn metrics(&self) -> PollerMetrics {
        let total = self.total_ticks.load(Ordering::Relaxed);
        let backoffs = self.backoff_count.load(Ordering::Relaxed);
        let resets = self.reset_count.load(Ordering::Relaxed);

        PollerMetrics {
            total_ticks: total,
            backoff_count: backoffs,
            reset_count: resets,
            total_interval_ms: 0,              // Not tracked in atomic version
            max_interval_used: Duration::ZERO, // Not tracked in atomic version
            value_changes: resets,             // Each reset indicates a value change
        }
    }
}

// Poller builder (fluent API)

/// Builder for creating custom poller configurations
#[derive(Debug, Clone)]
pub struct PollerBuilder {
    base_interval: Duration,
    max_interval: Duration,
    backoff_multiplier: f64,
    auto_reset_after: Option<u32>,
    name: &'static str,
}

impl PollerBuilder {
    /// Start building with default values
    pub fn new() -> Self {
        Self {
            base_interval: Duration::from_millis(200),
            max_interval: Duration::from_millis(2000),
            backoff_multiplier: 1.5,
            auto_reset_after: None,
            name: "custom",
        }
    }

    /// Start from a preset and customize
    pub fn from_preset(preset: PollerPreset) -> Self {
        let config = preset.to_config();
        Self {
            base_interval: config.base_interval,
            max_interval: config.max_interval,
            backoff_multiplier: config.backoff_multiplier,
            auto_reset_after: config.auto_reset_after,
            name: config.name,
        }
    }

    /// Set base polling interval
    pub fn base_interval(mut self, interval: Duration) -> Self {
        self.base_interval = interval;
        self
    }

    /// Set base polling interval in milliseconds
    pub fn base_interval_ms(mut self, ms: u64) -> Self {
        self.base_interval = Duration::from_millis(ms);
        self
    }

    /// Set maximum polling interval
    pub fn max_interval(mut self, interval: Duration) -> Self {
        self.max_interval = interval;
        self
    }

    /// Set maximum polling interval in milliseconds
    pub fn max_interval_ms(mut self, ms: u64) -> Self {
        self.max_interval = Duration::from_millis(ms);
        self
    }

    /// Set the backoff multiplier
    pub fn backoff_multiplier(mut self, multiplier: f64) -> Self {
        self.backoff_multiplier = multiplier;
        self
    }

    /// Set auto-reset behavior
    pub fn auto_reset_after(mut self, ticks: u32) -> Self {
        self.auto_reset_after = Some(ticks);
        self
    }

    /// Disable auto-reset
    pub fn no_auto_reset(mut self) -> Self {
        self.auto_reset_after = None;
        self
    }

    /// Set name for debugging
    pub fn name(mut self, name: &'static str) -> Self {
        self.name = name;
        self
    }

    /// Build the configuration
    pub fn build_config(self) -> PollerConfig {
        PollerConfig {
            base_interval: self.base_interval,
            max_interval: self.max_interval,
            backoff_multiplier: self.backoff_multiplier,
            auto_reset_after: self.auto_reset_after,
            name: self.name,
        }
    }

    /// Build a poller directly
    pub fn build<T: PartialEq + Clone>(self) -> AdaptivePoller<T> {
        AdaptivePoller::new(self.build_config())
    }

    /// Build a thread-safe poller
    pub fn build_sync<T: PartialEq + Clone + Send>(self) -> SyncAdaptivePoller<T> {
        SyncAdaptivePoller::new(self.build_config())
    }

    /// Build an atomic poller
    pub fn build_atomic(self) -> AtomicPoller {
        AtomicPoller::new(self.build_config())
    }
}

impl Default for PollerBuilder {
    fn default() -> Self {
        Self::new()
    }
}

// Tests

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_basic_backoff() {
        let mut poller: AdaptivePoller<i32> = AdaptivePoller::from_preset(PollerPreset::Fast);

        // First tick should return base interval
        let interval1 = poller.tick(&1);
        assert_eq!(interval1, Duration::from_millis(100));

        // Same value - should back off
        let interval2 = poller.tick(&1);
        assert!(interval2 > interval1);

        // Different value - should reset
        let interval3 = poller.tick(&2);
        assert_eq!(interval3, Duration::from_millis(100));
    }

    #[test]
    fn test_max_backoff_cap() {
        let config = PollerConfig::new(Duration::from_millis(100), Duration::from_millis(500), 2.0);
        let mut poller: AdaptivePoller<i32> = AdaptivePoller::new(config);

        // Keep ticking with same value to hit max
        let value = 42;
        for _ in 0..20 {
            poller.tick(&value);
        }

        assert!(poller.is_at_max());
        assert_eq!(poller.current_interval(), Duration::from_millis(500));
    }

    #[test]
    fn test_auto_reset() {
        let config =
            PollerConfig::new(Duration::from_millis(100), Duration::from_millis(1000), 2.0)
                .with_auto_reset(3);

        let mut poller: AdaptivePoller<i32> = AdaptivePoller::new(config);

        let value = 42;
        poller.tick(&value); // 100ms
        poller.tick(&value); // 200ms
        poller.tick(&value); // Should auto-reset

        // After 3 consecutive no-changes, should reset
        let interval = poller.tick(&value);
        assert!(interval <= Duration::from_millis(200)); // Should have reset
    }

    #[test]
    fn test_metrics() {
        let mut poller: AdaptivePoller<String> =
            AdaptivePoller::from_preset(PollerPreset::Exposure);

        poller.tick(&"state1".to_string());
        poller.tick(&"state1".to_string());
        poller.tick(&"state2".to_string());
        poller.tick(&"state2".to_string());

        let metrics = poller.metrics();
        assert_eq!(metrics.total_ticks, 4);
        assert_eq!(metrics.value_changes, 2); // First tick + state2
        assert!(metrics.average_interval() > Duration::ZERO);
    }

    #[test]
    fn test_tolerance_value() {
        let v1 = ToleranceValue::new(1.0, 0.01);
        let v2 = ToleranceValue::new(1.005, 0.01);
        let v3 = ToleranceValue::new(1.02, 0.01);

        assert_eq!(v1, v2); // Within tolerance
        assert_ne!(v1, v3); // Outside tolerance
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

    #[test]
    fn test_atomic_poller() {
        let poller = AtomicPoller::from_preset(PollerPreset::Fast);

        let interval1 = poller.signal_change();
        assert_eq!(interval1, Duration::from_millis(100));

        let interval2 = poller.signal_no_change();
        assert!(interval2 > interval1);

        let interval3 = poller.signal_change();
        assert_eq!(interval3, Duration::from_millis(100));
    }

    #[test]
    fn test_builder() {
        let poller: AdaptivePoller<i32> = PollerBuilder::new()
            .base_interval_ms(50)
            .max_interval_ms(1000)
            .backoff_multiplier(1.5)
            .name("test")
            .build();

        assert_eq!(poller.config().base_interval, Duration::from_millis(50));
        assert_eq!(poller.config().max_interval, Duration::from_millis(1000));
        assert_eq!(poller.config().name, "test");
    }

    #[test]
    fn test_preset_values() {
        let exposure = PollerPreset::Exposure.to_config();
        assert_eq!(exposure.base_interval, Duration::from_millis(200));
        assert_eq!(exposure.max_interval, Duration::from_millis(2000));

        let slew = PollerPreset::Slew.to_config();
        assert_eq!(slew.base_interval, Duration::from_millis(500));
        assert_eq!(slew.max_interval, Duration::from_millis(3000));

        let idle = PollerPreset::Idle.to_config();
        assert_eq!(idle.base_interval, Duration::from_millis(1000));
        assert_eq!(idle.max_interval, Duration::from_millis(5000));
        assert!(idle.auto_reset_after.is_some());
    }

    #[test]
    fn test_sync_poller() {
        let poller = SyncAdaptivePoller::<i32>::from_preset(PollerPreset::Fast);

        // Can be used from multiple threads
        let interval1 = poller.tick(&1);
        let interval2 = poller.tick(&1);

        assert!(interval2 > interval1);

        poller.reset();
        let interval3 = poller.tick(&1);
        assert_eq!(interval3, interval1);
    }

    #[test]
    fn test_reset() {
        let mut poller: AdaptivePoller<i32> = AdaptivePoller::from_preset(PollerPreset::Fast);

        // Build up some backoff
        poller.tick(&1);
        poller.tick(&1);
        poller.tick(&1);

        assert!(poller.current_interval() > poller.config().base_interval);

        // Reset
        poller.reset();

        assert_eq!(poller.current_interval(), poller.config().base_interval);
    }
}
