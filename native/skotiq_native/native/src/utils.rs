//! Common utilities for native SDK drivers
//!
//! This module provides:
//! - Safe C string conversion with null-termination validation
//! - Overflow-safe buffer size calculations
//! - Common error handling utilities
//!
//! Note: Per-vendor SDK mutexes are defined in `sync.rs`, not here.
//! Use functions like `zwo_camera_mutex()`, `qhy_mutex()`, etc. from `crate::sync`.

use crate::traits::NativeError;
use std::ffi::c_char;

// Safe string conversion

/// Convert a NUL-terminated C string to a Rust `String`, reading at most
/// `max_len` bytes. A null pointer yields an empty string; invalid UTF-8 is
/// replaced rather than rejected.
///
/// # Safety
/// The caller must ensure that `ptr` points to valid memory of at least `max_len` bytes
/// if `ptr` is not null.
pub fn safe_cstr_to_string(ptr: *const c_char, max_len: usize) -> String {
    if ptr.is_null() {
        return String::new();
    }

    // Safety: We're treating the pointer as a byte slice with bounded length.
    // The caller guarantees the pointer points to valid memory of at least max_len bytes.
    unsafe {
        let slice = std::slice::from_raw_parts(ptr as *const u8, max_len);
        // Find the null terminator, or use max_len if not found
        let null_pos = slice.iter().position(|&c| c == 0).unwrap_or(max_len);
        // Convert only up to the null terminator
        String::from_utf8_lossy(&slice[..null_pos]).to_string()
    }
}

/// Convert a fixed-size C char array — the shape SDK structs use — to a Rust
/// `String`, trimmed at the first NUL byte.
pub fn safe_char_array_to_string<const N: usize>(arr: &[c_char; N]) -> String {
    safe_cstr_to_string(arr.as_ptr(), N)
}

// Overflow-safe buffer calculations

/// Buffer size for image data, computed with checked arithmetic.
///
/// `width * height * bytes_per_pixel` overflows u32 on large images, and a
/// wrapped product allocates an undersized buffer, so overflow is an error
/// rather than a size.
pub fn calculate_buffer_size(
    width: u32,
    height: u32,
    bytes_per_pixel: u32,
) -> Result<usize, NativeError> {
    width
        .checked_mul(height)
        .and_then(|pixels| pixels.checked_mul(bytes_per_pixel))
        // Why: u32 → usize widening on every supported
        // target (≥ 32-bit usize; no 16-bit-usize Rust target exists in std).
        // The preceding `checked_mul`s already bounded the result to u32::MAX
        // so it fits trivially.
        .map(|size| size as usize)
        .ok_or_else(|| {
            NativeError::InvalidParameter(format!(
                "Image buffer size overflow: {}x{} with {} bytes/pixel",
                width, height, bytes_per_pixel
            ))
        })
}

/// [`calculate_buffer_size`] for the signed dimensions C APIs report. A
/// non-positive input is rejected before the cast to u32.
pub fn calculate_buffer_size_i32(
    width: i32,
    height: i32,
    bytes_per_pixel: i32,
) -> Result<usize, NativeError> {
    // Validate inputs are positive
    if width <= 0 || height <= 0 || bytes_per_pixel <= 0 {
        return Err(NativeError::InvalidParameter(format!(
            "Invalid image dimensions: width={}, height={}, bytes_per_pixel={}",
            width, height, bytes_per_pixel
        )));
    }

    // Why: all three values are checked `> 0` above, so
    // i32 → u32 is SAFE (positive i32 fits in u32). The cast is essentially
    // a no-op bit-pattern reinterpretation under that precondition.
    calculate_buffer_size(width as u32, height as u32, bytes_per_pixel as u32)
}

/// Check that `buffer_len` covers an image of the given dimensions; errors if it
/// is short or if the dimensions overflow.
pub fn validate_buffer_size(
    buffer_len: usize,
    width: u32,
    height: u32,
    bytes_per_pixel: u32,
) -> Result<(), NativeError> {
    let required = calculate_buffer_size(width, height, bytes_per_pixel)?;
    if buffer_len < required {
        return Err(NativeError::InvalidParameter(format!(
            "Buffer too small: have {} bytes, need {} bytes for {}x{} image",
            buffer_len, required, width, height
        )));
    }
    Ok(())
}

