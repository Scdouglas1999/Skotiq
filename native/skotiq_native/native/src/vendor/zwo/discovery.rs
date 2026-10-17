//! ZWO camera discovery and SDK status.

use super::*;
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};
use tokio::sync::watch;

/// ZWO camera discovery info
#[derive(Clone)]
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
static DISCOVERY_IN_FLIGHT: InFlight<Vec<ZwoDiscoveryInfo>> = InFlight::new();

type Outcome<T> = Option<Result<T, NativeError>>;

/// The scan that is currently running, if any. A caller that arrives while it
/// runs subscribes to its result instead of starting a second scan: the ASI SDK
/// is not thread-safe, and equipment refreshes, the device manager and the
/// connect flow all discover at once.
struct InFlight<T>(Mutex<Option<watch::Receiver<Outcome<T>>>>);

impl<T> InFlight<T> {
    const fn new() -> Self {
        Self(Mutex::new(None))
    }

    fn clear(&self) {
        *self.0.lock().unwrap_or_else(PoisonError::into_inner) = None;
    }
}

/// Publishes the scan's outcome to every subscriber. Dropping it without a
/// result (the task was cancelled) frees the slot and wakes subscribers with a
/// closed channel.
struct Publisher<T: 'static> {
    tx: watch::Sender<Outcome<T>>,
    in_flight: &'static InFlight<T>,
}

impl<T> Publisher<T> {
    /// Send the outcome while the scan still holds the slot, so callers that
    /// arrive during a stalled SDK call share the timeout instead of queueing
    /// another scan behind it.
    fn publish(&self, outcome: Result<T, NativeError>) {
        self.tx.send_replace(Some(outcome));
    }

    /// Free the slot first, then publish: a caller arriving after this starts a
    /// fresh scan rather than reading a finished one.
    fn finish(self, outcome: Result<T, NativeError>) {
        self.in_flight.clear();
        self.publish(outcome);
    }
}

impl<T> Drop for Publisher<T> {
    fn drop(&mut self) {
        self.in_flight.clear();
    }
}

fn timed_out(deadline: Duration) -> NativeError {
    NativeError::Timeout(format!(
        "ZWO camera discovery timed out after {} seconds",
        deadline.as_secs(),
    ))
}

/// Every subscriber gets its own copy of a shared failure. Discovery only
/// produces timeouts and SDK errors, so the copy keeps the variant callers
/// branch on and the message they show.
fn shared_error(error: &NativeError) -> NativeError {
    match error {
        NativeError::Timeout(message) => NativeError::Timeout(message.clone()),
        other => NativeError::SdkError(other.to_string()),
    }
}

/// Run one discovery scan at a time and share its result with everyone who
/// asked while it ran. Both the SDK lock wait and the blocking enumeration are
/// bounded by [deadline]. A scan that overruns keeps its lock and its slot
/// until the SDK call actually returns: releasing the lock early would allow
/// concurrent calls into the non-thread-safe ASI SDK, and freeing the slot
/// would let refreshes pile scans up behind a hung driver.
async fn run_discovery<T: Clone + Send + Sync + 'static>(
    mutex: &'static tokio::sync::Mutex<()>,
    in_flight: &'static InFlight<T>,
    deadline: Duration,
    scan: impl FnOnce() -> Result<T, NativeError> + Send + 'static,
) -> Result<T, NativeError> {
    let mut outcome = {
        let mut slot = in_flight.0.lock().unwrap_or_else(PoisonError::into_inner);
        match slot.as_ref() {
            Some(running) => running.clone(),
            None => {
                let (tx, rx) = watch::channel(None);
                *slot = Some(rx.clone());
                let publisher = Publisher { tx, in_flight };
                tokio::spawn(scan_and_publish(mutex, deadline, scan, publisher));
                rx
            }
        }
    };
    let result = outcome.wait_for(Option::is_some).await.map_err(|_| {
        NativeError::SdkError("ZWO camera discovery stopped before it finished".to_string())
    })?;
    match result.as_ref() {
        Some(Ok(value)) => Ok(value.clone()),
        Some(Err(error)) => Err(shared_error(error)),
        None => unreachable!("wait_for returned before the outcome was published"),
    }
}

