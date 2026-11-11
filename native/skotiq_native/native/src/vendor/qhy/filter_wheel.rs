//! QHY CFW filter wheel implementation and discovery.

use super::*;

pub(crate) const QHYCCD_ERROR_VALUE: f64 = u32::MAX as f64;
pub(crate) const DEFAULT_QHY_CFW_SLOTS: i32 = 5;
pub(crate) const MAX_QHY_CFW_SLOTS: i32 = 16;
pub(crate) const QHY_CFW_MOVE_TIMEOUT: Duration = Duration::from_secs(25);
pub(crate) const QHY_CFW_POLL_INTERVAL: Duration = Duration::from_millis(500);

pub(crate) fn parse_cfw_slot_count(count: f64) -> Result<i32, DriverError> {
    if !count.is_finite()
        // Rejects both the SDK's u32::MAX error sentinel and a nonsensical
        // sub-one wheel; a real CFW always reports at least one slot.
        || !(1.0..QHYCCD_ERROR_VALUE).contains(&count)
        || count > f64::from(MAX_QHY_CFW_SLOTS)
        || count.fract() != 0.0
    {
        return Err(DriverError::SdkError(format!(
            "GetQHYCCDParam(CONTROL_CFWSLOTSNUM) returned invalid slot count {}",
            count
        )));
    }

    Ok(count as i32)
}

