//! ZWO EFW filter wheel: SDK, device implementation and discovery.

use super::*;
use crate::load_vendor_sdk;
use crate::vendor::sdk_loader::vendor_library_candidates;
use std::path::PathBuf;

// EFW filter wheel SDK

/// EFW Info structure from SDK
#[repr(C)]
#[derive(Debug, Clone)]
pub(crate) struct EFWInfo {
    pub(crate) id: c_int,
    pub(crate) name: [c_char; 64],
    pub(crate) slot_num: c_int,
}

/// EFW Error codes
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
#[allow(non_camel_case_types, dead_code)]
pub(crate) enum EFWError {
    EFW_SUCCESS = 0,
    EFW_ERROR_INVALID_INDEX = 1,
    EFW_ERROR_INVALID_ID = 2,
    EFW_ERROR_INVALID_VALUE = 3,
    EFW_ERROR_REMOVED = 4,
    EFW_ERROR_MOVING = 5,
    EFW_ERROR_ERROR_STATE = 6,
    EFW_ERROR_GENERAL_ERROR = 7,
    EFW_ERROR_NOT_SUPPORTED = 8,
    EFW_ERROR_CLOSED = 9,
    EFW_ERROR_END = -1,
}

/// EFW ID/Serial Number structure
#[repr(C)]
#[derive(Debug, Clone)]
pub(crate) struct EFWSerialNumber {
    pub(crate) id: [c_uchar; 8],
}

/// Candidate library paths for the ZWO EFW (electronic filter wheel) SDK.
pub(crate) fn efw_candidate_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if cfg!(target_os = "windows") {
        paths.push(PathBuf::from("EFW_filter.dll"));
    } else if cfg!(target_os = "macos") {
        paths.push(PathBuf::from("libEFW_filter.dylib"));
    } else {
        paths.extend(vendor_library_candidates(
            // Accept the filename used by Arch's libasi package as well as
            // the historical name from ZWO's SDK archive.
            &["libEFW_filter.so", "libEFWFilter.so"],
            &[
                "/usr/lib/libEFW_filter.so",
                "/usr/lib/libEFWFilter.so",
                "/usr/local/lib/libEFW_filter.so",
                "/usr/local/lib/libEFWFilter.so",
            ],
        ));
    }
    paths
}

load_vendor_sdk! {
    /// ZWO EFW Filter Wheel SDK function-pointer table.
    vendor_name: "ZWO EFW Filter Wheel",
    sdk_struct: EfwSdk,
    sdk_static: EFW_SDK,
    candidate_paths_fn: efw_candidate_paths,
    symbols: {
        get_num: b"EFWGetNum\0"
            => unsafe extern "C" fn() -> c_int,
        get_id: b"EFWGetID\0"
            => unsafe extern "C" fn(c_int, *mut c_int) -> c_int,
        open: b"EFWOpen\0"
            => unsafe extern "C" fn(c_int) -> c_int,
        close: b"EFWClose\0"
            => unsafe extern "C" fn(c_int) -> c_int,
        get_property: b"EFWGetProperty\0"
            => unsafe extern "C" fn(c_int, *mut EFWInfo) -> c_int,
        get_position: b"EFWGetPosition\0"
            => unsafe extern "C" fn(c_int, *mut c_int) -> c_int,
        set_position: b"EFWSetPosition\0"
            => unsafe extern "C" fn(c_int, c_int) -> c_int,
        set_direction: b"EFWSetDirection\0"
            => unsafe extern "C" fn(c_int, bool) -> c_int,
        get_direction: b"EFWGetDirection\0"
            => unsafe extern "C" fn(c_int, *mut bool) -> c_int,
        calibrate: b"EFWCalibrate\0"
            => unsafe extern "C" fn(c_int) -> c_int,
        get_sdk_version: b"EFWGetSDKVersion\0"
            => unsafe extern "C" fn() -> *const c_char,
        get_hw_error_code: b"EFWGetHWErrorCode\0"
            => unsafe extern "C" fn(c_int, *mut c_int) -> c_int,
        get_firmware_version: b"EFWGetFirmwareVersion\0"
            => unsafe extern "C" fn(c_int, *mut c_uchar, *mut c_uchar, *mut c_uchar) -> c_int,
        get_serial_number: b"EFWGetSerialNumber\0"
            => unsafe extern "C" fn(c_int, *mut EFWSerialNumber) -> c_int,
    }
}

