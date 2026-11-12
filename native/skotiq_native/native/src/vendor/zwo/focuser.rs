//! ZWO EAF focuser: SDK, device implementation and discovery.

use super::*;
use crate::load_vendor_sdk;
use crate::vendor::sdk_loader::vendor_library_candidates;
use std::path::PathBuf;

/// EAF Info structure from SDK
#[repr(C)]
#[derive(Debug, Clone)]
pub(crate) struct EAFInfo {
    pub(crate) id: c_int,
    pub(crate) name: [c_char; 64],
    pub(crate) max_step: c_int,
}

/// EAF Error codes
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
#[allow(non_camel_case_types, dead_code)]
pub(crate) enum EAFError {
    EAF_SUCCESS = 0,
    EAF_ERROR_INVALID_INDEX = 1,
    EAF_ERROR_INVALID_ID = 2,
    EAF_ERROR_INVALID_VALUE = 3,
    EAF_ERROR_REMOVED = 4,
    EAF_ERROR_MOVING = 5,
    EAF_ERROR_ERROR_STATE = 6,
    EAF_ERROR_GENERAL_ERROR = 7,
    EAF_ERROR_NOT_SUPPORTED = 8,
    EAF_ERROR_CLOSED = 9,
    EAF_ERROR_END = -1,
}

/// EAF ID/Serial Number structure
#[repr(C)]
#[derive(Debug, Clone)]
pub(crate) struct EAFSerialNumber {
    pub(crate) id: [c_uchar; 8],
}

/// Candidate library paths for the ZWO EAF (focuser) SDK. ZWO only ships the
/// EAF focuser SDK as a single platform-specific filename — no install-tree
/// search is needed beyond the system loader path.
pub(crate) fn eaf_candidate_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if cfg!(target_os = "windows") {
        paths.push(PathBuf::from("EAF_focuser.dll"));
    } else if cfg!(target_os = "macos") {
        paths.push(PathBuf::from("libEAF_focuser.dylib"));
    } else {
        paths.extend(vendor_library_candidates(
            // ZWO's Linux packages and distro repackagings use both names:
            // the SDK archive historically used libEAF_focuser.so, while
            // Arch's libasi package installs libEAFFocuser.so.
            &["libEAF_focuser.so", "libEAFFocuser.so"],
            &[
                "/usr/lib/libEAF_focuser.so",
                "/usr/lib/libEAFFocuser.so",
                "/usr/local/lib/libEAF_focuser.so",
                "/usr/local/lib/libEAFFocuser.so",
            ],
        ));
    }
    paths
}

load_vendor_sdk! {
    /// ZWO EAF Focuser SDK function-pointer table.
    vendor_name: "ZWO EAF Focuser",
    sdk_struct: EafSdk,
    sdk_static: EAF_SDK,
    candidate_paths_fn: eaf_candidate_paths,
    symbols: {
        get_num: b"EAFGetNum\0"
            => unsafe extern "C" fn() -> c_int,
        get_id: b"EAFGetID\0"
            => unsafe extern "C" fn(c_int, *mut c_int) -> c_int,
        open: b"EAFOpen\0"
            => unsafe extern "C" fn(c_int) -> c_int,
        close: b"EAFClose\0"
            => unsafe extern "C" fn(c_int) -> c_int,
        get_property: b"EAFGetProperty\0"
            => unsafe extern "C" fn(c_int, *mut EAFInfo) -> c_int,
        move_to: b"EAFMove\0"
            => unsafe extern "C" fn(c_int, c_int) -> c_int,
        stop: b"EAFStop\0"
            => unsafe extern "C" fn(c_int) -> c_int,
        is_moving: b"EAFIsMoving\0"
            => unsafe extern "C" fn(c_int, *mut bool, *mut bool) -> c_int,
        get_position: b"EAFGetPosition\0"
            => unsafe extern "C" fn(c_int, *mut c_int) -> c_int,
        get_temp: b"EAFGetTemp\0"
            => unsafe extern "C" fn(c_int, *mut f32) -> c_int,
        set_max_step: b"EAFSetMaxStep\0"
            => unsafe extern "C" fn(c_int, c_int) -> c_int,
        get_max_step: b"EAFGetMaxStep\0"
            => unsafe extern "C" fn(c_int, *mut c_int) -> c_int,
        set_backlash: b"EAFSetBacklash\0"
            => unsafe extern "C" fn(c_int, c_int) -> c_int,
        get_backlash: b"EAFGetBacklash\0"
            => unsafe extern "C" fn(c_int, *mut c_int) -> c_int,
        set_reverse: b"EAFSetReverse\0"
            => unsafe extern "C" fn(c_int, bool) -> c_int,
        get_reverse: b"EAFGetReverse\0"
            => unsafe extern "C" fn(c_int, *mut bool) -> c_int,
        set_beep: b"EAFSetBeep\0"
            => unsafe extern "C" fn(c_int, bool) -> c_int,
        get_beep: b"EAFGetBeep\0"
            => unsafe extern "C" fn(c_int, *mut bool) -> c_int,
        get_sdk_version: b"EAFGetSDKVersion\0"
            => unsafe extern "C" fn() -> *const c_char,
        get_firmware_version: b"EAFGetFirmwareVersion\0"
            => unsafe extern "C" fn(c_int, *mut c_uchar, *mut c_uchar, *mut c_uchar) -> c_int,
        get_serial_number: b"EAFGetSerialNumber\0"
            => unsafe extern "C" fn(c_int, *mut EAFSerialNumber) -> c_int,
        // SDK header ships with the typo "EAFResetPostion" (sic) — we must keep
        // it because that's the only symbol the .dll actually exports.
        reset_position: b"EAFResetPostion\0"
            => unsafe extern "C" fn(c_int, c_int) -> c_int,
    }
}

