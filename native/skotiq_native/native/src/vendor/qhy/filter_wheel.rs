//! QHY CFW filter wheel implementation and discovery.

use super::*;

pub(crate) const QHYCCD_ERROR_VALUE: f64 = u32::MAX as f64;
pub(crate) const DEFAULT_QHY_CFW_SLOTS: i32 = 5;
pub(crate) const MAX_QHY_CFW_SLOTS: i32 = 16;
pub(crate) const QHY_CFW_MOVE_TIMEOUT: Duration = Duration::from_secs(25);
pub(crate) const QHY_CFW_POLL_INTERVAL: Duration = Duration::from_millis(500);

pub(crate) fn parse_cfw_slot_count(count: f64) -> Result<i32, NativeError> {
    if !count.is_finite()
        // Rejects both the SDK's u32::MAX error sentinel and a nonsensical
        // sub-one wheel; a real CFW always reports at least one slot.
        || !(1.0..QHYCCD_ERROR_VALUE).contains(&count)
        || count > f64::from(MAX_QHY_CFW_SLOTS)
        || count.fract() != 0.0
    {
        return Err(NativeError::SdkError(format!(
            "GetQHYCCDParam(CONTROL_CFWSLOTSNUM) returned invalid slot count {}",
            count
        )));
    }

    Ok(count as i32)
}

pub(crate) fn parse_cfw_position(position: f64) -> Result<i32, NativeError> {
    if !position.is_finite() || position >= QHYCCD_ERROR_VALUE || position.fract() != 0.0 {
        return Err(NativeError::SdkError(format!(
            "GetQHYCCDParam(CONTROL_CFWPORT) returned invalid position {}",
            position
        )));
    }

    match position as u8 {
        b'0'..=b'9' => Ok(i32::from(position as u8 - b'0')),
        b'A'..=b'F' => Ok(i32::from(position as u8 - b'A') + 10),
        b'a'..=b'f' => Ok(i32::from(position as u8 - b'a') + 10),
        _ => Err(NativeError::SdkError(format!(
            "GetQHYCCDParam(CONTROL_CFWPORT) returned invalid position {}",
            position
        ))),
    }
}

pub(crate) fn encode_cfw_position(position: i32) -> f64 {
    let value = match position {
        0..=9 => b'0' + position as u8,
        10..=15 => b'A' + (position - 10) as u8,
        _ => unreachable!("CFW position was validated against the 16-slot maximum"),
    };
    f64::from(value)
}

/// QHY CFW discovery info
pub struct QhyFilterWheelInfo {
    /// Camera ID that the filter wheel is attached to
    pub camera_id: String,
    /// Display name
    pub name: String,
    /// Number of filter slots
    pub slot_count: i32,
    /// QHY SDK version reported by the loaded native library, when available
    pub sdk_version: Option<String>,
}

/// QHY Filter Wheel implementation
/// Note: QHY CFW is controlled through the camera handle
#[derive(Debug)]
pub struct QhyFilterWheel {
    pub(crate) camera_id: String,
    pub(crate) device_id: String,
    pub(crate) name: String,
    pub(crate) handle: Option<QhyCamHandle>,
    pub(crate) connected: bool,
    pub(crate) slot_count: i32,
    pub(crate) filter_names: Vec<String>,
    pub(crate) target_position: Option<i32>,
}

// SAFETY: QhyFilterWheel contains a raw `QhyCamHandle` (`Option<*mut c_void>`). Every FFI call
// against the handle takes `qhy_mutex()` first (CFW is controlled through the camera SDK and
// shares the same global mutex), so the handle is never accessed concurrently.
unsafe impl Send for QhyFilterWheel {}
// SAFETY: Same justification — shared references never invoke the SDK without taking
// qhy_mutex() first.
unsafe impl Sync for QhyFilterWheel {}

impl QhyFilterWheel {
    /// Create a new QHY filter wheel instance
    pub fn new(camera_id: String) -> Self {
        let (model_name, _) = QhyCameraInfo::parse_id(&camera_id);
        let name = format!("{} CFW", model_name);
        let device_id = format!("native:qhy_cfw:{}", camera_id);
        Self {
            camera_id,
            device_id,
            name,
            handle: None,
            connected: false,
            slot_count: 0,
            filter_names: Vec::new(),
            target_position: None,
        }
    }