/// Check EFW error code and convert to NativeError
pub(crate) fn check_efw_error(code: c_int) -> Result<(), NativeError> {
    match code {
        0 => Ok(()),
        1 => Err(NativeError::InvalidDevice(
            "EFW_ERROR_INVALID_INDEX".to_string(),
        )),
        2 => Err(NativeError::InvalidDevice(
            "EFW_ERROR_INVALID_ID".to_string(),
        )),
        3 => Err(NativeError::InvalidParameter(
            "EFW_ERROR_INVALID_VALUE".to_string(),
        )),
        4 => Err(NativeError::Disconnected),
        5 => Err(NativeError::SdkError(
            "EFW_ERROR_MOVING: Filter wheel is moving".to_string(),
        )),
        6 => Err(NativeError::SdkError(
            "EFW_ERROR_ERROR_STATE: Filter wheel in error state".to_string(),
        )),
        7 => Err(NativeError::SdkError("EFW_ERROR_GENERAL_ERROR".to_string())),
        8 => Err(NativeError::NotSupported),
        9 => Err(NativeError::NotConnected),
        _ => Err(NativeError::SdkError(format!(
            "Unknown EFW error code: {}",
            code
        ))),
    }
}

// Filter wheel implementation

/// ZWO EFW Filter Wheel implementation
#[derive(Debug)]
pub struct ZwoFilterWheel {
    pub(crate) filterwheel_id: i32,
    pub(crate) device_id: String,
    pub(crate) connected: bool,
    pub(crate) slot_count: i32,
    pub(crate) name: String,
    pub(crate) filter_names: Vec<String>,
    pub(crate) settle_after_move_pending: AtomicBool,
}

impl ZwoFilterWheel {
    /// Create a new ZWO filter wheel instance
    pub fn new(filterwheel_id: i32) -> Self {
        Self {
            filterwheel_id,
            device_id: format!("native:zwo:efw:{}", filterwheel_id),
            connected: false,
            slot_count: 0,
            name: format!("ZWO EFW {}", filterwheel_id),
            filter_names: Vec::new(),
            settle_after_move_pending: AtomicBool::new(false),
        }
    }

    pub(crate) async fn read_position_once(&self) -> Result<i32, NativeError> {
        let sdk = EfwSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let _lock = zwo_efw_mutex().lock().await;
        let mut position: c_int = -999;
        // SAFETY: zwo_efw_mutex held; `position` is a valid stack pointer and
        // filterwheel_id is valid while this filter wheel is connected.
        let result = unsafe { (sdk.get_position)(self.filterwheel_id, &mut position) };
        check_efw_error(result)?;
        Ok(position)
    }

    /// Read EFW position without consuming the post-move settle during motion.
    ///
    /// A non-moving result is re-read after the configured delay. If that
    /// confirmation says the wheel is still moving, the settle remains pending
    /// so the full delay is applied again after actual completion.
    pub(crate) async fn read_position_settled(&self) -> Result<i32, NativeError> {
        let position = self.read_position_once().await?;
        if position == -1 || !self.settle_after_move_pending.load(Ordering::Acquire) {
            return Ok(position);
        }

        match crate::quirks::get_position_delay_after_move_ms(&self.device_id) {
            Some(delay_ms) if delay_ms > 0 => {
                tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
            }
            Some(_) => {}
            None => {
                tracing::warn!(
                    "ZWO EFW {} has no DelayAfterMoveMs quirk entry; skipping post-move settle (callers may observe stale slot index).",
                    self.device_id
                );
            }
        }

        let confirmed_position = self.read_position_once().await?;
        if confirmed_position != -1 {
            self.settle_after_move_pending
                .store(false, Ordering::Release);
        }
        Ok(confirmed_position)
    }
}