/// Check EAF error code and convert to DriverError
pub(crate) fn check_eaf_error(code: c_int) -> Result<(), DriverError> {
    match code {
        0 => Ok(()),
        1 => Err(DriverError::InvalidDevice(
            "EAF_ERROR_INVALID_INDEX".to_string(),
        )),
        2 => Err(DriverError::InvalidDevice(
            "EAF_ERROR_INVALID_ID".to_string(),
        )),
        3 => Err(DriverError::InvalidParameter(
            "EAF_ERROR_INVALID_VALUE".to_string(),
        )),
        4 => Err(DriverError::Disconnected),
        5 => Err(DriverError::SdkError(
            "EAF_ERROR_MOVING: Focuser is moving".to_string(),
        )),
        6 => Err(DriverError::SdkError(
            "EAF_ERROR_ERROR_STATE: Focuser in error state".to_string(),
        )),
        7 => Err(DriverError::SdkError("EAF_ERROR_GENERAL_ERROR".to_string())),
        8 => Err(DriverError::NotSupported),
        9 => Err(DriverError::NotConnected),
        _ => Err(DriverError::SdkError(format!(
            "Unknown EAF error code: {}",
            code
        ))),
    }
}

#[derive(Debug)]
pub struct ZwoFocuser {
    pub(crate) focuser_id: i32,
    pub(crate) device_id: String,
    pub(crate) connected: bool,
    pub(crate) max_position: i32,
    pub(crate) name: String,
    /// Microns of mechanical travel per motor step, resolved at connect time from the
    /// quirks database keyed by the SDK-reported model name. The EAF SDK does not
    /// expose this value, so absent a quirks entry we cannot honestly answer
    /// `get_step_size`; tracking it here lets us fail loudly instead of guessing.
    pub(crate) step_size_um: Option<f64>,
}

impl ZwoFocuser {
    pub fn new(focuser_id: i32) -> Self {
        Self {
            focuser_id,
            device_id: format!("native:zwo:eaf:{}", focuser_id),
            connected: false,
            max_position: 0,
            name: format!("ZWO EAF {}", focuser_id),
            step_size_um: None,
        }
    }
}

