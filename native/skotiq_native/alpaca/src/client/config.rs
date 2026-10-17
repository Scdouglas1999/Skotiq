use super::*;

/// Timeout configuration for different operation types
#[derive(Debug, Clone)]
pub struct TimeoutConfig {
    /// Timeout for quick status queries (e.g., is_connected, position)
    pub quick_query_ms: u64,
    /// Timeout for standard operations (e.g., filter change, short moves)
    pub standard_operation_ms: u64,
    /// Timeout for long operations (e.g., image download, parking, slewing)
    pub long_operation_ms: u64,
    /// Timeout for very long operations (e.g., large image downloads, dome rotation)
    pub very_long_operation_ms: u64,
    /// Connection timeout
    pub connect_ms: u64,
}

impl Default for TimeoutConfig {
    fn default() -> Self {
        Self {
            quick_query_ms: 5000,           // 5 seconds for quick queries
            standard_operation_ms: 30000,   // 30 seconds for standard operations
            long_operation_ms: 300000,      // 5 minutes for long operations
            very_long_operation_ms: 600000, // 10 minutes for very long operations
            connect_ms: 10000,              // 10 seconds for initial connection
        }
    }
}

impl TimeoutConfig {
    /// Create timeout config optimized for camera operations
    /// Cameras need longer timeouts for image downloads
    pub fn for_camera() -> Self {
        Self {
            quick_query_ms: 5000,
            standard_operation_ms: 30000,
            long_operation_ms: 300000,      // 5 minutes for image download
            very_long_operation_ms: 900000, // 15 minutes for very large images
            connect_ms: 15000,
        }
    }

    /// Create timeout config optimized for telescope/mount operations
    /// Mounts need longer timeouts for slewing across the sky
    pub fn for_telescope() -> Self {
        Self {
            quick_query_ms: 5000,
            standard_operation_ms: 60000, // 1 minute for sync operations
            long_operation_ms: 300000,    // 5 minutes for slewing
            very_long_operation_ms: 600000, // 10 minutes for parking/homing
            connect_ms: 15000,
        }
    }

    /// Create timeout config optimized for dome operations
    /// Domes can take a long time to rotate and operate shutters
    pub fn for_dome() -> Self {
        Self {
            quick_query_ms: 5000,
            standard_operation_ms: 60000, // 1 minute for status queries
            long_operation_ms: 300000,    // 5 minutes for shutter operations
            very_long_operation_ms: 600000, // 10 minutes for full rotation
            connect_ms: 15000,
        }
    }

    /// Create timeout config optimized for focuser operations
    pub fn for_focuser() -> Self {
        Self {
            quick_query_ms: 5000,
            standard_operation_ms: 30000,
            long_operation_ms: 120000, // 2 minutes for long focus moves
            very_long_operation_ms: 300000, // 5 minutes for full travel
            connect_ms: 10000,
        }
    }

    /// Create timeout config optimized for filter wheel operations
    pub fn for_filter_wheel() -> Self {
        Self {
            quick_query_ms: 5000,
            standard_operation_ms: 30000, // 30 seconds for filter changes
            long_operation_ms: 60000,     // 1 minute maximum
            very_long_operation_ms: 120000, // 2 minutes for slow wheels
            connect_ms: 10000,
        }
    }

    /// Create timeout config optimized for rotator operations
    pub fn for_rotator() -> Self {
        Self {
            quick_query_ms: 5000,
            standard_operation_ms: 30000,
            long_operation_ms: 120000, // 2 minutes for 180-degree rotation
            very_long_operation_ms: 300000, // 5 minutes for slow rotators
            connect_ms: 10000,
        }
    }

    /// Create timeout config for discovery operations
    pub fn for_discovery() -> Self {
        Self {
            quick_query_ms: 2000,
            standard_operation_ms: 5000,
            long_operation_ms: 10000,
            very_long_operation_ms: 15000,
            connect_ms: 5000,
        }
    }
}

/// Retry configuration for failed requests
#[derive(Debug, Clone)]
pub struct RetryConfig {
    /// Maximum number of retry attempts
    pub max_attempts: u32,
    /// Initial delay between retries in milliseconds
    pub initial_delay_ms: u64,
    /// Maximum delay between retries in milliseconds
    pub max_delay_ms: u64,
    /// Multiplier for exponential backoff (e.g., 2.0 doubles the delay each time)
    pub backoff_multiplier: f64,
    /// Whether to add jitter to retry delays
    pub use_jitter: bool,
}