#[async_trait]
impl NativeDevice for ZwoFilterWheel {
    fn id(&self) -> &str {
        &self.device_id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn vendor(&self) -> NativeVendor {
        NativeVendor::Zwo
    }

    fn is_connected(&self) -> bool {
        self.connected
    }

    async fn connect(&mut self) -> Result<(), NativeError> {
        tracing::info!(
            "Connecting to ZWO EFW filter wheel ID {}...",
            self.filterwheel_id
        );

        let sdk = EfwSdk::get().ok_or_else(|| {
            tracing::error!("Cannot connect to ZWO EFW: EFW SDK not loaded");
            NativeError::SdkNotLoaded
        })?;

        // Acquire mutex for EFW SDK operations
        let _lock = zwo_efw_mutex().lock().await;

        // EFWGetNum/EFWGetID populate the vendor SDK's internal ID table.
        // A profile can connect a persisted hardware ID before any discovery
        // has run; on real ZWO SDK builds, calling EFWOpen directly in that
        // state returns EFW_ERROR_INVALID_ID even though the wheel is present.
        // SAFETY: zwo_efw_mutex is held (acquired above), so no other task is inside
        // the EFW SDK while it re-scans its internal ID table. EFWGetNum takes no
        // arguments and returns a c_int, so there is no pointer to invalidate, and
        // `sdk` comes from the process-lifetime EfwSdk singleton whose library is
        // never unloaded.
        let num_wheels = unsafe { (sdk.get_num)() };
        let mut id_is_present = false;
        for index in 0..num_wheels {
            let mut discovered_id: c_int = -1;
            // SAFETY: zwo_efw_mutex is held, index is bounded by EFWGetNum,
            // and discovered_id is a valid output pointer.
            let result = unsafe { (sdk.get_id)(index, &mut discovered_id) };
            if result == 0 && discovered_id == self.filterwheel_id {
                id_is_present = true;
                break;
            }
        }
        if !id_is_present {
            let reported = num_wheels.max(0);
            return Err(NativeError::DeviceNotFound(format!(
                "ZWO EFW ID {} is not present (SDK reported {} wheel{})",
                self.filterwheel_id,
                reported,
                if reported == 1 { "" } else { "s" }
            )));
        }

        // Open filter wheel
        // SAFETY: zwo_efw_mutex held above; filterwheel_id was matched against
        // the SDK-issued IDs immediately above.
        let result = unsafe { (sdk.open)(self.filterwheel_id) };
        check_efw_error(result)?;

        // Create cleanup guard to close the filter wheel if subsequent operations fail
        let filterwheel_id = self.filterwheel_id;
        let cleanup_guard = CleanupGuard::new(|| {
            tracing::debug!(
                "Cleaning up ZWO EFW filter wheel {} after failed connect",
                filterwheel_id
            );
            if let Some(sdk) = EfwSdk::get() {
                // SAFETY: best-effort cleanup; filterwheel_id was successfully opened above (guard only runs after open succeeded). Mutex still held when this drop runs in connect() scope.
                let _ = unsafe { (sdk.close)(filterwheel_id) };
            }
        });

        // Get properties
        // SAFETY: EFWInfo is `#[repr(C)]` POD; zeroed is a valid initial state.
        let mut info: EFWInfo = unsafe { std::mem::zeroed() };
        // SAFETY: zwo_efw_mutex held by connect(); `info` is a valid stack pointer; filterwheel_id was successfully opened above.
        let result = unsafe { (sdk.get_property)(self.filterwheel_id, &mut info) };
        check_efw_error(result)?;

        self.slot_count = info.slot_num;
        self.name = safe_cstr_to_string(info.name.as_ptr(), 64);

        // Initialize default filter names
        self.filter_names = (0..self.slot_count)
            .map(|i| format!("Filter {}", i + 1))
            .collect();

        // Read serial number under the still-held SDK mutex so we can populate
        // the connected-device registry below. This is the same call discovery
        // makes; doing it at connect time means discovery never needs to open
        // an already-connected device just to re-read its serial number.
        // SAFETY: EFWSerialNumber is `#[repr(C)]` POD; zeroed is a valid initial state.
        let mut sn: EFWSerialNumber = unsafe { std::mem::zeroed() };
        // SAFETY: zwo_efw_mutex held by connect(); `sn` is a valid stack pointer; filterwheel_id is open.
        let connect_serial_number =
            if unsafe { (sdk.get_serial_number)(self.filterwheel_id, &mut sn) } == 0 {
                let sn_bytes: [u8; 8] = sn.id;
                let sn_str = sn_bytes
                    .iter()
                    .take_while(|&&b| b != 0)
                    .map(|&b| format!("{:02X}", b))
                    .collect::<String>();
                if sn_str.is_empty() {
                    None
                } else {
                    Some(sn_str)
                }
            } else {
                None
            };

        // All operations succeeded - defuse the cleanup guard
        cleanup_guard.defuse();

        self.connected = true;

        // Populate the connected-EFW registry so that hot-plug discovery polls
        // can report this device from cache instead of calling EFWOpen/EFWClose
        // on the live handle.
        // Lock ordering: registry lock acquired here with SDK mutex (_lock) still
        // live. No SDK call is made while holding the registry lock. Inside
        // discover_filter_wheels the SDK mutex is held when the registry lock is
        // acquired (same direction). No inverse ordering exists, so no deadlock.
        {
            let mut reg = connected_efw().lock().unwrap_or_else(|e| e.into_inner());
            reg.insert(
                self.filterwheel_id,
                ConnectedEfwEntry {
                    filterwheel_id: self.filterwheel_id,
                    name: self.name.clone(),
                    slot_count: self.slot_count,
                    serial_number: connect_serial_number,
                    sdk_version: efw_sdk_version_from_sdk(sdk),
                },
            );
        }

        // Drop the mutex before the async sleep so other operations aren't blocked
        drop(_lock);

        // Give the firmware time to read the encoder position after EFWOpen.
        // Some ZWO EFW firmware returns position 0 or -1 immediately after open
        // because the encoder hasn't been polled yet. A short settle delay lets
        // the firmware synchronise with the physical slot position.
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;

        // Read initial position to pre-warm the SDK and verify it works
        {
            let _lock = zwo_efw_mutex().lock().await;
            let mut position: c_int = -999;
            // SAFETY: zwo_efw_mutex held in this inner scope; `position` is a valid stack pointer; filterwheel_id is valid (already opened in this connect() above).
            let result = unsafe { (sdk.get_position)(self.filterwheel_id, &mut position) };
            tracing::info!(
                "[ZWO EFW] Post-connect initial position read: hw_id={}, SDK result={}, position={}",
                self.filterwheel_id,
                result,
                position
            );
        }

        tracing::info!(
            "Connected to ZWO EFW: {} ({} slots)",
            self.name,
            self.slot_count
        );
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), NativeError> {
        if !self.connected {
            return Ok(());
        }

        tracing::info!(
            "Disconnecting from ZWO EFW filter wheel ID {}...",
            self.filterwheel_id
        );

        let sdk = EfwSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let _lock = zwo_efw_mutex().lock().await;
        // SAFETY: zwo_efw_mutex held above; filterwheel_id is valid because self.connected is true (only set after successful connect()).
        let result = unsafe { (sdk.close)(self.filterwheel_id) };
        check_efw_error(result)?;

        self.connected = false;
        self.settle_after_move_pending
            .store(false, Ordering::Release);

        // Remove from the connected-EFW registry so that subsequent discovery
        // polls perform a full open/query/close (device may have been physically
        // replugged). Lock ordering: registry lock acquired with SDK mutex held;
        // same ordering as inside discover_filter_wheels; no deadlock cycle.
        {
            let mut reg = connected_efw().lock().unwrap_or_else(|e| e.into_inner());
            reg.remove(&self.filterwheel_id);
        }

        tracing::info!("Disconnected from ZWO EFW");
        Ok(())
    }
}

#[async_trait]
impl NativeFilterWheel for ZwoFilterWheel {
    async fn move_to_position(&mut self, position: i32) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = EfwSdk::get().ok_or(NativeError::SdkNotLoaded)?;