#[async_trait]
impl DeviceDriver for ZwoFocuser {
    fn id(&self) -> &str {
        &self.device_id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn vendor(&self) -> Vendor {
        Vendor::Zwo
    }

    fn is_connected(&self) -> bool {
        self.connected
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        tracing::info!("Connecting to ZWO EAF focuser ID {}...", self.focuser_id);

        let sdk = EafSdk::installed().inspect_err(|_| {
            tracing::error!("Cannot connect to ZWO EAF: EAF SDK not loaded");
        })?;

        // Hold the EAF SDK lock for the connect sequence
        let sdk = sdk.lock().await;

        // A saved profile connects by id before any device search; EAFGetNum
        // "should be the first API to be called" (EAF_focuser.h) and fills the
        // id table EAFOpen looks in, as for the EFW.
        // SAFETY: EAFGetNum takes no arguments; the lock guard keeps every other
        // task out of the EAF SDK while it re-scans.
        let num_focusers = unsafe { (sdk.get_num)() };
        // SAFETY: index is bounded by EAFGetNum and `listed` is a valid output
        // pointer.
        let listed = |index, listed: &mut c_int| unsafe { (sdk.get_id)(index, listed) };
        if !id_is_listed(num_focusers, listed, self.focuser_id) {
            let reported = num_focusers.max(0);
            return Err(DriverError::DeviceNotFound(format!(
                "ZWO EAF ID {} is not present (SDK reported {} focuser{})",
                self.focuser_id,
                reported,
                if reported == 1 { "" } else { "s" }
            )));
        }

        // SAFETY: focuser_id was matched against the SDK-issued IDs immediately above.
        let result = unsafe { (sdk.open)(self.focuser_id) };
        check_eaf_error(result)?;

        let focuser_id = self.focuser_id;
        let locked_sdk: &EafSdk = &sdk;
        let cleanup_guard = CleanupGuard::new(|| {
            tracing::debug!(
                "Cleaning up ZWO EAF focuser {} after failed connect",
                focuser_id
            );
            // SAFETY: best-effort cleanup; focuser_id was successfully opened above (guard only runs if we got past open). The cleanup borrows the lock guard, so it runs while connect() still holds the lock.
            let _ = unsafe { (locked_sdk.close)(focuser_id) };
        });

        // SAFETY: EAFInfo is `#[repr(C)]` POD; zeroed is a valid initial state.
        let mut info: EAFInfo = unsafe { std::mem::zeroed() };
        // SAFETY: `info` is a valid stack pointer; focuser_id was successfully opened above.
        let result = unsafe { (sdk.get_property)(self.focuser_id, &mut info) };
        check_eaf_error(result)?;

        self.max_position = info.max_step;
        self.name = safe_cstr_to_string(info.name.as_ptr(), 64);

        // Resolve step size via the quirks DB using the SDK-reported model as the
        // matchable token. The model lives only in `name`, never in `device_id`,
        // so a synthesized lookup id is required for ModelContains matchers
        // ("EAF-S", "EAF-2", "EAF") to differentiate the gear-ratio variants.
        let lookup_id = format!("native:zwo:{}", self.name);
        self.step_size_um = crate::quirks::get_focuser_step_size_um(&lookup_id);
        if self.step_size_um.is_none() {
            tracing::warn!(
                "ZWO EAF model '{}' has no step-size quirk entry; get_step_size will return an error",
                self.name
            );
        }

        // Read serial number under the still-held SDK lock so we can populate
        // the connected-device registry below. This is the same call discovery
        // makes; doing it at connect time means discovery never needs to open
        // an already-connected device just to re-read its serial number.
        // SAFETY: EAFSerialNumber is `#[repr(C)]` POD; zeroed is a valid initial state.
        let mut sn: EAFSerialNumber = unsafe { std::mem::zeroed() };
        // SAFETY: `sn` is a valid stack pointer; focuser_id is open.
        let serial_number = if unsafe { (sdk.get_serial_number)(self.focuser_id, &mut sn) } == 0 {
            accessory_serial(sn.id)
        } else {
            None
        };

        cleanup_guard.defuse();

        self.connected = true;

        // Populate the connected-EAF registry so that hot-plug discovery polls
        // can report this device from cache instead of calling EAFOpen/EAFClose
        // on the live handle.
        // Lock ordering: the EAF SDK guard (`sdk`) is still live here and the
        // registry lock is taken inside it, the same direction as in
        // discover_focusers (see the lock-ordering note above the registries
        // in mod.rs). Nothing takes the registry lock and then waits for the
        // SDK lock, and no SDK call is made while the registry lock is held,
        // so there is no cycle.
        {
            let mut reg = connected_eaf().lock().unwrap_or_else(|e| e.into_inner());
            reg.insert(
                self.focuser_id,
                ConnectedEafEntry {
                    focuser_id: self.focuser_id,
                    name: self.name.clone(),
                    serial_number,
                    sdk_version: eaf_sdk_version_from_sdk(&sdk),
                },
            );
        }

        // The focuser's own limits and compensation, which Skotiq reads but does
        // not set: EAFGetProperty's MaxStep is the travel Skotiq allows, while
        // INDI and NINA use EAFGetMaxStep; a non-zero backlash is applied by the
        // focuser on top of any Skotiq applies.
        let mut user_max_step: c_int = -1;
        let mut backlash: c_int = -1;
        let mut reversed = false;
        // SAFETY: valid stack out-pointers; focuser_id is open.
        let reads = unsafe {
            [
                (sdk.get_max_step)(self.focuser_id, &mut user_max_step),
                (sdk.get_backlash)(self.focuser_id, &mut backlash),
                (sdk.get_reverse)(self.focuser_id, &mut reversed),
            ]
        };
        tracing::info!(
            "Connected to ZWO EAF: {} (max step: {}, step size: {:?} um; focuser max step {}, \
             backlash {}, reversed {}, read results {:?})",
            self.name,
            self.max_position,
            self.step_size_um,
            user_max_step,
            backlash,
            reversed,
            reads
        );
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        if !self.connected {
            return Ok(());
        }

        tracing::info!(
            "Disconnecting from ZWO EAF focuser ID {}...",
            self.focuser_id
        );

        let sdk = EafSdk::lock().await?;
        // SAFETY: focuser_id is valid because self.connected is true (only set after successful connect()).
        let result = unsafe { (sdk.close)(self.focuser_id) };

        // Forgotten even when the close fails: a focuser unplugged while
        // connected cannot be closed, and the one plugged in next may get its id.
        self.connected = false;

        // Remove from the connected-EAF registry so that subsequent discovery
        // polls perform a full open/query/close (device may have been physically
        // replugged). Lock ordering: registry lock acquired with the SDK guard held;
        // this is the same ordering as inside discover_focusers, so no cycle.
        {
            let mut reg = connected_eaf().lock().unwrap_or_else(|e| e.into_inner());
            reg.remove(&self.focuser_id);
        }
        check_eaf_error(result)?;

        tracing::info!("Disconnected from ZWO EAF");
        Ok(())
    }
}

#[async_trait]
impl FocuserDriver for ZwoFocuser {
    async fn move_to(&mut self, position: i32) -> Result<(), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        let sdk = EafSdk::lock().await?;