    /// Check if CFW is available (must be called after connecting to camera)
    pub(crate) fn check_cfw_available(&self) -> Result<bool, NativeError> {
        let sdk = QhySdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let handle = self.handle.ok_or(NativeError::NotConnected)?;

        // SAFETY: caller (connect / move_to_position / get_position) holds qhy_mutex(); handle
        // was validated via Option::ok_or; IsQHYCCDCFWPlugged takes only the handle.
        let result = unsafe { (sdk.is_qhyccd_cfw_plugged)(handle) };
        Ok(result == 0) // QHYCCD_SUCCESS = 0
    }

    /// Get number of filter slots
    pub(crate) fn get_slot_count(&self) -> Result<i32, NativeError> {
        let sdk = QhySdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let handle = self.handle.ok_or(NativeError::NotConnected)?;

        // SAFETY: caller (connect()) holds qhy_mutex(); handle validated above;
        // CONTROL_CFWSLOTSNUM discriminant fits in c_int; GetQHYCCDParam returns c_double.
        let count =
            unsafe { (sdk.get_qhyccd_param)(handle, QhyControl::CONTROL_CFWSLOTSNUM as c_int) };

        parse_cfw_slot_count(count)
    }

    /// Get current position (0-indexed)
    pub(crate) fn get_current_position(&self) -> Result<i32, NativeError> {
        let sdk = QhySdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let handle = self.handle.ok_or(NativeError::NotConnected)?;

        // QHY returns position as ASCII value (48 = '0', 49 = '1', etc.)
        // SAFETY: caller (get_position()) holds qhy_mutex(); handle validated above;
        // CONTROL_CFWPORT discriminant fits in c_int.
        let pos = unsafe { (sdk.get_qhyccd_param)(handle, QhyControl::CONTROL_CFWPORT as c_int) };

        parse_cfw_position(pos)
    }

    /// Set position (0-indexed)
    pub(crate) fn set_current_position(&self, position: i32) -> Result<(), NativeError> {
        let sdk = QhySdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let handle = self.handle.ok_or(NativeError::NotConnected)?;

        // QHY uses ASCII encoding ('0'..'9', then 'A'..'F').
        let ascii_position = encode_cfw_position(position);

        // SAFETY: caller (move_to_position()) holds qhy_mutex(); handle validated above;
        // CONTROL_CFWPORT discriminant fits in c_int; ascii_position is pass-by-value c_double.
        // The `position` argument was bounds-checked in the caller against self.slot_count.
        let result = unsafe {
            (sdk.set_qhyccd_param)(handle, QhyControl::CONTROL_CFWPORT as c_int, ascii_position)
        };

        check_qhy_error(result, "SetCFWPosition")
    }
}

