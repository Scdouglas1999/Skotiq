//! How long the bridge waits on a device before reporting a timeout.
//!
//! | Operation | Timeout |
//! |-----------|---------|
//! | Connection | 30 s |
//! | Property read / write | 5 s / 10 s |
//! | Short slew / long slew | 60 s / 300 s |
//! | Exposure start | 10 s |
//! | Large image download | 120 s |
//! | Focuser move | 30-180 s by distance, 120 s when the start is unknown |
//! | Filter wheel, rotator | 60 s |

use crate::error::SkotiqError;
use std::future::Future;
use std::time::Duration;
use tokio::time::timeout;

/// Standard timeout values for different operation types
pub struct Timeouts;

impl Timeouts {
    /// Timeout for long mount movements (GoTo)
    pub const fn long_slew() -> Duration {
        Duration::from_secs(300)
    }

    /// Timeout for large image downloads (high resolution cameras)
    pub const fn image_download_large() -> Duration {
        Duration::from_secs(120)
    }

    pub const fn focuser_move() -> Duration {
        Duration::from_secs(120)
    }

    pub const fn rotator_move() -> Duration {
        Duration::from_secs(60)
    }

    /// Timeout for establishing an ASCOM connection
    #[cfg(any(windows, test))]
    pub const fn connection() -> Duration {
        Duration::from_secs(30)
    }
}

/// The waits of the ASCOM COM worker, the only code that waits on these.
#[cfg(windows)]
impl Timeouts {
    /// Timeout for reading device properties
    pub const fn property_read() -> Duration {
        Duration::from_secs(5)
    }

    /// Timeout for writing device properties
    pub const fn property_write() -> Duration {
        Duration::from_secs(10)
    }

    /// Timeout for short mount movements (small adjustments, pulse guide)
    pub const fn short_slew() -> Duration {
        Duration::from_secs(60)
    }

    pub const fn park() -> Duration {
        Duration::from_secs(180)
    }

    pub const fn find_home() -> Duration {
        Duration::from_secs(300)
    }

    /// Timeout for starting an exposure
    pub const fn exposure_start() -> Duration {
        Duration::from_secs(10)
    }

    /// Timeout for filter wheel rotation
    pub const fn filter_wheel() -> Duration {
        Duration::from_secs(60)
    }

    pub const fn dome() -> Duration {
        Duration::from_secs(300)
    }

    /// Timeout for dome shutter operations
    pub const fn dome_shutter() -> Duration {
        Duration::from_secs(120)
    }

    /// Timeout for cover calibrator operations
    pub const fn cover_calibrator() -> Duration {
        Duration::from_secs(30)
    }

    /// Timeout for heartbeat/ping operations
    pub const fn heartbeat() -> Duration {
        Duration::from_secs(5)
    }
}

// Timeout wrapper functions

/// Execute a future with a timeout, reporting an expiry as
/// [`SkotiqError::DeviceTimeout`] naming `device_id` and `operation`.
pub async fn with_timeout<T, F>(
    future: F,
    timeout_duration: Duration,
    device_id: &str,
    operation: &str,
) -> Result<T, SkotiqError>
where
    F: Future<Output = Result<T, SkotiqError>>,
{
    match timeout(timeout_duration, future).await {
        Ok(result) => result,
        Err(_elapsed) => Err(SkotiqError::DeviceTimeout {
            device_id: device_id.to_string(),
            operation: operation.to_string(),
            timeout_secs: timeout_duration.as_secs_f64(),
        }),
    }
}

/// Execute a future with a timeout, mapping string errors to SkotiqError
///
/// This variant is useful for operations that return `Result<T, String>`
#[cfg(windows)]
pub async fn with_timeout_str<T, F>(
    future: F,
    timeout_duration: Duration,
    device_id: &str,
    operation: &str,
) -> Result<T, SkotiqError>
where
    F: Future<Output = Result<T, String>>,
{
    match timeout(timeout_duration, future).await {
        Ok(result) => result.map_err(|e| SkotiqError::OperationFailed(e)),
        Err(_elapsed) => Err(SkotiqError::DeviceTimeout {
            device_id: device_id.to_string(),
            operation: operation.to_string(),
            timeout_secs: timeout_duration.as_secs_f64(),
        }),
    }
}

// Specialized timeout operations