        let target = validate_zwo_eaf_target(position, self.max_position)?;

        tracing::debug!("Moving ZWO EAF to position {}", target);
        // SAFETY: `target` was validated to be in
        // [0, max_position]; focuser_id is valid (connected=true checked).
        let result = unsafe { (sdk.move_to)(self.focuser_id, target) };
        check_eaf_error(result)
    }

    async fn move_relative(&mut self, steps: i32) -> Result<(), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        let current = self.get_position().await?;
        let target = current.checked_add(steps).ok_or_else(|| {
            DriverError::InvalidParameter(format!(
                "ZWO EAF relative move from {} by {} overflows i32",
                current, steps
            ))
        })?;
        self.move_to(target).await
    }

    async fn get_position(&self) -> Result<i32, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        let sdk = EafSdk::lock().await?;
        let mut position: c_int = 0;
        // SAFETY: `position` is a valid stack pointer; focuser_id is valid (connected=true checked).
        let result = unsafe { (sdk.get_position)(self.focuser_id, &mut position) };
        check_eaf_error(result)?;
        Ok(position)
    }

    async fn is_moving(&self) -> Result<bool, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        let sdk = EafSdk::lock().await?;
        let mut is_moving = false;
        let mut hand_control = false;
        // SAFETY: both out-bool pointers point to valid stack bools (SDK writes 0 or 1); focuser_id is valid (connected=true checked).
        let result = unsafe { (sdk.is_moving)(self.focuser_id, &mut is_moving, &mut hand_control) };
        check_eaf_error(result)?;
        Ok(is_moving)
    }

    async fn halt(&mut self) -> Result<(), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        let sdk = EafSdk::lock().await?;
        tracing::debug!("Stopping ZWO EAF movement");
        // SAFETY: focuser_id is valid (connected=true checked).
        let result = unsafe { (sdk.stop)(self.focuser_id) };
        check_eaf_error(result)
    }

    async fn get_temperature(&self) -> Result<Option<f64>, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        let sdk = EafSdk::lock().await?;
        let mut temp: f32 = 0.0;
        // SAFETY: `temp` is a valid stack pointer; focuser_id is valid (connected=true checked).
        let result = unsafe { (sdk.get_temp)(self.focuser_id, &mut temp) };

        // Temperature of -273 means invalid/unavailable
        if result == 0 && temp > -273.0 {
            Ok(Some(temp as f64))
        } else {
            Ok(None)
        }
    }

    fn get_max_position(&self) -> i32 {
        self.max_position
    }

    fn get_step_size(&self) -> f64 {
        // Resolved at connect time from the quirks DB; 0.0 here is the contract
        // the trait offers for "unknown" and is surfaced to callers as such. The
        // tracing::error makes the missing-entry case loud and diagnosable rather
        // than a silent guess that propagates into the focus model micron axis.
        match self.step_size_um {
            Some(um) => um,
            None => {
                tracing::error!(
                    "ZWO EAF '{}' has no step-size quirk entry; returning 0.0 to signal unknown",
                    self.name
                );
                0.0
            }
        }
    }
}