// Error handling utilities

/// Build a `NativeError::SdkError` carrying the vendor, the operation and the
/// raw SDK code, so error text reads the same across vendors.
pub fn sdk_error(vendor: &str, operation: &str, code: i32, message: Option<&str>) -> NativeError {
    match message {
        Some(msg) => NativeError::SdkError(format!(
            "{} {}: error code {} - {}",
            vendor, operation, code, msg
        )),
        None => NativeError::SdkError(format!("{} {}: error code {}", vendor, operation, code)),
    }
}

// Connect with cleanup guard

/// A guard that ensures cleanup is called if the guarded block fails.
///
/// This is useful for implementing the pattern where we need to close
/// a device handle if subsequent initialization steps fail after opening.
///
/// # Example
/// ```ignore
/// // Open the device
/// sdk.open(device_id);
///
/// // Create guard that will close on drop if not defused
/// let cleanup_guard = CleanupGuard::new(|| {
///     sdk.close(device_id);
/// });
///
/// // Do initialization that might fail
/// sdk.init(device_id)?;
/// sdk.configure(device_id)?;
///
/// // Success! Defuse the guard so it doesn't clean up
/// cleanup_guard.defuse();
/// ```
pub struct CleanupGuard<F: FnOnce()> {
    cleanup: Option<F>,
}

impl<F: FnOnce()> CleanupGuard<F> {
    /// Create a new cleanup guard with the given cleanup function.
    pub fn new(cleanup: F) -> Self {
        Self {
            cleanup: Some(cleanup),
        }
    }

    /// Defuse the guard, preventing the cleanup function from running.
    /// Call this when the operation succeeds and cleanup is not needed.
    pub fn defuse(mut self) {
        self.cleanup = None;
    }
}

impl<F: FnOnce()> Drop for CleanupGuard<F> {
    fn drop(&mut self) {
        if let Some(cleanup) = self.cleanup.take() {
            cleanup();
        }
    }
}

// Timeout utilities

use crate::traits::NativeTimeoutConfig;
use std::time::{Duration, Instant};

/// Poll `is_complete` until the exposure finishes or `timeout_secs` elapses,
/// backing off 1.5x per round up to 500ms so a long exposure does not spin.
pub async fn wait_for_exposure_with_timeout<F, Fut>(
    mut is_complete: F,
    timeout_secs: f64,
) -> Result<(), NativeError>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<bool, NativeError>>,
{
    let start = std::time::Instant::now();
    let mut backoff_ms = 10u64;
    const MAX_BACKOFF_MS: u64 = 500;

    loop {
        // Check if exposure is complete
        if is_complete().await? {
            return Ok(());
        }

        // Check timeout
        if start.elapsed().as_secs_f64() > timeout_secs {
            return Err(NativeError::Timeout(format!(
                "Exposure did not complete within {:.1}s timeout",
                timeout_secs
            )));
        }

        // Wait with exponential backoff
        tokio::time::sleep(std::time::Duration::from_millis(backoff_ms)).await;

        // Increase backoff (1.5x) up to max
        backoff_ms = (backoff_ms * 3 / 2).min(MAX_BACKOFF_MS);
    }
}

/// [`wait_for_exposure_with_timeout`] driven by a [`NativeTimeoutConfig`]: the
/// deadline is `exposure_secs` plus the config's margin, and a miss reports the
/// elapsed and expected durations.
pub async fn wait_for_exposure<F, Fut>(
    mut is_complete: F,
    config: &NativeTimeoutConfig,
    exposure_secs: f64,
) -> Result<(), NativeError>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<bool, NativeError>>,
{
    let timeout = config.calculate_exposure_timeout(exposure_secs);
    let start = Instant::now();
    let poll_interval = config.poll_interval;

    loop {
        // Check if exposure is complete
        match is_complete().await {
            Ok(true) => {
                tracing::debug!(
                    "Exposure completed after {:.2}s (expected {:.1}s)",
                    start.elapsed().as_secs_f64(),
                    exposure_secs
                );
                return Ok(());
            }
            Ok(false) => {
                // Not complete yet, continue polling
            }
            Err(e) => {
                // Propagate errors from the completion check
                return Err(e);
            }
        }

        // Check timeout
        let elapsed = start.elapsed();
        if elapsed > timeout {
            tracing::warn!(
                "Exposure timeout after {:?} (expected {:.1}s exposure + margin)",
                elapsed,
                exposure_secs
            );
            return Err(NativeError::exposure_timeout(elapsed, exposure_secs));
        }

        // Wait before next poll
        tokio::time::sleep(poll_interval).await;
    }
}