        // Validate position
        if position < 0 || position >= self.slot_count {
            return Err(NativeError::InvalidParameter(format!(
                "Invalid position {}. Valid range: 0-{}",
                position,
                self.slot_count - 1
            )));
        }

        let _lock = zwo_efw_mutex().lock().await;
        tracing::debug!("Moving ZWO EFW to position {}", position);
        // SAFETY: zwo_efw_mutex held above; `position` was bounds-checked against slot_count earlier in this function; filterwheel_id is valid (connected=true checked).
        let result = unsafe { (sdk.set_position)(self.filterwheel_id, position) };
        check_efw_error(result)?;
        self.settle_after_move_pending
            .store(true, Ordering::Release);
        Ok(())
    }

    async fn get_position(&self) -> Result<i32, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let position = self.read_position_settled().await?;
        // debug, not info: position is polled continuously by status pollers.
        tracing::debug!(
            "[ZWO EFW] get_position(hw_id={}) => position={}",
            self.filterwheel_id,
            position
        );
        Ok(position)
    }

    async fn is_moving(&self) -> Result<bool, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let position = self.read_position_settled().await?;
        // debug, not info: polled continuously while a move is in flight.
        tracing::debug!(
            "[ZWO EFW] is_moving(hw_id={}) => position={}",
            self.filterwheel_id,
            position
        );
        // Position is -1 when moving
        Ok(position == -1)
    }

    fn get_filter_count(&self) -> i32 {
        self.slot_count
    }

    async fn get_filter_names(&self) -> Result<Vec<String>, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }
        Ok(self.filter_names.clone())
    }

    async fn set_filter_name(&mut self, position: i32, name: String) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        if position < 0 || position >= self.slot_count {
            return Err(NativeError::InvalidParameter(format!(
                "Invalid position {}. Valid range: 0-{}",
                position,
                self.slot_count - 1
            )));
        }

        // Why: bounds checked `0 <= position < self.slot_count` above; position is i32.
        // `as usize` is widening with verified non-negative value.
        self.filter_names[position as usize] = name;
        Ok(())
    }
}

