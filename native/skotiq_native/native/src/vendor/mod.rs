//! Vendor-specific SDK implementations
//!
//! Each vendor module wraps their SDK and implements the native driver traits.
//!
//! ## SDK loading
//!
//! Path search + library open + symbol resolution + `OnceLock` storage is shared
//! across all vendors via [`sdk_loader`]. New vendors should use the
//! `load_vendor_sdk!` macro instead of duplicating the boilerplate.

// Shared SDK loading infrastructure (trait + macro + path-search helper).
pub mod sdk_loader;

// Camera SDKs
pub mod atik;
pub mod fli;
#[cfg(target_os = "windows")]
pub mod fujifilm;
pub mod gphoto2;
pub mod moravian;
pub mod player_one;
pub mod qhy;
pub mod svbony;
pub mod touptek;
pub mod zwo;

// Mount protocols (serial communication)
pub mod ioptron;
pub mod lx200;
pub mod skywatcher;

use crate::traits::NativeError;
use std::sync::OnceLock;
use tokio::sync::{Mutex as AsyncMutex, MutexGuard as AsyncMutexGuard};

/// Coordinates short-lived attempts to claim a serial mount port.
///
/// Discovery probes and live connections otherwise race at the OS handle: a
/// discovery sweep can open COM4 between a driver's disconnect and reconnect,
/// causing the real connection to fail with `Access is denied`. The guard is
/// intentionally held only while opening/probing a port, never for the lifetime
/// of a connected mount.
static SERIAL_MOUNT_ACCESS: OnceLock<AsyncMutex<()>> = OnceLock::new();

pub(crate) async fn serial_mount_access() -> AsyncMutexGuard<'static, ()> {
    SERIAL_MOUNT_ACCESS
        .get_or_init(|| AsyncMutex::new(()))
        .lock()
        .await
}

/// Run a serial-port scan on a blocking thread.
///
/// Serial mount discovery is entirely synchronous — `serialport` open/read plus
/// the settle sleeps every protocol needs between probes — and costs roughly a
/// second per (port, baud) pair, so a four-port machine spends ~17 s inside one
/// call. Run inline it would freeze whichever Tokio worker picked it up, along
/// with every other task scheduled there.
pub(crate) async fn run_serial_scan<T, F>(vendor: &'static str, scan: F) -> Result<T, NativeError>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, NativeError> + Send + 'static,
{
    let _serial_access = serial_mount_access().await;
    tokio::task::spawn_blocking(scan).await.unwrap_or_else(|e| {
        Err(NativeError::SdkError(format!(
            "{} mount discovery task failed: {}",
            vendor, e
        )))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    #[tokio::test(flavor = "current_thread")]
    async fn serial_scan_leaves_the_async_runtime_free_to_make_progress() {
        // The single runtime thread must service a 20 ms timer while a 200 ms
        // synchronous scan is in flight. Run the scan inline and it cannot.
        let order = Arc::new(Mutex::new(Vec::new()));

        let timer_order = order.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(20)).await;
            timer_order.lock().unwrap().push("timer");
        });

        let scan_order = order.clone();
        let scanned = run_serial_scan("test", move || {
            std::thread::sleep(Duration::from_millis(200));
            scan_order.lock().unwrap().push("scan");
            Ok(7u32)
        })
        .await
        .expect("scan failed");

        assert_eq!(scanned, 7);
        assert_eq!(
            order.lock().unwrap().as_slice(),
            &["timer", "scan"],
            "the runtime was blocked for the duration of the serial scan"
        );
    }

    #[tokio::test]
    async fn serial_scan_propagates_the_scan_error() {
        let err = run_serial_scan("test", || {
            Err::<(), _>(NativeError::SdkError("no ports".to_string()))
        })
        .await
        .expect_err("expected the scan error to surface");
        assert!(err.to_string().contains("no ports"));
    }

    #[tokio::test]
    async fn serial_scans_do_not_overlap() {
        let first_running = Arc::new(AtomicBool::new(false));
        let overlap = Arc::new(AtomicBool::new(false));

        let first_flag = Arc::clone(&first_running);
        let first = tokio::spawn(async move {
            run_serial_scan("first", move || {
                first_flag.store(true, Ordering::SeqCst);
                std::thread::sleep(Duration::from_millis(100));
                first_flag.store(false, Ordering::SeqCst);
                Ok(())
            })
            .await
        });

        tokio::time::sleep(Duration::from_millis(20)).await;
        let observed_running = Arc::clone(&first_running);
        let observed_overlap = Arc::clone(&overlap);
        let second = tokio::spawn(async move {
            run_serial_scan("second", move || {
                observed_overlap.store(observed_running.load(Ordering::SeqCst), Ordering::SeqCst);
                Ok(())
            })
            .await
        });

        first.await.unwrap().unwrap();
        second.await.unwrap().unwrap();
        assert!(!overlap.load(Ordering::SeqCst));
    }
}
