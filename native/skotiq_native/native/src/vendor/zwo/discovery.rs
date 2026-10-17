//! ZWO camera discovery and SDK status.

use super::*;
use std::time::Duration;

/// ZWO camera discovery info
pub struct ZwoDiscoveryInfo {
    /// Stable SDK CameraID used by ASIOpenCamera and all subsequent operations.
    pub camera_id: i32,
    pub name: String,
    /// Discovery index (0-based) for disambiguation when multiple same-model cameras
    /// ZWO SDK doesn't expose serial numbers, so we use index instead
    pub discovery_index: usize,
    /// ZWO ASI SDK version reported by the loaded native library
    pub sdk_version: Option<String>,
}

/// Check if ZWO SDK is available
pub fn is_sdk_available() -> bool {
    AsiSdk::get().is_some()
}

/// Check if ZWO SDK is loaded and return status message
pub fn get_sdk_status() -> (bool, String) {
    match AsiSdk::get() {
        Some(sdk) => (
            true,
            asi_sdk_version_from_sdk(sdk)
                .map(|version| format!("{version} loaded successfully"))
                .unwrap_or_else(|| "ZWO ASI SDK loaded successfully".to_string()),
        ),
        None => (false, "ZWO ASI SDK (ASICamera2.dll) not found. Install the ASI SDK or use ASCOM drivers instead.".to_string()),
    }
}

pub(crate) fn asi_sdk_version_from_sdk(sdk: &AsiSdk) -> Option<String> {
    // SAFETY: ASIGetSDKVersion takes no arguments and returns a static C string.
    sdk_static_cstr(unsafe { (sdk.get_sdk_version)() })
        .map(|version| format!("ZWO ASI SDK v{version}"))
}

const DISCOVERY_TIMEOUT: Duration = Duration::from_secs(10);
static DISCOVERY_IN_FLIGHT: AtomicBool = AtomicBool::new(false);

struct DiscoveryPermit(&'static AtomicBool);

impl Drop for DiscoveryPermit {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

/// Bound both the SDK lock wait and the blocking enumeration call. A timed-out
/// SDK call keeps its lock and permit until it actually returns: releasing the
/// lock early would allow concurrent calls into the non-thread-safe ASI SDK.
async fn run_discovery<T: Send + 'static>(
    mutex: &'static tokio::sync::Mutex<()>,
    in_flight: &'static AtomicBool,
    deadline: Duration,
    scan: impl FnOnce() -> Result<T, NativeError> + Send + 'static,
) -> Result<T, NativeError> {
    in_flight
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .map_err(|_| {
            NativeError::SdkError("Previous ZWO camera discovery is still running".to_string())
        })?;
    let permit = DiscoveryPermit(in_flight);
    let operation = async move {
        let lock = mutex.lock().await;
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            let _lock = lock;
            scan()
        })
        .await
        .map_err(|error| NativeError::SdkError(format!("ZWO discovery worker failed: {error}")))?
    };
    tokio::time::timeout(deadline, operation)
        .await
        .map_err(|_| {
            NativeError::Timeout(format!(
                "ZWO camera discovery timed out after {} seconds",
                deadline.as_secs(),
            ))
        })?
}

/// Discover ZWO cameras without blocking discovery of other equipment.
pub async fn discover_devices() -> Result<Vec<ZwoDiscoveryInfo>, NativeError> {
    run_discovery(
        zwo_camera_mutex(),
        &DISCOVERY_IN_FLIGHT,
        DISCOVERY_TIMEOUT,
        discover_devices_locked,
    )
    .await
}