#[async_trait]
impl NativeDevice for QhyFilterWheel {
    fn id(&self) -> &str {
        &self.device_id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn vendor(&self) -> NativeVendor {
        NativeVendor::Qhy
    }

    fn is_connected(&self) -> bool {
        self.connected
    }

    async fn connect(&mut self) -> Result<(), NativeError> {
        if self.connected {
            return Ok(());
        }

        QhySdk::ensure_initialized()?;
        let sdk = QhySdk::get().ok_or(NativeError::SdkNotLoaded)?;

        // Acquire mutex for SDK operations
        let _lock = qhy_mutex().lock().await;

        // Open the camera to access CFW
        let camera_id_cstr = CString::new(self.camera_id.clone())
            .map_err(|_| NativeError::InvalidParameter("Invalid camera ID".into()))?;

        // SAFETY: qhy_mutex held above; camera_id_cstr is a valid NUL-terminated CString that
        // outlives the call. OpenQHYCCD returns a handle we null-check immediately below.
        let handle = unsafe { (sdk.open_qhyccd)(camera_id_cstr.as_ptr()) };
        if handle.is_null() {
            return Err(NativeError::SdkError(
                "Failed to open QHY camera for CFW".into(),
            ));
        }

        self.handle = Some(handle);

        // Set stream mode and init (required for CFW access)
        // SAFETY: qhy_mutex held; `handle` is the non-null pointer returned by OpenQHYCCD above;
        // mode=0 (single frame) is a documented constant per qhyccd.h; CloseQHYCCD pairs with
        // OpenQHYCCD on the error path inside the block.
        unsafe {
            (sdk.set_qhyccd_stream_mode)(handle, 0); // Single frame mode
            let init_result = (sdk.init_qhyccd)(handle);
            if init_result != 0 {
                (sdk.close_qhyccd)(handle);
                self.handle = None;
                return Err(NativeError::SdkError(
                    "Failed to initialize QHY camera for CFW".into(),
                ));
            }
        }

        // Check if CFW is available (mutex already held)
        if !self.check_cfw_available()? {
            // SAFETY: qhy_mutex held; handle was successfully opened and initialized above.
            // CloseQHYCCD pairs with OpenQHYCCD on this CFW-not-available error path.
            unsafe { (sdk.close_qhyccd)(handle) };
            self.handle = None;
            return Err(NativeError::DeviceNotFound(
                "No CFW detected on this QHY camera".into(),
            ));
        }

        // Get slot count (mutex already held)
        self.slot_count = match self.get_slot_count() {
            Ok(count) => count,
            Err(error) => {
                tracing::warn!(
                    "Failed to detect QHY CFW slot count: {}; using {} slots",
                    error,
                    DEFAULT_QHY_CFW_SLOTS
                );
                DEFAULT_QHY_CFW_SLOTS
            }
        }
        .clamp(1, MAX_QHY_CFW_SLOTS);

        let current_position = match self.get_current_position() {
            Ok(position) if position < self.slot_count => position,
            Ok(position) => {
                // SAFETY: qhy_mutex held; handle was successfully opened and initialized above.
                unsafe { (sdk.close_qhyccd)(handle) };
                self.handle = None;
                return Err(NativeError::SdkError(format!(
                    "QHY CFW reported position {} outside its {} slots",
                    position, self.slot_count
                )));
            }
            Err(error) => {
                // SAFETY: qhy_mutex held; handle was successfully opened and initialized above.
                unsafe { (sdk.close_qhyccd)(handle) };
                self.handle = None;
                return Err(error);
            }
        };

        // Initialize filter names with defaults
        self.filter_names = (0..self.slot_count)
            .map(|i| format!("Filter {}", i + 1))
            .collect();
        self.target_position = Some(current_position);

        self.connected = true;
        tracing::info!("Connected to QHY CFW with {} slots", self.slot_count);

        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), NativeError> {
        if !self.connected {
            return Ok(());
        }

        // Acquire mutex first to avoid Send issues with raw pointer
        let _lock = qhy_mutex().lock().await;
        if let Some(handle) = self.handle.take() {
            if let Some(sdk) = QhySdk::get() {
                // SAFETY: qhy_mutex held above; handle was successfully opened during connect()
                // and stored in self.handle (None case skipped via if-let). CloseQHYCCD pairs
                // with OpenQHYCCD.
                unsafe { (sdk.close_qhyccd)(handle) };
            }
        }

        self.connected = false;
        self.target_position = None;
        tracing::info!("Disconnected from QHY CFW");

        Ok(())
    }
}

#[async_trait]
impl NativeFilterWheel for QhyFilterWheel {
    fn get_filter_count(&self) -> i32 {
        self.slot_count
    }

