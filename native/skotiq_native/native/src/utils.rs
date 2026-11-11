//! Common utilities for native SDK drivers
//!
//! This module provides:
//! - Safe C string conversion with null-termination validation
//! - Overflow-safe buffer size calculations
//! - A cleanup guard for half-opened devices
//!
//! Note: each vendor SDK's lock lives with its function table
//! (`vendor::sdk_loader::SdkSlot`), not here.

use skotiq_device::DriverError;
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
) -> Result<usize, DriverError> {
    width
        .checked_mul(height)
        .and_then(|pixels| pixels.checked_mul(bytes_per_pixel))
        // Why: u32 → usize widening on every supported
        // target (≥ 32-bit usize; no 16-bit-usize Rust target exists in std).
        // The preceding `checked_mul`s already bounded the result to u32::MAX
        // so it fits trivially.
        .map(|size| size as usize)
        .ok_or_else(|| {
            DriverError::InvalidParameter(format!(
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
) -> Result<usize, DriverError> {
    // Validate inputs are positive
    if width <= 0 || height <= 0 || bytes_per_pixel <= 0 {
        return Err(DriverError::InvalidParameter(format!(
            "Invalid image dimensions: width={}, height={}, bytes_per_pixel={}",
            width, height, bytes_per_pixel
        )));
    }

    // Why: all three values are checked `> 0` above, so
    // i32 → u32 is SAFE (positive i32 fits in u32). The cast is essentially
    // a no-op bit-pattern reinterpretation under that precondition.
    calculate_buffer_size(width as u32, height as u32, bytes_per_pixel as u32)
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