impl Default for RetryConfig {
    fn default() -> Self {
        Self {
            max_attempts: 3,
            initial_delay_ms: 100,
            max_delay_ms: 5000,
            backoff_multiplier: 2.0,
            use_jitter: true,
        }
    }
}

impl RetryConfig {
    /// Calculate the delay for a given attempt number (0-indexed)
    pub fn delay_for_attempt(&self, attempt: u32) -> Duration {
        // Why: `initial_delay_ms` and `max_delay_ms` are u64
        // configuration values typically ≤ 5_000 (5s); even at the u64::MAX
        // edge, f64's 53-bit mantissa still represents the value with
        // bounded relative error well below the +/-25% jitter band, so this
        // is a precision-loss-acceptable widening.
        let initial_delay_f = self.initial_delay_ms as f64;
        let max_delay_f = self.max_delay_ms as f64;
        // Why: `attempt` is u32; `powi` takes i32. Max
        // retry attempts in practice is `max_attempts` (configured ≤ ~10);
        // `attempt > i32::MAX` would require >2 billion retries, which is
        // outside the retry loop's `attempts < max_attempts` invariant.
        // Saturate at i32::MAX to avoid silent wrap into a negative exponent
        // (which would yield 1/multiplier instead of multiplier^n).
        let attempt_i32 = i32::try_from(attempt).unwrap_or(i32::MAX);
        let base_delay = initial_delay_f * self.backoff_multiplier.powi(attempt_i32);
        let capped_delay = base_delay.min(max_delay_f);

        let final_delay = if self.use_jitter {
            // Add +/- 25% jitter
            let jitter_factor = 0.75 + (rand_simple() * 0.5);
            capped_delay * jitter_factor
        } else {
            capped_delay
        };

        // Why: `final_delay` is bounded by `max_delay_ms`
        // (u64) * 1.25 jitter ceiling; clamped via `min` above. f64 → u64
        // uses Rust 1.45+ saturating semantics on overflow / NaN, which for
        // a bounded retry delay is the desired behavior.
        Duration::from_millis(final_delay as u64)
    }

    pub fn delay_for_retry_error(&self, error: &AlpacaError, attempt: u32) -> Duration {
        error
            .retry_after()
            .unwrap_or_else(|| self.delay_for_attempt(attempt))
    }

    /// Create a config with no retries
    pub fn no_retry() -> Self {
        Self {
            max_attempts: 1,
            ..Default::default()
        }
    }
}

/// Simple pseudo-random number generator for jitter (0.0 to 1.0)
fn rand_simple() -> f64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    // Why: `duration_since(UNIX_EPOCH)` only fails when the
    // system clock is set before 1970-01-01. This jitter source is purely a
    // retry-backoff perturbation (not cryptographic, not security-sensitive),
    // so a pre-epoch clock falling through to `Duration::ZERO` (no jitter on
    // that one retry) is preferable to panicking the entire HTTP retry layer.
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_nanos();
    // Why: `subsec_nanos()` returns u32 in [0, 999_999_999].
    // u32 → f64 is exact (f64 mantissa covers all u32 values). `u32::MAX` →
    // f64 is the literal divisor and is also exact.
    (f64::from(nanos) / f64::from(u32::MAX)).fract()
}

pub(super) fn parse_retry_after_header(headers: &reqwest::header::HeaderMap) -> Option<Duration> {
    headers
        .get(reqwest::header::RETRY_AFTER)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| parse_retry_after_value(value, Utc::now()))
}

pub(super) fn parse_retry_after_value(value: &str, now: DateTime<Utc>) -> Option<Duration> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }

    if let Ok(seconds) = trimmed.parse::<u64>() {
        return Some(Duration::from_secs(seconds));
    }

    let retry_at = DateTime::parse_from_rfc2822(trimmed)
        .ok()?
        .with_timezone(&Utc);
    if retry_at <= now {
        return Some(Duration::ZERO);
    }

    retry_at.signed_duration_since(now).to_std().ok()
}