/// Poll `is_moving` until a focuser or filter-wheel move settles or `timeout`
/// elapses. `operation_desc` names the move in the timeout error.
pub async fn wait_for_move_complete<F, Fut>(
    mut is_moving: F,
    timeout: Duration,
    poll_interval: Duration,
    operation_desc: impl Into<String>,
) -> Result<(), NativeError>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<bool, NativeError>>,
{
    let operation = operation_desc.into();
    let start = Instant::now();

    loop {
        // Check if still moving
        match is_moving().await {
            Ok(true) => {
                // Still moving, continue polling
            }
            Ok(false) => {
                // Move complete
                tracing::debug!(
                    "{} completed after {:.2}s",
                    operation,
                    start.elapsed().as_secs_f64()
                );
                return Ok(());
            }
            Err(e) => {
                // Propagate errors
                return Err(e);
            }
        }

        // Check timeout
        let elapsed = start.elapsed();
        if elapsed > timeout {
            tracing::warn!("{} timeout after {:?}", operation, elapsed);
            return Err(NativeError::MoveTimeout {
                duration: elapsed,
                details: operation,
            });
        }

        // Wait before next poll
        tokio::time::sleep(poll_interval).await;
    }
}

/// [`wait_for_move_complete`] with the config's focuser timeout.
pub async fn wait_for_focuser_move<F, Fut>(
    is_moving: F,
    config: &NativeTimeoutConfig,
    target_position: i32,
) -> Result<(), NativeError>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<bool, NativeError>>,
{
    wait_for_move_complete(
        is_moving,
        config.focuser_move_timeout,
        config.poll_interval,
        format!("focuser move to position {}", target_position),
    )
    .await
}

/// [`wait_for_move_complete`] with the config's filter-wheel timeout.
pub async fn wait_for_filterwheel_move<F, Fut>(
    is_moving: F,
    config: &NativeTimeoutConfig,
    target_slot: i32,
) -> Result<(), NativeError>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<bool, NativeError>>,
{
    wait_for_move_complete(
        is_moving,
        config.filterwheel_move_timeout,
        config.poll_interval,
        format!("filter wheel move to slot {}", target_slot),
    )
    .await
}

/// Run any async operation under a deadline — SDK calls on unresponsive
/// hardware hang otherwise. A miss becomes `NativeError::OperationTimeout`
/// naming `operation_name`.
pub async fn with_timeout<T, F, Fut>(
    operation: F,
    timeout: Duration,
    operation_name: impl Into<String>,
) -> Result<T, NativeError>
where
    F: FnOnce() -> Fut,
    Fut: std::future::Future<Output = Result<T, NativeError>>,
{
    let name = operation_name.into();
    match tokio::time::timeout(timeout, operation()).await {
        Ok(result) => result,
        Err(_) => {
            tracing::warn!("Operation '{}' timed out after {:?}", name, timeout);
            Err(NativeError::operation_timeout(name, timeout))
        }
    }
}

/// [`with_timeout`] that reports a miss as `Ok(None)` instead of an error, for
/// callers that treat a timeout as a normal outcome.
pub async fn try_with_timeout<T, F, Fut>(
    operation: F,
    timeout: Duration,
) -> Result<Option<T>, NativeError>
where
    F: FnOnce() -> Fut,
    Fut: std::future::Future<Output = Result<T, NativeError>>,
{
    match tokio::time::timeout(timeout, operation()).await {
        Ok(result) => result.map(Some),
        Err(_) => Ok(None),
    }
}

/// Tracks the duration of an operation for timeout checking.
///
/// This struct provides a convenient way to check if an operation has
/// exceeded its timeout without repeatedly calculating elapsed time.
///
/// # Example
/// ```ignore
/// let tracker = TimeoutTracker::new(Duration::from_secs(30));
/// loop {
///     if tracker.is_expired() {
///         return Err(tracker.timeout_error("my operation"));
///     }
///     // Do polling work...
///     tokio::time::sleep(Duration::from_millis(100)).await;
/// }
/// ```
#[derive(Debug, Clone)]
pub struct TimeoutTracker {
    start: Instant,
    timeout: Duration,
}