impl ZwoFilterWheel {
    /// `move_to_position` to the 0-indexed slot, then wait for the wheel to
    /// settle under the config's filter-wheel timeout.
    pub async fn move_to_position_with_timeout(
        &mut self,
        position: i32,
        config: &NativeTimeoutConfig,
    ) -> Result<(), NativeError> {
        // Start the move
        self.move_to_position(position).await?;

        // Wait for move to complete
        wait_for_filterwheel_move(|| async { self.is_moving().await }, config, position).await
    }
}

// Filter wheel discovery

/// ZWO filter wheel discovery info
pub struct ZwoFilterWheelDiscoveryInfo {
    pub filterwheel_id: i32,
    pub name: String,
    pub slot_count: i32,
    pub serial_number: Option<String>,
    pub sdk_version: Option<String>,
    pub discovery_index: usize,
}

/// Check if EFW SDK is available
pub fn is_efw_sdk_available() -> bool {
    EfwSdk::get().is_some()
}

/// Get EFW SDK status
pub fn get_efw_sdk_status() -> (bool, String) {
    match EfwSdk::get() {
        Some(_) => (
            true,
            efw_sdk_version()
                .map(|version| format!("{version} loaded successfully"))
                .unwrap_or_else(|| "ZWO EFW SDK loaded successfully".to_string()),
        ),
        None => (false, "ZWO EFW SDK (EFW_filter.dll) not found.".to_string()),
    }
}