/// Mount slew under the long-slew timeout.
///
/// The budget is fixed rather than scaled by slew distance: the driver arms
/// that call this do not read the mount's current position first, so there is
/// no distance to scale by.
#[cfg(windows)]
pub async fn mount_slew_with_timeout<F>(future: F, mount_id: &str) -> Result<(), SkotiqError>
where
    F: Future<Output = Result<(), SkotiqError>>,
{
    with_timeout(
        future,
        Timeouts::long_slew(),
        mount_id,
        "slew_to_coordinates",
    )
    .await
}

/// Focuser move with timeout based on step distance
pub async fn focuser_move_with_timeout<F>(
    future: F,
    focuser_id: &str,
    target_position: i32,
    current_position: Option<i32>,
    max_position: i32,
) -> Result<(), SkotiqError>
where
    F: Future<Output = Result<(), SkotiqError>>,
{
    // Estimate move time based on distance
    let timeout_duration = if let Some(current) = current_position {
        let distance = (target_position - current).abs();
        let full_travel_time = 120.0; // 120s for full travel
                                      // Why: i32 → f64 widening, exact. The resulting
                                      // timeout is clamped to [30, 180] seconds via min/max below, so
                                      // any precision artifact is invisible.
        let estimated_secs =
            (f64::from(distance) / f64::from(max_position)) * full_travel_time + 10.0;
        Duration::from_secs_f64(estimated_secs.max(30.0).min(180.0))
    } else {
        Timeouts::focuser_move()
    };

    with_timeout(future, timeout_duration, focuser_id, "move").await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_timeout_success() {
        let result: Result<i32, SkotiqError> = with_timeout(
            async { Ok(42) },
            Duration::from_secs(1),
            "test_device",
            "test_op",
        )
        .await;

        assert!(result.is_ok());
        assert_eq!(result.unwrap(), 42);
    }

    #[tokio::test]
    async fn test_timeout_expiry() {
        let result: Result<i32, SkotiqError> = with_timeout(
            async {
                tokio::time::sleep(Duration::from_secs(2)).await;
                Ok(42)
            },
            Duration::from_millis(100),
            "test_device",
            "test_op",
        )
        .await;

        assert!(result.is_err());
        match result.unwrap_err() {
            SkotiqError::DeviceTimeout {
                device_id,
                operation,
                ..
            } => {
                assert_eq!(device_id, "test_device");
                assert_eq!(operation, "test_op");
            }
            _ => panic!("Expected DeviceTimeout error"),
        }
    }

    /// The ASCOM connect read-back budget must finish INSIDE this crate's own
    /// connect deadline, or the diagnostic it produces is never delivered.
    ///
    /// Every ASCOM wrapper in `ascom_wrapper` awaits its worker's `connect`
    /// reply under `Timeouts::connection()`. `AscomDeviceConnection::connect`
    /// spends up to `CONNECT_VERIFY_TIMEOUT` polling `Connected` back before it
    /// can report a phantom device (finding L4: a driver with no hardware
    /// behind it accepts `Connected = true` and then reads back false for
    /// ever). If the polling budget reaches the transport deadline, the caller
    /// has already dropped the receiver: the operator is shown the generic
    /// `"... connect timed out after 30s"` and the message naming the real
    /// causes — not powered, not plugged in, already open elsewhere — is
    /// discarded unread.
    ///
    /// That is not hypothetical. Measured on the reference rig 2026-08-09 with
    /// the budget set equal to the transport deadline, the phantom
    /// `ASCOM.ASIMount.Telescope` was correctly refused — at 30.064 s, i.e.
    /// after `Timeouts::connection()` had already fired, on every attempt.
    ///
    /// This test is the only place in the tree that can see both numbers, so it
    /// is what stops either of them drifting back into collision.
    #[test]
    fn ascom_connect_readback_budget_fits_inside_the_connection_timeout() {
        use skotiq_ascom::connect_verify::{
            CONNECT_VERIFY_TIMEOUT, CONNECT_VERIFY_TRANSPORT_HEADROOM,
        };

        let needed = CONNECT_VERIFY_TIMEOUT + CONNECT_VERIFY_TRANSPORT_HEADROOM;
        assert!(
            needed <= Timeouts::connection(),
            "ASCOM connect read-back needs {:?} ({:?} polling + {:?} for the two property \
             writes that bracket it) but the transport gives up at {:?}. The phantom-device \
             message would be composed and then thrown away, and the operator would see a bare \
             timeout instead. Lower CONNECT_VERIFY_TIMEOUT or raise Timeouts::connection().",
            needed,
            CONNECT_VERIFY_TIMEOUT,
            CONNECT_VERIFY_TRANSPORT_HEADROOM,
            Timeouts::connection(),
        );
    }
}