pub struct ZwoFocuserDiscoveryInfo {
    pub focuser_id: i32,
    pub name: String,
    pub serial_number: Option<String>,
    pub sdk_version: Option<String>,
    pub discovery_index: usize,
}

pub fn is_eaf_sdk_available() -> bool {
    EafSdk::is_available()
}

pub fn get_eaf_sdk_status() -> (bool, String) {
    match EafSdk::installed() {
        Ok(sdk) => (
            true,
            // Unlocked on purpose: EAFGetSDKVersion takes no arguments, returns a
            // pointer to a string compiled into the library and touches no device,
            // and this synchronous status helper cannot wait for the lock.
            eaf_sdk_version_from_sdk(sdk.unlocked())
                .map(|version| format!("{version} loaded successfully"))
                .unwrap_or_else(|| "ZWO EAF SDK loaded successfully".to_string()),
        ),
        Err(_) => (
            false,
            "ZWO EAF SDK (EAF_focuser.dll) not found.".to_string(),
        ),
    }
}

pub(crate) fn sdk_static_cstr(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }

    // SAFETY: vendor SDK version functions return pointers to static,
    // NUL-terminated strings owned by the loaded SDK library.
    let value = unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .trim()
        .to_string();
    (!value.is_empty()).then_some(value)
}

pub(crate) fn eaf_sdk_version_from_sdk(sdk: &EafSdk) -> Option<String> {
    // SAFETY: EAFGetSDKVersion takes no arguments and returns a static C string.
    sdk_static_cstr(unsafe { (sdk.get_sdk_version)() })
        .map(|version| format!("ZWO EAF SDK v{version}"))
}