pub(crate) fn efw_sdk_version_from_sdk(sdk: &EfwSdk) -> Option<String> {
    // SAFETY: EFWGetSDKVersion takes no arguments and returns a static C string.
    sdk_static_cstr(unsafe { (sdk.get_sdk_version)() })
        .map(|version| format!("ZWO EFW SDK v{version}"))
}

pub fn efw_sdk_version() -> Option<String> {
    EfwSdk::get().and_then(efw_sdk_version_from_sdk)
}

/// Discover ZWO EFW filter wheels
pub async fn discover_filter_wheels() -> Result<Vec<ZwoFilterWheelDiscoveryInfo>, NativeError> {
    let sdk = match EfwSdk::get() {
        Some(sdk) => sdk,
        None => {
            tracing::debug!("ZWO EFW discovery skipped: EFW SDK not loaded");
            return Ok(Vec::new());
        }
    };

    // Acquire mutex for EFW SDK discovery operations
    let _lock = zwo_efw_mutex().lock().await;

    tracing::debug!("Discovering ZWO EFW filter wheels via native SDK...");
    let sdk_version = efw_sdk_version_from_sdk(sdk);
    // SAFETY: zwo_efw_mutex held above; EFWGetNum takes no arguments and only reads internal SDK state.
    let num_wheels = unsafe { (sdk.get_num)() };
    tracing::info!(
        "EFW SDK reports {} connected filter wheel{}",
        num_wheels,
        if num_wheels == 1 { "" } else { "s" }
    );

    let mut wheels = Vec::new();

    for i in 0..num_wheels {
        let mut id: c_int = 0;
        // SAFETY: zwo_efw_mutex held above; `i` is bounded by num_wheels; `id` is a valid stack pointer.
        let result = unsafe { (sdk.get_id)(i, &mut id) };

        if result != 0 {
            continue;
        }

        // Lock-ordering note: the SDK mutex (zwo_efw_mutex) is held for the
        // duration of discover_filter_wheels. The registry lock is acquired
        // briefly here to read a cached entry, then immediately released before
        // any SDK call. The connect/disconnect paths acquire the registry lock
        // while the SDK mutex may or may not be held, but never hold the
        // registry lock across an SDK call. No inverse ordering exists (registry
        // → waiting for SDK mutex), so no deadlock cycle.
        let cached_entry: Option<ConnectedEfwEntry> = {
            let reg = connected_efw().lock().unwrap_or_else(|e| e.into_inner());
            reg.get(&id).cloned()
        };
        // Registry lock is released here before any SDK call.

        if let Some(entry) = cached_entry {
            // This device ID has an active session with its handle open. Skip
            // EFWOpen/EFWGetProperty/EFWGetSerialNumber/EFWClose entirely to
            // avoid closing the live handle. Report from cached metadata.
            tracing::debug!(
                "ZWO EFW discovery: skipping open/close for connected filter wheel ID {} ({}); using cached metadata",
                id,
                entry.name
            );
            wheels.push(ZwoFilterWheelDiscoveryInfo {
                filterwheel_id: entry.filterwheel_id,
                name: entry.name,
                slot_count: entry.slot_count,
                serial_number: entry.serial_number,
                sdk_version: entry.sdk_version,
                // Why: `i` is loop index (c_int, 0..count) — non-negative by
                // construction. `as usize` is widening with verified non-negative.
                discovery_index: i as usize,
            });
            continue;
        }

        // Not a connected device — perform the normal open/query/close discovery.
        // SAFETY: mutex held; `id` was just populated by EFWGetID.
        let result = unsafe { (sdk.open)(id) };
        if result == 0 {
            // SAFETY: EFWInfo is `#[repr(C)]` POD; zeroed is a valid initial state.
            let mut info: EFWInfo = unsafe { std::mem::zeroed() };
            // SAFETY: mutex held; `info` is a valid stack pointer; `id` was just successfully opened.
            let property_result = unsafe { (sdk.get_property)(id, &mut info) };
            if property_result != 0 {
                // `info` would still be zeroed: an empty name and slot_num = 0, and
                // discovery publishes that name verbatim as the device identity
                // (native/src/discovery.rs). A blank, zero-slot entry is a wrong answer,
                // not a discovery result. Close the handle and leave the wheel out of
                // this scan; connect() runs the same EFWGetProperty (checked) and reports
                // the failure if the user targets it, and the next scan retries.
                tracing::error!(
                    "ZWO EFW discovery: EFWGetProperty failed for filter wheel ID {} (EFW error {}); omitting it from this scan",
                    id,
                    property_result
                );
                // SAFETY: mutex held; `id` was successfully opened above. EFWClose pairs with EFWOpen.
                let _ = unsafe { (sdk.close)(id) };
                continue;
            }
            // SAFETY: ASI SDK guarantees `info.name` is NUL-terminated within the 64-byte array.
            let name = unsafe {
                CStr::from_ptr(info.name.as_ptr())
                    .to_string_lossy()
                    .to_string()
            };
            let slot_count = info.slot_num;

            // Try to get serial number (must be done before close)
            // SAFETY: EFWSerialNumber is `#[repr(C)]` POD (just `id: [u8; 8]`); zeroed is valid.
            let mut sn: EFWSerialNumber = unsafe { std::mem::zeroed() };
            // SAFETY: mutex held; `sn` is a valid stack pointer; `id` is open.
            let serial_number = if unsafe { (sdk.get_serial_number)(id, &mut sn) } == 0 {
                let sn_bytes: [u8; 8] = sn.id;
                let sn_str = sn_bytes
                    .iter()
                    .take_while(|&&b| b != 0)
                    .map(|&b| format!("{:02X}", b))
                    .collect::<String>();
                if sn_str.is_empty() {
                    None
                } else {
                    Some(sn_str)
                }
            } else {
                None
            };

            // SAFETY: mutex held; `id` was successfully opened above. EFWClose pairs with EFWOpen.
            let _ = unsafe { (sdk.close)(id) };

            tracing::info!(
                "Found ZWO EFW: {} (ID: {}, {} slots, SN: {:?})",
                name,
                id,
                slot_count,
                serial_number
            );
            wheels.push(ZwoFilterWheelDiscoveryInfo {
                filterwheel_id: id,
                name,
                slot_count,
                serial_number,
                sdk_version: sdk_version.clone(),
                // Why: `i` is loop index (c_int, 0..count) — non-negative by
                // construction. `as usize` is widening with verified non-negative.
                discovery_index: i as usize,
            });
        }
    }

    Ok(wheels)
}

// Linux library-name candidates; the module is gated rather than the test so
// `use super::*` is not an unused import on every other platform.
#[cfg(all(test, target_os = "linux"))]
mod candidate_path_tests {
    use super::*;

    #[test]
    fn accepts_zwo_and_distro_linux_library_names() {
        let candidates = efw_candidate_paths();
        assert!(candidates.contains(&PathBuf::from("libEFW_filter.so")));
        assert!(candidates.contains(&PathBuf::from("libEFWFilter.so")));
        assert!(candidates.contains(&PathBuf::from("/usr/lib/libEFWFilter.so")));
    }
}