impl TimeoutTracker {
    /// Create a new timeout tracker with the given timeout duration.
    pub fn new(timeout: Duration) -> Self {
        Self {
            start: Instant::now(),
            timeout,
        }
    }

    /// Create a timeout tracker from a `NativeTimeoutConfig` for exposure operations.
    pub fn for_exposure(config: &NativeTimeoutConfig, exposure_secs: f64) -> Self {
        Self::new(config.calculate_exposure_timeout(exposure_secs))
    }

    /// Check if the timeout has expired.
    pub fn is_expired(&self) -> bool {
        self.start.elapsed() > self.timeout
    }

    /// Get the elapsed time since the tracker was created.
    pub fn elapsed(&self) -> Duration {
        self.start.elapsed()
    }

    /// Get the remaining time before timeout, or zero if already expired.
    pub fn remaining(&self) -> Duration {
        self.timeout.saturating_sub(self.start.elapsed())
    }

    /// Get the configured timeout duration.
    pub fn timeout(&self) -> Duration {
        self.timeout
    }

    /// Create an operation timeout error with the elapsed duration.
    pub fn timeout_error(&self, operation: impl Into<String>) -> NativeError {
        NativeError::operation_timeout(operation, self.elapsed())
    }

    /// Create an exposure timeout error.
    pub fn exposure_timeout_error(&self, expected_exposure: f64) -> NativeError {
        NativeError::exposure_timeout(self.elapsed(), expected_exposure)
    }

    /// Create a move timeout error.
    pub fn move_timeout_error(&self, details: impl Into<String>) -> NativeError {
        NativeError::MoveTimeout {
            duration: self.elapsed(),
            details: details.into(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_calculate_buffer_size() {
        // Normal case
        assert_eq!(calculate_buffer_size(100, 100, 2).unwrap(), 20000);

        // Large but valid
        assert_eq!(calculate_buffer_size(4656, 3520, 2).unwrap(), 32778240);

        // Zero dimensions
        assert_eq!(calculate_buffer_size(0, 100, 2).unwrap(), 0);

        // Would overflow - this should error
        let result = calculate_buffer_size(u32::MAX, u32::MAX, 2);
        assert!(result.is_err());
    }

    #[test]
    fn test_calculate_buffer_size_i32() {
        // Normal case
        assert_eq!(calculate_buffer_size_i32(100, 100, 2).unwrap(), 20000);

        // Negative width
        assert!(calculate_buffer_size_i32(-100, 100, 2).is_err());

        // Negative height
        assert!(calculate_buffer_size_i32(100, -100, 2).is_err());

        // Zero bytes per pixel
        assert!(calculate_buffer_size_i32(100, 100, 0).is_err());
    }

    #[test]
    fn test_safe_cstr_to_string() {
        // Null pointer
        assert_eq!(safe_cstr_to_string(std::ptr::null(), 64), "");

        // Normal C string
        let test = b"Hello\0World\0";
        let ptr = test.as_ptr() as *const c_char;
        assert_eq!(safe_cstr_to_string(ptr, 12), "Hello");

        // No null terminator within bounds
        let test = b"HelloWorld";
        let ptr = test.as_ptr() as *const c_char;
        assert_eq!(safe_cstr_to_string(ptr, 5), "Hello");
    }

    #[test]
    fn test_cleanup_guard_defuse() {
        use std::sync::atomic::{AtomicBool, Ordering};

        let cleaned_up = AtomicBool::new(false);
        {
            let guard = CleanupGuard::new(|| {
                cleaned_up.store(true, Ordering::SeqCst);
            });
            guard.defuse();
        }
        // Should NOT have cleaned up because we defused
        assert!(!cleaned_up.load(Ordering::SeqCst));
    }

    #[test]
    fn test_cleanup_guard_drops() {
        use std::sync::atomic::{AtomicBool, Ordering};

        let cleaned_up = AtomicBool::new(false);
        {
            let _guard = CleanupGuard::new(|| {
                cleaned_up.store(true, Ordering::SeqCst);
            });
            // guard is dropped here without defuse
        }
        // Should have cleaned up
        assert!(cleaned_up.load(Ordering::SeqCst));
    }
}