    async fn get_position(&self) -> Result<i32, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }
        let _lock = qhy_mutex().lock().await;
        self.get_current_position()
    }

    async fn move_to_position(&mut self, position: i32) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        if position < 0 || position >= self.slot_count {
            return Err(NativeError::InvalidParameter(format!(
                "Position {} out of range (0-{})",
                position,
                self.slot_count - 1
            )));
        }

        tracing::info!("Moving QHY CFW to position {}", position);
        {
            let _lock = qhy_mutex().lock().await;
            self.set_current_position(position)?;
        }
        self.target_position = Some(position);

        let started = Instant::now();
        loop {
            let current_position = {
                let _lock = qhy_mutex().lock().await;
                self.get_current_position()?
            };
            if current_position == position {
                return Ok(());
            }

            let elapsed = started.elapsed();
            if elapsed >= QHY_CFW_MOVE_TIMEOUT {
                return Err(NativeError::Timeout(format!(
                    "QHY CFW did not reach position {} within {:?} (current position: {})",
                    position, QHY_CFW_MOVE_TIMEOUT, current_position
                )));
            }

            tokio::time::sleep(QHY_CFW_POLL_INTERVAL.min(QHY_CFW_MOVE_TIMEOUT - elapsed)).await;
        }
    }

    async fn is_moving(&self) -> Result<bool, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let target_position = self.target_position.ok_or_else(|| {
            NativeError::SdkError("QHY CFW target position is unknown".to_string())
        })?;
        let _lock = qhy_mutex().lock().await;
        Ok(self.get_current_position()? != target_position)
    }

    async fn get_filter_names(&self) -> Result<Vec<String>, NativeError> {
        Ok(self.filter_names.clone())
    }

    async fn set_filter_name(&mut self, position: i32, name: String) -> Result<(), NativeError> {
        if position < 0 || position >= self.slot_count {
            return Err(NativeError::InvalidParameter(format!(
                "Position {} out of range (0-{})",
                position,
                self.slot_count - 1
            )));
        }
        // Why: bounds checked `0 <= position < self.slot_count` above; position is i32,
        // self.filter_names is a Vec sized to slot_count, so `as usize` is widening with
        // verified non-negative value.
        self.filter_names[position as usize] = name;
        Ok(())
    }
}

/// Internal function to perform the actual CFW discovery.
pub(crate) fn discover_filter_wheels_internal(
    sdk: &QhySdk,
) -> Result<Vec<QhyFilterWheelInfo>, NativeError> {
    let sdk_version = sdk_version_from_sdk(sdk);

    // Scan for cameras
    // SAFETY: caller (discover_filter_wheels) holds qhy_mutex(); ScanQHYCCD takes no args.
    let num_cameras = unsafe { (sdk.scan_qhyccd)() };

    let mut filter_wheels = Vec::new();

    for i in 0..num_cameras {
        let mut id_buf = [0 as c_char; 256];
        // SAFETY: caller holds qhy_mutex(); `i` is in `0..num_cameras`; id_buf is a 256-byte
        // stack array.
        let result = unsafe { (sdk.get_qhyccd_id)(i, id_buf.as_mut_ptr()) };

        if result != 0 {
            continue;
        }

        // SAFETY: id_buf is 256 bytes; GetQHYCCDId guaranteed NUL-termination on success.
        let camera_id = unsafe { CStr::from_ptr(id_buf.as_ptr()) }
            .to_string_lossy()
            .to_string();

        // Open camera temporarily to check for CFW
        let camera_id_cstr = match CString::new(camera_id.clone()) {
            Ok(s) => s,
            Err(_) => continue,
        };

        // SAFETY: caller holds qhy_mutex(); camera_id_cstr is a valid NUL-terminated CString
        // that outlives the call; null-checked immediately below.
        let handle = unsafe { (sdk.open_qhyccd)(camera_id_cstr.as_ptr()) };
        if handle.is_null() {
            continue;
        }

        // Initialize camera to check CFW
        // SAFETY: caller holds qhy_mutex(); `handle` is the non-null pointer returned by
        // OpenQHYCCD above; mode=0 is single-frame per qhyccd.h; CloseQHYCCD pairs with
        // OpenQHYCCD on the init-failed path within this block.
        unsafe {
            (sdk.set_qhyccd_stream_mode)(handle, 0);
            if (sdk.init_qhyccd)(handle) != 0 {
                (sdk.close_qhyccd)(handle);
                continue;
            }
        }

        // Check if CFW is plugged in
        // SAFETY: caller holds qhy_mutex(); handle was opened and initialized above.
        let cfw_result = unsafe { (sdk.is_qhyccd_cfw_plugged)(handle) };

        if cfw_result == 0 {
            // CFW is available
            // SAFETY: caller holds qhy_mutex(); handle was opened and initialized above;
            // CONTROL_CFWSLOTSNUM discriminant fits in c_int.
            let raw_slot_count =
                unsafe { (sdk.get_qhyccd_param)(handle, QhyControl::CONTROL_CFWSLOTSNUM as c_int) };
            let slot_count = parse_cfw_slot_count(raw_slot_count).unwrap_or_else(|error| {
                tracing::warn!(
                    "Failed to detect QHY CFW slot count for {}: {}; using {} slots",
                    camera_id,
                    error,
                    DEFAULT_QHY_CFW_SLOTS
                );
                DEFAULT_QHY_CFW_SLOTS
            });

            let (model_name, _) = QhyCameraInfo::parse_id(&camera_id);

            filter_wheels.push(QhyFilterWheelInfo {
                camera_id: camera_id.clone(),
                name: format!("{} CFW", model_name),
                slot_count,
                sdk_version: sdk_version.clone(),
            });

            tracing::info!(
                "Found QHY CFW on camera {} with {} slots",
                camera_id,
                slot_count
            );
        }

        // Close camera
        // SAFETY: caller holds qhy_mutex(); handle was opened above. CloseQHYCCD pairs with
        // OpenQHYCCD to release the SDK-owned handle at the end of the per-camera probe.
        unsafe { (sdk.close_qhyccd)(handle) };
    }

    Ok(filter_wheels)
}