pub async fn discover_focusers() -> Result<Vec<ZwoFocuserDiscoveryInfo>, DriverError> {
    let sdk = match EafSdk::installed() {
        Ok(sdk) => sdk,
        Err(_) => {
            tracing::debug!("ZWO EAF discovery skipped: EAF SDK not loaded");
            return Ok(Vec::new());
        }
    };

    // Hold the EAF SDK lock for the whole scan
    let sdk = sdk.lock().await;

    tracing::debug!("Discovering ZWO EAF focusers via native SDK...");
    let sdk_version = eaf_sdk_version_from_sdk(&sdk);
    // SAFETY: EAFGetNum takes no arguments and only reads internal SDK state.
    let num_focusers = unsafe { (sdk.get_num)() };
    tracing::info!(
        "EAF SDK reports {} connected focuser{}",
        num_focusers,
        if num_focusers == 1 { "" } else { "s" }
    );

    let mut focusers = Vec::new();

    for i in 0..num_focusers {
        let mut id: c_int = 0;
        // SAFETY: `i` is bounded by num_focusers; `id` is a valid stack pointer.
        let result = unsafe { (sdk.get_id)(i, &mut id) };

        if result != 0 {
            continue;
        }

        // Lock-ordering note: the EAF SDK guard is held for the
        // duration of discover_focusers. The registry lock is acquired briefly
        // here to read a cached entry, then immediately released before any SDK
        // call. The connect/disconnect paths acquire the registry lock while the
        // SDK mutex may or may not be held, but they never hold the registry
        // lock across an SDK call. So the two acquisition orders are:
        //   discover: SDK mutex → registry lock (read only, released immediately)
        //   connect:  SDK mutex held → registry lock (no SDK call while held)
        //   disconnect: SDK mutex held → registry lock (no SDK call while held)
        // There is no inverse path (registry → then waiting for SDK mutex), so
        // no deadlock cycle exists.
        let cached_entry: Option<ConnectedEafEntry> = {
            let reg = connected_eaf().lock().unwrap_or_else(|e| e.into_inner());
            reg.get(&id).cloned()
        };
        // Registry lock is released here before any SDK call.

        if let Some(entry) = cached_entry {
            // This device ID has an active session with its handle open. Skip
            // EAFOpen/EAFGetProperty/EAFGetSerialNumber/EAFClose entirely to
            // avoid closing the live handle. Report from cached metadata.
            tracing::debug!(
                "ZWO EAF discovery: skipping open/close for connected focuser ID {} ({}); using cached metadata",
                id,
                entry.name
            );
            focusers.push(ZwoFocuserDiscoveryInfo {
                focuser_id: entry.focuser_id,
                name: entry.name,
                serial_number: entry.serial_number,
                sdk_version: entry.sdk_version,
                // Why: `i` is loop index (c_int, 0..count) — non-negative by
                // construction. `as usize` is widening with verified non-negative.
                discovery_index: i as usize,
            });
            continue;
        }

        // Not a connected device — perform the normal open/query/close discovery.
        // SAFETY: `id` was just populated by EAFGetID, a valid SDK identifier.
        let result = unsafe { (sdk.open)(id) };
        if result == 0 {
            // SAFETY: EAFInfo is `#[repr(C)]` POD; zeroed is a valid initial state.
            let mut info: EAFInfo = unsafe { std::mem::zeroed() };
            // SAFETY: `info` is a valid stack pointer; `id` was just successfully opened.
            let property_result = unsafe { (sdk.get_property)(id, &mut info) };
            if property_result != 0 {
                // `info` would still be zeroed, and discovery publishes `name` verbatim
                // as the device identity (native/src/discovery.rs), so the focuser would
                // appear as a blank row. Close the handle and leave it out of this scan;
                // connect() runs the same EAFGetProperty (checked) and reports the failure
                // if the user targets it, and the next scan retries.
                tracing::error!(
                    "ZWO EAF discovery: EAFGetProperty failed for focuser ID {} (EAF error {}); omitting it from this scan",
                    id,
                    property_result
                );
                // SAFETY: `id` was successfully opened above. EAFClose pairs with EAFOpen.
                let _ = unsafe { (sdk.close)(id) };
                continue;
            }
            let name = safe_cstr_to_string(info.name.as_ptr(), 64);

            // Try to get serial number (must be done before close)
            // SAFETY: EAFSerialNumber is `#[repr(C)]` POD (just `id: [u8; 8]`); zeroed is valid.
            let mut sn: EAFSerialNumber = unsafe { std::mem::zeroed() };
            // SAFETY: `sn` is a valid stack pointer; `id` is open.
            let serial_number = if unsafe { (sdk.get_serial_number)(id, &mut sn) } == 0 {
                accessory_serial(sn.id)
            } else {
                None
            };

            // SAFETY: `id` was successfully opened above. EAFClose pairs with EAFOpen.
            let _ = unsafe { (sdk.close)(id) };

            tracing::info!(
                "Found ZWO EAF: {} (ID: {}, SN: {:?})",
                name,
                id,
                serial_number
            );
            focusers.push(ZwoFocuserDiscoveryInfo {
                focuser_id: id,
                name,
                serial_number,
                sdk_version: sdk_version.clone(),
                // Why: `i` is the loop index (c_int, 0..count) — non-negative by
                // construction. `as usize` is widening with verified non-negative.
                discovery_index: i as usize,
            });
        }
    }

    Ok(focusers)
}

// Linux library-name candidates; the module is gated rather than the test so
// `use super::*` is not an unused import on every other platform.
#[cfg(all(test, target_os = "linux"))]
mod candidate_path_tests {
    use super::*;

    #[test]
    fn accepts_zwo_and_distro_linux_library_names() {
        let candidates = eaf_candidate_paths();
        assert!(candidates.contains(&PathBuf::from("libEAF_focuser.so")));
        assert!(candidates.contains(&PathBuf::from("libEAFFocuser.so")));
        assert!(candidates.contains(&PathBuf::from("/usr/lib/libEAFFocuser.so")));
    }
}