pub(crate) fn parse_cfw_position(position: f64) -> Result<i32, DriverError> {
    if !position.is_finite() || position >= QHYCCD_ERROR_VALUE || position.fract() != 0.0 {
        return Err(DriverError::SdkError(format!(
            "GetQHYCCDParam(CONTROL_CFWPORT) returned invalid position {}",
            position
        )));
    }

    match position as u8 {
        b'0'..=b'9' => Ok(i32::from(position as u8 - b'0')),
        b'A'..=b'F' => Ok(i32::from(position as u8 - b'A') + 10),
        b'a'..=b'f' => Ok(i32::from(position as u8 - b'a') + 10),
        _ => Err(DriverError::SdkError(format!(
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

pub struct QhyFilterWheelInfo {
    /// Camera ID that the filter wheel is attached to
    pub camera_id: String,
    pub name: String,
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
// against the handle goes through the `QhySdk` lock guard (CFW is controlled through the camera
// SDK and shares its lock), so the handle is never accessed concurrently.
unsafe impl Send for QhyFilterWheel {}
// SAFETY: Same justification — shared references never invoke the SDK without taking
// the `QhySdk` lock guard first.
unsafe impl Sync for QhyFilterWheel {}

impl QhyFilterWheel {
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
    pub(crate) fn check_cfw_available(&self, sdk: &QhySdk) -> Result<bool, DriverError> {
        let handle = self.handle.ok_or(DriverError::NotConnected)?;

        // SAFETY: handle
        // was validated via Option::ok_or; IsQHYCCDCFWPlugged takes only the handle.
        let result = unsafe { (sdk.is_qhyccd_cfw_plugged)(handle) };
        Ok(result == 0) // QHYCCD_SUCCESS = 0
    }

    pub(crate) fn get_slot_count(&self, sdk: &QhySdk) -> Result<i32, DriverError> {
        let handle = self.handle.ok_or(DriverError::NotConnected)?;

        // SAFETY: handle validated above;
        // CONTROL_CFWSLOTSNUM discriminant fits in c_int; GetQHYCCDParam returns c_double.
        let count =
            unsafe { (sdk.get_qhyccd_param)(handle, QhyControl::CONTROL_CFWSLOTSNUM as c_int) };

        parse_cfw_slot_count(count)
    }

    /// Get current position (0-indexed)
    pub(crate) fn get_current_position(&self, sdk: &QhySdk) -> Result<i32, DriverError> {
        let handle = self.handle.ok_or(DriverError::NotConnected)?;

        // QHY returns position as ASCII value (48 = '0', 49 = '1', etc.)
        // SAFETY: handle validated above;
        // CONTROL_CFWPORT discriminant fits in c_int.
        let pos = unsafe { (sdk.get_qhyccd_param)(handle, QhyControl::CONTROL_CFWPORT as c_int) };

        parse_cfw_position(pos)
    }

    /// Set position (0-indexed)
    pub(crate) fn set_current_position(
        &self,
        sdk: &QhySdk,
        position: i32,
    ) -> Result<(), DriverError> {
        let handle = self.handle.ok_or(DriverError::NotConnected)?;

        // QHY uses ASCII encoding ('0'..'9', then 'A'..'F').
        let ascii_position = encode_cfw_position(position);

        // SAFETY: handle validated above;
        // CONTROL_CFWPORT discriminant fits in c_int; ascii_position is pass-by-value c_double.
        // The `position` argument was bounds-checked in the caller against self.slot_count.
        let result = unsafe {
            (sdk.set_qhyccd_param)(handle, QhyControl::CONTROL_CFWPORT as c_int, ascii_position)
        };

        check_qhy_error(result, "SetCFWPosition")
    }
}

#[async_trait]
impl DeviceDriver for QhyFilterWheel {
    fn id(&self) -> &str {
        &self.device_id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn vendor(&self) -> Vendor {
        Vendor::Qhy
    }

    fn is_connected(&self) -> bool {
        self.connected
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        if self.connected {
            return Ok(());
        }

        QhySdk::ensure_initialized()?;
        let sdk = QhySdk::lock().await?;

        // Open the camera to access CFW
        let camera_id_cstr = CString::new(self.camera_id.clone())
            .map_err(|_| DriverError::InvalidParameter("Invalid camera ID".into()))?;

        // SAFETY: camera_id_cstr is a valid NUL-terminated CString that
        // outlives the call. OpenQHYCCD returns a handle we null-check immediately below.
        let handle = unsafe { (sdk.open_qhyccd)(camera_id_cstr.as_ptr()) };
        if handle.is_null() {
            return Err(DriverError::SdkError(
                "Failed to open QHY camera for CFW".into(),
            ));
        }

        self.handle = Some(handle);

        // Set stream mode and init (required for CFW access)
        // SAFETY: `handle` is the non-null pointer returned by OpenQHYCCD above;
        // mode=0 (single frame) is a documented constant per qhyccd.h; CloseQHYCCD pairs with
        // OpenQHYCCD on the error path inside the block.
        unsafe {
            (sdk.set_qhyccd_stream_mode)(handle, 0); // Single frame mode
            let init_result = (sdk.init_qhyccd)(handle);
            if init_result != 0 {
                (sdk.close_qhyccd)(handle);
                self.handle = None;
                return Err(DriverError::SdkError(
                    "Failed to initialize QHY camera for CFW".into(),
                ));
            }
        }

        // Check if CFW is available (mutex already held)
        if !self.check_cfw_available(&sdk)? {
            // SAFETY: handle was successfully opened and initialized above.
            // CloseQHYCCD pairs with OpenQHYCCD on this CFW-not-available error path.
            unsafe { (sdk.close_qhyccd)(handle) };
            self.handle = None;
            return Err(DriverError::DeviceNotFound(
                "No CFW detected on this QHY camera".into(),
            ));
        }

        // Get slot count (mutex already held)
        self.slot_count = match self.get_slot_count(&sdk) {
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

        let current_position = match self.get_current_position(&sdk) {
            Ok(position) if position < self.slot_count => position,
            Ok(position) => {
                // SAFETY: handle was successfully opened and initialized above.
                unsafe { (sdk.close_qhyccd)(handle) };
                self.handle = None;
                return Err(DriverError::SdkError(format!(
                    "QHY CFW reported position {} outside its {} slots",
                    position, self.slot_count
                )));
            }
            Err(error) => {
                // SAFETY: handle was successfully opened and initialized above.
                unsafe { (sdk.close_qhyccd)(handle) };
                self.handle = None;
                return Err(error);
            }
        };

        self.filter_names = (0..self.slot_count)
            .map(|i| format!("Filter {}", i + 1))
            .collect();
        self.target_position = Some(current_position);

        self.connected = true;
        tracing::info!("Connected to QHY CFW with {} slots", self.slot_count);

        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        if !self.connected {
            return Ok(());
        }

        // Take the lock first to avoid Send issues with raw pointer
        let lock = QhySdk::slot().lock_before_load().await;
        if let Some(handle) = self.handle.take() {
            if let Ok(sdk) = lock.table() {
                // SAFETY: handle was successfully opened during connect()
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
impl FilterWheelDriver for QhyFilterWheel {
    fn get_filter_count(&self) -> i32 {
        self.slot_count
    }

    async fn get_position(&self) -> Result<i32, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }
        let sdk = QhySdk::lock().await?;
        self.get_current_position(&sdk)
    }

    async fn move_to_position(&mut self, position: i32) -> Result<(), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        if position < 0 || position >= self.slot_count {
            return Err(DriverError::InvalidParameter(format!(
                "Position {} out of range (0-{})",
                position,
                self.slot_count - 1
            )));
        }

        tracing::info!("Moving QHY CFW to position {}", position);
        {
            let sdk = QhySdk::lock().await?;
            self.set_current_position(&sdk, position)?;
        }
        self.target_position = Some(position);

        let started = Instant::now();
        loop {
            let current_position = {
                let sdk = QhySdk::lock().await?;
                self.get_current_position(&sdk)?
            };
            if current_position == position {
                return Ok(());
            }

            let elapsed = started.elapsed();
            if elapsed >= QHY_CFW_MOVE_TIMEOUT {
                return Err(DriverError::Timeout(format!(
                    "QHY CFW did not reach position {} within {:?} (current position: {})",
                    position, QHY_CFW_MOVE_TIMEOUT, current_position
                )));
            }

            tokio::time::sleep(QHY_CFW_POLL_INTERVAL.min(QHY_CFW_MOVE_TIMEOUT - elapsed)).await;
        }
    }

    async fn is_moving(&self) -> Result<bool, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        let target_position = self.target_position.ok_or_else(|| {
            DriverError::SdkError("QHY CFW target position is unknown".to_string())
        })?;
        let sdk = QhySdk::lock().await?;
        Ok(self.get_current_position(&sdk)? != target_position)
    }

    async fn get_filter_names(&self) -> Result<Vec<String>, DriverError> {
        Ok(self.filter_names.clone())
    }

    async fn set_filter_name(&mut self, position: i32, name: String) -> Result<(), DriverError> {
        if position < 0 || position >= self.slot_count {
            return Err(DriverError::InvalidParameter(format!(
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
) -> Result<Vec<QhyFilterWheelInfo>, DriverError> {
    let sdk_version = sdk_version_from_sdk(sdk);

    // SAFETY: ScanQHYCCD takes no args.
    let num_cameras = unsafe { (sdk.scan_qhyccd)() };

    let mut filter_wheels = Vec::new();

    for i in 0..num_cameras {
        let mut id_buf = [0 as c_char; 256];
        // SAFETY: `i` is in `0..num_cameras`; id_buf is a 256-byte
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

        // SAFETY: camera_id_cstr is a valid NUL-terminated CString
        // that outlives the call; null-checked immediately below.
        let handle = unsafe { (sdk.open_qhyccd)(camera_id_cstr.as_ptr()) };
        if handle.is_null() {
            continue;
        }

        // Initialize camera to check CFW
        // SAFETY: `handle` is the non-null pointer returned by
        // OpenQHYCCD above; mode=0 is single-frame per qhyccd.h; CloseQHYCCD pairs with
        // OpenQHYCCD on the init-failed path within this block.
        unsafe {
            (sdk.set_qhyccd_stream_mode)(handle, 0);
            if (sdk.init_qhyccd)(handle) != 0 {
                (sdk.close_qhyccd)(handle);
                continue;
            }
        }

        // SAFETY: handle was opened and initialized above.
        let cfw_result = unsafe { (sdk.is_qhyccd_cfw_plugged)(handle) };

        if cfw_result == 0 {
            // SAFETY: handle was opened and initialized above;
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

        // SAFETY: handle was opened above. CloseQHYCCD pairs with
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
pub async fn discover_filter_wheels() -> Result<Vec<QhyFilterWheelInfo>, DriverError> {
    let config = get_discovery_config();

    if !config.enabled {
        tracing::debug!("QHY discovery is disabled, returning empty filter wheel list");
        return Ok(Vec::new());
    }

    QhySdk::ensure_initialized()?;

    let loaded = match QhySdk::installed() {
        Ok(sdk) => sdk,
        Err(_) => return Ok(Vec::new()),
    };

    // Hold the SDK lock for as long as this call waits for the scan
    let _scan_lock = loaded.lock().await;

    let timeout_duration = Duration::from_millis(config.timeout_ms);

    let catch_panics = config.catch_panics;
    let discovery_future = async move {
        if catch_panics {
            // Wrap SDK calls in catch_unwind for crash protection
            tokio::task::spawn_blocking(move || {
                // Unlocked on purpose: the caller's guard is held only while the
                // caller waits. After a timeout this scan keeps running on the
                // blocking thread without it, which is how QHY discovery has
                // always behaved (see the timeout handling below).
                let sdk = loaded.unlocked();
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
                        DriverError::SdkError(format!(
                            "QHY SDK crashed during CFW discovery: {}",
                            panic_msg
                        ))
                    },
                )?
            })
            .await
            .map_err(|e| DriverError::SdkError(format!("QHY CFW discovery task failed: {:?}", e)))?
        } else {
            // No panic protection, just call directly. The caller's guard is
            // still held here, see above.
            discover_filter_wheels_internal(loaded.unlocked())
        }
    };

    match tokio::time::timeout(timeout_duration, discovery_future).await {
        Ok(result) => result,
        Err(_) => {
            tracing::error!("QHY CFW discovery timed out after {}ms", config.timeout_ms);
            Err(DriverError::Timeout(format!(
                "QHY CFW discovery timed out after {}ms",
                config.timeout_ms
            )))
        }
    }
}