fn discover_devices_locked() -> Result<Vec<ZwoDiscoveryInfo>, NativeError> {
    let sdk = match AsiSdk::get() {
        Some(sdk) => sdk,
        None => {
            // Log prominently so users know why discovery returned nothing
            tracing::debug!("ZWO native camera discovery skipped: ASI SDK not loaded");
            return Ok(Vec::new());
        }
    };

    let sdk_version = asi_sdk_version_from_sdk(sdk);

    tracing::debug!("Discovering ZWO cameras via native ASI SDK...");
    // SAFETY: caller holds zwo_camera_mutex; ASIGetNumOfConnectedCameras takes no arguments and only reads internal SDK state.
    let num_cameras = unsafe { (sdk.get_num_cameras)() };
    tracing::debug!(
        "ASI SDK reports {} connected camera{}",
        num_cameras,
        if num_cameras == 1 { "" } else { "s" }
    );

    let mut cameras = Vec::new();
    let mut failed_count = 0;

    for i in 0..num_cameras {
        // SAFETY: ASICameraInfo is `#[repr(C)]` POD; zeroed is a valid initial state before SDK populates it.
        let mut info: ASICameraInfo = unsafe { std::mem::zeroed() };
        // ASIGetCameraProperty(ASI_CAMERA_INFO *pASICameraInfo, int iCameraIndex)
        // SAFETY: caller holds zwo_camera_mutex; `i` is bounded by num_cameras returned by the SDK; `info` is a valid stack pointer.
        let result = unsafe { (sdk.get_camera_property)(&mut info, i) };

        if result == 0 {
            // SAFETY: ASI SDK guarantees `info.name` is a NUL-terminated UTF-8 string within the 64-byte array; to_string_lossy handles any non-UTF8 bytes by replacing them.
            let name = unsafe {
                CStr::from_ptr(info.name.as_ptr())
                    .to_string_lossy()
                    .to_string()
            };
            tracing::info!(
                "Found ZWO camera: {} (ID: {}, index: {})",
                name,
                info.camera_id,
                i
            );

            cameras.push(ZwoDiscoveryInfo {
                camera_id: info.camera_id,
                name,
                // Why: `i` ranges 0..num_cameras (c_int) and is non-negative by loop
                // bound; ZWO advertises a small camera count (<= ~10). `as usize` is
                // widening with verified non-negative value.
                discovery_index: i as usize,
                sdk_version: sdk_version.clone(),
            });
        } else {
            failed_count += 1;
            let error_desc = match result {
                1 => "INVALID_INDEX - camera may be in use by another application",
                2 => "INVALID_ID",
                3 => "INVALID_CONTROL_TYPE",
                4 => "CAMERA_CLOSED",
                5 => "CAMERA_REMOVED - camera was disconnected",
                6 => "INVALID_PATH",
                7 => "INVALID_FILEFORMAT",
                8 => "INVALID_SIZE",
                9 => "INVALID_IMGTYPE",
                10 => "OUTOF_BOUNDARY",
                11 => "TIMEOUT",
                12 => "INVALID_SEQUENCE",
                13 => "BUFFER_TOO_SMALL",
                14 => "VIDEO_MODE_ACTIVE",
                15 => "EXPOSURE_IN_PROGRESS",
                16 => "GENERAL_ERROR - camera may be in use by another application",
                17 => "INVALID_MODE",
                18 => "GPS_NOT_SUPPORTED",
                19 => "GPS_VER_ERROR",
                20 => "GPS_FPGA_ERROR",
                21 => "GPS_DATA_ERROR",
                22 => "END",
                _ => "UNKNOWN",
            };
            tracing::warn!(
                "Failed to query camera index {}: ASI error {} ({})",
                i,
                result,
                error_desc
            );
        }
    }

    if cameras.is_empty() && num_cameras > 0 {
        tracing::error!(
            "ASI SDK detected {} camera{} but none could be queried. \
            Check the per-camera SDK errors above for disconnection, timeout, or access failures.",
            num_cameras,
            if num_cameras == 1 { "" } else { "s" }
        );
    } else if failed_count > 0 {
        tracing::warn!(
            "Successfully discovered {} of {} cameras. {} camera{} may be in use by other software.",
            cameras.len(),
            num_cameras,
            failed_count,
            if failed_count == 1 { "" } else { "s" }
        );
    }

    Ok(cameras)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn discovery_times_out_behind_a_camera_operation_without_queueing_a_scan() {
        static MUTEX: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
        static IN_FLIGHT: AtomicBool = AtomicBool::new(false);
        let camera_operation = MUTEX.lock().await;
        let result = run_discovery(
            &MUTEX,
            &IN_FLIGHT,
            Duration::from_millis(20),
            || -> Result<(), NativeError> {
                panic!("must not probe while another camera operation owns the SDK");
            },
        )
        .await;
        assert!(matches!(result, Err(NativeError::Timeout(_))));
        assert!(!IN_FLIGHT.load(Ordering::Acquire));
        drop(camera_operation);
        assert_eq!(
            run_discovery(&MUTEX, &IN_FLIGHT, Duration::from_secs(1), || Ok(7))
                .await
                .unwrap(),
            7
        );
    }

    #[tokio::test]
    async fn stalled_sdk_scan_releases_the_caller_but_keeps_its_lock_and_blocks_duplicates() {
        static MUTEX: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
        static IN_FLIGHT: AtomicBool = AtomicBool::new(false);
        let (started_tx, started_rx) = tokio::sync::oneshot::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let scan = tokio::spawn(run_discovery(
            &MUTEX,
            &IN_FLIGHT,
            Duration::from_millis(500),
            move || {
                started_tx.send(()).unwrap();
                release_rx.recv_timeout(Duration::from_secs(5)).unwrap();
                Ok(())
            },
        ));
        started_rx.await.unwrap();
        let result = scan.await.unwrap();
        let lock_still_held = MUTEX.try_lock().is_err();
        let duplicate = run_discovery(
            &MUTEX,
            &IN_FLIGHT,
            Duration::from_secs(1),
            || -> Result<(), NativeError> {
                panic!("refresh must not start another scan while the first is stalled");
            },
        )
        .await;
        // Release the test worker before asserting so a failed test cannot
        // leave the runtime waiting for the blocking task at shutdown.
        release_tx.send(()).unwrap();
        tokio::time::timeout(Duration::from_secs(1), async {
            while IN_FLIGHT.load(Ordering::Acquire) {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        assert!(matches!(result, Err(NativeError::Timeout(_))));
        assert!(lock_still_held);
        assert!(matches!(duplicate, Err(NativeError::SdkError(_))));
        assert_eq!(
            run_discovery(&MUTEX, &IN_FLIGHT, Duration::from_secs(1), || Ok(9))
                .await
                .unwrap(),
            9
        );
    }
}