async fn scan_and_publish<T: Send + Sync + 'static>(
    mutex: &'static tokio::sync::Mutex<()>,
    deadline: Duration,
    scan: impl FnOnce() -> Result<T, NativeError> + Send + 'static,
    publisher: Publisher<T>,
) {
    let started = Instant::now();
    let Ok(lock) = tokio::time::timeout(deadline, mutex.lock()).await else {
        // Another camera operation owns the SDK for the whole window: give up
        // without queueing a scan behind it.
        publisher.finish(Err(timed_out(deadline)));
        return;
    };
    let mut worker = tokio::task::spawn_blocking(move || {
        let _lock = lock;
        scan()
    });
    let remaining = deadline.saturating_sub(started.elapsed());
    match tokio::time::timeout(remaining, &mut worker).await {
        Ok(joined) => publisher.finish(joined.unwrap_or_else(|error| {
            Err(NativeError::SdkError(format!(
                "ZWO discovery worker failed: {error}"
            )))
        })),
        Err(_) => {
            publisher.publish(Err(timed_out(deadline)));
            // Hold the slot until the stalled SDK call returns; the publisher's
            // drop frees it.
            let _ = worker.await;
        }
    }
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
    use std::sync::atomic::AtomicUsize;

    fn slot_is_free<T>(in_flight: &InFlight<T>) -> bool {
        in_flight
            .0
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .is_none()
    }

    #[tokio::test]
    async fn discovery_times_out_behind_a_camera_operation_without_queueing_a_scan() {
        static MUTEX: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
        static IN_FLIGHT: InFlight<i32> = InFlight::new();
        let camera_operation = MUTEX.lock().await;
        let result = run_discovery(&MUTEX, &IN_FLIGHT, Duration::from_millis(20), || {
            panic!("must not probe while another camera operation owns the SDK");
        })
        .await;
        assert!(matches!(result, Err(NativeError::Timeout(_))));
        assert!(slot_is_free(&IN_FLIGHT));
        drop(camera_operation);
        assert_eq!(
            run_discovery(&MUTEX, &IN_FLIGHT, Duration::from_secs(1), || Ok(7))
                .await
                .unwrap(),
            7
        );
    }

    #[tokio::test]
    async fn callers_that_overlap_share_one_scan() {
        static MUTEX: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
        static IN_FLIGHT: InFlight<usize> = InFlight::new();
        static SCANS: AtomicUsize = AtomicUsize::new(0);
        let (started_tx, started_rx) = tokio::sync::oneshot::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel::<()>();
        let first = tokio::spawn(run_discovery(
            &MUTEX,
            &IN_FLIGHT,
            Duration::from_secs(5),
            move || {
                started_tx.send(()).unwrap();
                release_rx.recv_timeout(Duration::from_secs(5)).unwrap();
                Ok(SCANS.fetch_add(1, Ordering::SeqCst) + 1)
            },
        ));
        started_rx.await.unwrap();
        let second = tokio::spawn(run_discovery(
            &MUTEX,
            &IN_FLIGHT,
            Duration::from_secs(5),
            || -> Result<usize, NativeError> {
                panic!("an overlapping caller must join the running scan");
            },
        ));
        // Let the second caller subscribe before the scan finishes.
        tokio::task::yield_now().await;
        release_tx.send(()).unwrap();
        assert_eq!(first.await.unwrap().unwrap(), 1);
        assert_eq!(second.await.unwrap().unwrap(), 1);
        assert_eq!(SCANS.load(Ordering::SeqCst), 1);
        assert!(slot_is_free(&IN_FLIGHT));
    }

    #[tokio::test]
    async fn stalled_sdk_scan_releases_the_caller_but_keeps_its_lock_and_blocks_duplicates() {
        static MUTEX: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
        static IN_FLIGHT: InFlight<i32> = InFlight::new();
        let (started_tx, started_rx) = tokio::sync::oneshot::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let scan = tokio::spawn(run_discovery(
            &MUTEX,
            &IN_FLIGHT,
            Duration::from_millis(500),
            move || {
                started_tx.send(()).unwrap();
                release_rx.recv_timeout(Duration::from_secs(5)).unwrap();
                Ok(1)
            },
        ));
        started_rx.await.unwrap();
        let result = scan.await.unwrap();
        let lock_still_held = MUTEX.try_lock().is_err();
        let duplicate = run_discovery(&MUTEX, &IN_FLIGHT, Duration::from_secs(1), || {
            panic!("refresh must not start another scan while the first is stalled");
        })
        .await;
        // Release the test worker before asserting so a failed test cannot
        // leave the runtime waiting for the blocking task at shutdown.
        release_tx.send(()).unwrap();
        tokio::time::timeout(Duration::from_secs(1), async {
            while !slot_is_free(&IN_FLIGHT) {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        assert!(matches!(result, Err(NativeError::Timeout(_))));
        assert!(lock_still_held);
        assert!(matches!(duplicate, Err(NativeError::Timeout(_))));
        assert_eq!(
            run_discovery(&MUTEX, &IN_FLIGHT, Duration::from_secs(1), || Ok(9))
                .await
                .unwrap(),
            9
        );
    }
}
