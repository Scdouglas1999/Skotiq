//! Reader-supervision, protocol and reconnection configuration types.

use super::*;

/// Reader task status for supervision
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReaderStatus {
    /// Reader task is running normally
    Running,
    /// Reader task has stopped gracefully
    Stopped,
    /// Reader task has crashed/failed
    Crashed,
    /// Reader task is being restarted
    Restarting,
}

/// Configuration for reader task supervision
#[derive(Debug, Clone)]
pub struct ReaderTaskConfig {
    /// Maximum number of consecutive failures before giving up (default: 5)
    pub max_consecutive_failures: u32,
    /// Base delay for restart backoff (default: 1 second)
    pub restart_base_delay_secs: u64,
    /// Maximum delay cap for restart backoff (default: 60 seconds)
    pub restart_max_delay_secs: u64,
    /// Whether to automatically restart on failure (default: true)
    pub auto_restart: bool,
    /// Use jitter in restart delays to prevent thundering herd (default: true)
    pub use_jitter: bool,
    /// Jitter factor (0.0 to 1.0, default 0.3)
    pub jitter_factor: f64,
}

impl Default for ReaderTaskConfig {
    fn default() -> Self {
        Self {
            max_consecutive_failures: 5,
            restart_base_delay_secs: 1,
            restart_max_delay_secs: 60,
            auto_restart: true,
            use_jitter: true,
            jitter_factor: 0.3,
        }
    }
}

impl ReaderTaskConfig {
    /// Calculate restart delay for a given attempt number with optional jitter.
    ///
    /// Why the `rng` parameter is required: jitter for reconnect/restart must
    /// be uncorrelated across `IndiClient` instances. Pulling randomness from
    /// the per-client PRNG (rather than a process-global one) guarantees two
    /// clients running the same backoff schedule do not synchronise their
    /// retries into a thundering herd against the INDI server.
    pub fn calculate_restart_delay(&self, attempt: u32, rng: &JitterRng) -> Duration {
        let base = Duration::from_secs(self.restart_base_delay_secs);
        let max = Duration::from_secs(self.restart_max_delay_secs);

        // Calculate exponential delay: base * 2^(attempt-1)
        // Why: checked_mul overflow at very large `attempt` saturates
        // to `max` — which is exactly what `.min(max)` enforces unconditionally on the
        // next line. The fallback merely short-circuits the saturation case.
        let exponential_delay = base
            .checked_mul(2u32.pow(attempt.saturating_sub(1)))
            .unwrap_or(max)
            .min(max);

        if self.use_jitter && self.jitter_factor > 0.0 {
            let jitter_range = exponential_delay.as_secs_f64() * self.jitter_factor;
            let random_factor = jitter_sample(rng) * jitter_range - (jitter_range / 2.0);
            let jittered_secs = (exponential_delay.as_secs_f64() + random_factor).max(0.1);
            Duration::from_secs_f64(jittered_secs.min(max.as_secs_f64()))
        } else {
            exponential_delay
        }
    }
}

/// Configuration for protocol version
#[derive(Debug, Clone)]
pub struct ProtocolConfig {
    /// Preferred protocol version
    pub preferred_version: String,
    /// Whether to auto-detect server version
    pub auto_detect: bool,
    /// Minimum supported version
    pub min_version: Option<String>,
}

impl Default for ProtocolConfig {
    fn default() -> Self {
        Self {
            preferred_version: DEFAULT_PROTOCOL_VERSION.to_string(),
            auto_detect: true,
            min_version: None,
        }
    }
}

/// Reconnection configuration with jitter support
#[derive(Debug, Clone)]
pub struct ReconnectionConfig {
    /// Base delay for exponential backoff
    pub base_delay_secs: u64,
    /// Maximum delay cap
    pub max_delay_secs: u64,
    /// Maximum number of reconnection attempts
    pub max_attempts: u32,
    /// Whether to add jitter (randomness) to prevent thundering herd
    pub use_jitter: bool,
    /// Jitter factor (0.0 to 1.0, default 0.3 = 30% variation)
    pub jitter_factor: f64,
}

impl Default for ReconnectionConfig {
    fn default() -> Self {
        Self {
            base_delay_secs: 1,
            max_delay_secs: 30,
            max_attempts: 5,
            use_jitter: true,
            jitter_factor: 0.3,
        }
    }
}

impl ReconnectionConfig {
    /// Calculate delay for a given attempt number with optional jitter.
    ///
    /// Why the `rng` parameter is required: see [`ReaderTaskConfig::calculate_restart_delay`].
    /// Reconnect backoff jitter must be sampled from the owning client's PRNG
    /// so concurrent clients do not collapse onto identical retry schedules.
    pub fn calculate_delay(&self, attempt: u32, rng: &JitterRng) -> Duration {
        // Calculate base exponential delay: base * 2^(attempt-1)
        let base = Duration::from_secs(self.base_delay_secs);
        let max = Duration::from_secs(self.max_delay_secs);

        // Why: see ReaderTaskConfig::calculate_restart_delay — overflow
        // saturates to `max`, which `.min(max)` enforces unconditionally on the next line.
        let exponential_delay = base
            .checked_mul(2u32.pow(attempt.saturating_sub(1)))
            .unwrap_or(max)
            .min(max);

        if self.use_jitter && self.jitter_factor > 0.0 {
            // Add jitter: delay * (1 - jitter_factor/2 + random * jitter_factor)
            // This gives a range of [delay * (1 - jitter_factor/2), delay * (1 + jitter_factor/2)]
            let jitter_range = exponential_delay.as_secs_f64() * self.jitter_factor;
            let random_factor = jitter_sample(rng) * jitter_range - (jitter_range / 2.0);
            let jittered_secs = (exponential_delay.as_secs_f64() + random_factor).max(0.1);
            Duration::from_secs_f64(jittered_secs.min(max.as_secs_f64()))
        } else {
            exponential_delay
        }
    }
}