/// Discover QHY filter wheels (CFW attached to cameras) with safety measures.
///
/// Uses the same safety measures as `discover_devices()`:
/// - Enable/disable check
/// - Panic protection via catch_unwind
/// - Timeout from quirks database
/// - Mutex serialization
pub async fn discover_filter_wheels() -> Result<Vec<QhyFilterWheelInfo>, NativeError> {
    let config = get_discovery_config();

    // Check if discovery is enabled
    if !config.enabled {
        tracing::debug!("QHY discovery is disabled, returning empty filter wheel list");
        return Ok(Vec::new());
    }

    // Ensure SDK is initialized
    QhySdk::ensure_initialized()?;

    // Verify SDK is available before proceeding
    if QhySdk::get().is_none() {
        return Ok(Vec::new());
    }

    // Acquire mutex for SDK discovery operations
    let _lock = qhy_mutex().lock().await;

    // Create the timeout duration from config
    let timeout_duration = Duration::from_millis(config.timeout_ms);

    // Perform discovery with timeout
    let catch_panics = config.catch_panics;
    let discovery_future = async move {
        if catch_panics {
            // Wrap SDK calls in catch_unwind for crash protection
            // We get the SDK inside the blocking task to avoid Send issues with raw pointers
            tokio::task::spawn_blocking(move || {
                // Get SDK inside the blocking task - this is safe because SDK is 'static
                let sdk = match QhySdk::get() {
                    Some(s) => s,
                    None => return Err(NativeError::SdkNotLoaded),
                };
                catch_unwind(AssertUnwindSafe(|| discover_filter_wheels_internal(sdk))).map_err(
                    |panic_info| {
                        let panic_msg = if let Some(s) = panic_info.downcast_ref::<&str>() {
                            s.to_string()
                        } else if let Some(s) = panic_info.downcast_ref::<String>() {
                            s.clone()
                        } else {
                            "Unknown panic".to_string()
                        };
                        tracing::error!("QHY SDK panicked during CFW discovery: {}", panic_msg);
                        NativeError::SdkError(format!(
                            "QHY SDK crashed during CFW discovery: {}",
                            panic_msg
                        ))
                    },
                )?
            })
            .await
            .map_err(|e| NativeError::SdkError(format!("QHY CFW discovery task failed: {:?}", e)))?
        } else {
            // No panic protection, just call directly (SDK is 'static, so we can get it again)
            let sdk = QhySdk::get().ok_or(NativeError::SdkNotLoaded)?;
            discover_filter_wheels_internal(sdk)
        }
    };

    // Apply timeout
    match tokio::time::timeout(timeout_duration, discovery_future).await {
        Ok(result) => result,
        Err(_) => {
            tracing::error!("QHY CFW discovery timed out after {}ms", config.timeout_ms);
            Err(NativeError::Timeout(format!(
                "QHY CFW discovery timed out after {}ms",
                config.timeout_ms
            )))
        }
    }
}
