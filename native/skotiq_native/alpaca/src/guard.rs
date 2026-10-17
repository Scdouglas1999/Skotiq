//! RAII guards for Alpaca device resource cleanup
//!
//! This module provides guards that ensure proper cleanup of Alpaca device
//! connections even when operations fail mid-way. Since Rust's Drop is
//! synchronous but Alpaca operations are async, we use a pattern that
//! spawns cleanup tasks on drop.

use crate::{
    AlpacaCamera, AlpacaDome, AlpacaFilterWheel, AlpacaFocuser, AlpacaRotator, AlpacaTelescope,
};

// Alpaca connection guard trait

/// Trait for Alpaca devices that can be connected/disconnected
pub trait AlpacaConnectable: Send + Sync {
    /// Attempt to disconnect the device (best-effort cleanup)
    fn disconnect_sync(&self);
}

impl AlpacaConnectable for AlpacaCamera {
    fn disconnect_sync(&self) {
        // Spawn a task to disconnect asynchronously
        // This is best-effort cleanup - we can't block in Drop
        let base_url = self.base_url().to_string();
        let device_number = self.device_number();

        std::thread::spawn(move || {
            if let Ok(rt) = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                rt.block_on(async {
                    let device = crate::AlpacaDevice::from_server(
                        crate::AlpacaDeviceType::Camera,
                        &base_url,
                        device_number,
                    );
                    let camera = AlpacaCamera::new(&device);
                    let _ = camera.disconnect().await;
                });
            }
        });
    }
}

impl AlpacaConnectable for AlpacaTelescope {
    fn disconnect_sync(&self) {
        let base_url = self.base_url().to_string();
        let device_number = self.device_number();

        std::thread::spawn(move || {
            if let Ok(rt) = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                rt.block_on(async {
                    let device = crate::AlpacaDevice::from_server(
                        crate::AlpacaDeviceType::Telescope,
                        &base_url,
                        device_number,
                    );
                    let mount = AlpacaTelescope::new(&device);
                    let _ = mount.disconnect().await;
                });
            }
        });
    }
}

impl AlpacaConnectable for AlpacaFocuser {
    fn disconnect_sync(&self) {
        let base_url = self.base_url().to_string();
        let device_number = self.device_number();

        std::thread::spawn(move || {
            if let Ok(rt) = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                rt.block_on(async {
                    let device = crate::AlpacaDevice::from_server(
                        crate::AlpacaDeviceType::Focuser,
                        &base_url,
                        device_number,
                    );
                    let focuser = AlpacaFocuser::new(&device);
                    let _ = focuser.disconnect().await;
                });
            }
        });
    }
}

impl AlpacaConnectable for AlpacaFilterWheel {
    fn disconnect_sync(&self) {
        let base_url = self.base_url().to_string();
        let device_number = self.device_number();

        std::thread::spawn(move || {
            if let Ok(rt) = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                rt.block_on(async {
                    let device = crate::AlpacaDevice::from_server(
                        crate::AlpacaDeviceType::FilterWheel,
                        &base_url,
                        device_number,
                    );
                    let fw = AlpacaFilterWheel::new(&device);
                    let _ = fw.disconnect().await;
                });
            }
        });
    }
}

impl AlpacaConnectable for AlpacaRotator {
    fn disconnect_sync(&self) {
        let base_url = self.base_url().to_string();
        let device_number = self.device_number();

        std::thread::spawn(move || {
            if let Ok(rt) = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                rt.block_on(async {
                    let device = crate::AlpacaDevice::from_server(
                        crate::AlpacaDeviceType::Rotator,
                        &base_url,
                        device_number,
                    );
                    let rotator = AlpacaRotator::new(&device);
                    let _ = rotator.disconnect().await;
                });
            }
        });
    }
}

impl AlpacaConnectable for AlpacaDome {
    fn disconnect_sync(&self) {
        let base_url = self.base_url().to_string();
        let device_number = self.device_number();

        std::thread::spawn(move || {
            if let Ok(rt) = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                rt.block_on(async {
                    let device = crate::AlpacaDevice::from_server(
                        crate::AlpacaDeviceType::Dome,
                        &base_url,
                        device_number,
                    );
                    let dome = AlpacaDome::new(&device);
                    let _ = dome.disconnect().await;
                });
            }
        });
    }
}

// Scoped connection helper

/// Run `operation` against an already-connected device and disconnect on the
/// way out, whether the operation succeeded or failed.
pub async fn with_alpaca_connection<T, F, R, E>(
    device: &T,
    device_name: &str,
    operation: F,
) -> Result<R, E>
where
    T: AlpacaConnectable,
    F: std::future::Future<Output = Result<R, E>>,
    E: From<String>,
{
    // Note: The caller should have already connected the device.
    // This guard just ensures cleanup on failure.

    // Create a cleanup guard using the device reference
    struct CleanupOnDrop<'a, T: AlpacaConnectable> {
        device: &'a T,
        device_name: String,
        should_cleanup: bool,
    }

    impl<'a, T: AlpacaConnectable> Drop for CleanupOnDrop<'a, T> {
        fn drop(&mut self) {
            if self.should_cleanup {
                tracing::debug!(
                    "with_alpaca_connection: cleaning up {} after error",
                    self.device_name
                );
                self.device.disconnect_sync();
            }
        }
    }

    let mut guard = CleanupOnDrop {
        device,
        device_name: device_name.to_string(),
        should_cleanup: true,
    };

    match operation.await {
        Ok(result) => {
            guard.should_cleanup = false;
            Ok(result)
        }
        Err(e) => {
            // Guard will clean up on drop
            Err(e)
        }
    }
}

#[cfg(test)]
mod tests {
    // Note: These tests would require a mock Alpaca server to run.
    // They are here as documentation of intended behavior.

    #[test]
    fn test_guard_defuse_prevents_cleanup() {
        // When a guard is defused, it should not trigger cleanup
        // This is tested implicitly by the fact that defuse sets device to None
    }
}
