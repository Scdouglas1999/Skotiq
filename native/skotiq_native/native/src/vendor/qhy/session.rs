//! One open SDK handle per camera, shared by the camera driver and the driver
//! of the filter wheel on the camera's CFW port.
//!
//! `OpenQHYCCD` on a camera that is already open returns that camera's handle,
//! and `CloseQHYCCD` cancels the camera's exposure and closes the handle for
//! every holder (both read from the SDK binary, see notes/a-qhy.md). So the
//! camera and its wheel must hold one handle between them: the first to
//! connect opens and initializes the camera, the last to leave closes it.
//!
//! Every function here takes the SDK table from a held `QhySdk` guard; the
//! registry is only touched under that lock.

use super::*;
use crate::camera_core::SdkHandle;
use std::collections::HashMap;
use std::sync::Mutex;

struct Open {
    handle: SdkHandle<QhyCamHandle>,
    holders: u32,
}

fn sessions() -> std::sync::MutexGuard<'static, HashMap<String, Open>> {
    static SESSIONS: OnceLock<Mutex<HashMap<String, Open>>> = OnceLock::new();
    SESSIONS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// The ids the SDK lists now. A scan is how the SDK learns that a camera was
/// plugged back in; it does not disturb cameras that are open (INDI scans
/// every second while its cameras run).
pub(crate) fn scan(sdk: &QhySdk) -> Vec<String> {
    // SAFETY: ScanQHYCCD takes no arguments; the caller holds the SDK lock.
    let count = unsafe { (sdk.scan_qhyccd)() };
    // ScanQHYCCD answers QHYCCD_ERROR when it fails.
    let count = if count == QHYCCD_ERROR { 0 } else { count };
    let mut ids = Vec::new();
    for index in 0..count {
        let mut id = [0 as c_char; 256];
        // SAFETY: `index` is below the count ScanQHYCCD reported and the
        // buffer is larger than any QHY id (qhyccd.h: 32 bytes).
        if unsafe { (sdk.get_qhyccd_id)(index, id.as_mut_ptr()) } == QHYCCD_SUCCESS {
            // SAFETY: GetQHYCCDId wrote a NUL-terminated id.
            ids.push(unsafe { CStr::from_ptr(id.as_ptr()) }.to_string_lossy().into_owned());
        }
    }
    ids
}

/// The handle `camera_id` is open under, if a driver holds it.
pub(crate) fn current(camera_id: &str) -> Option<QhyCamHandle> {
    sessions().get(camera_id).map(|open| open.handle.0)
}

/// Join the camera's session, opening and initializing the camera when no
/// driver holds it yet. Returns the handle and whether this call opened it.
pub(crate) fn join(sdk: &QhySdk, camera_id: &str) -> Result<(QhyCamHandle, bool), DriverError> {
    if let Some(open) = sessions().get_mut(camera_id) {
        open.holders += 1;
        return Ok((open.handle.0, false));
    }
    if !scan(sdk).iter().any(|id| id == camera_id) {
        return Err(DriverError::DeviceNotFound(format!(
            "QHY camera {camera_id} is not connected: the QHY SDK does not list it. \
             Check its USB cable and its 12 V power."
        )));
    }
    let handle = open_listed(sdk, camera_id)?;
    sessions().insert(
        camera_id.to_string(),
        Open {
            handle: SdkHandle(handle),
            holders: 1,
        },
    );
    Ok((handle, true))
}

/// Leave the camera's session; the last holder closes the camera.
pub(crate) fn leave(sdk: &QhySdk, camera_id: &str) {
    let mut sessions = sessions();
    let Some(open) = sessions.get_mut(camera_id) else {
        return;
    };
    open.holders -= 1;
    if open.holders > 0 {
        return;
    }
    let handle = open.handle.0;
    sessions.remove(camera_id);
    // SAFETY: the handle came from OpenQHYCCD and no driver holds it any more.
    let result = unsafe { (sdk.close_qhyccd)(handle) };
    if result != QHYCCD_SUCCESS {
        tracing::warn!("QHY camera {camera_id}: CloseQHYCCD answered 0x{result:X}");
    }
}

/// Open and initialize a camera the last scan listed, outside any session.
/// The caller closes it with `CloseQHYCCD` or registers it.
pub(crate) fn open_listed(sdk: &QhySdk, camera_id: &str) -> Result<QhyCamHandle, DriverError> {
    let id = CString::new(camera_id)
        .map_err(|_| DriverError::InvalidDevice(format!("Invalid QHY camera id {camera_id:?}")))?;
    // SAFETY: `id` is NUL-terminated and outlives the call.
    let handle = unsafe { (sdk.open_qhyccd)(id.as_ptr()) };
    if handle.is_null() {
        return Err(DriverError::SdkError(format!(
            "The QHY SDK could not open camera {camera_id}. Another program (SharpCap, \
             NINA, the QHY ASCOM driver) may be using it; close it, or unplug the camera \
             and plug it in again."
        )));
    }
    // SAFETY: `handle` is the non-null handle OpenQHYCCD just returned; stream
    // mode 0 is single-frame mode (qhyccd.h).
    let stream = unsafe { (sdk.set_qhyccd_stream_mode)(handle, 0) };
    let failed = if stream != QHYCCD_SUCCESS {
        Some(("switch to single-frame mode", stream))
    } else {
        // SAFETY: as above.
        match unsafe { (sdk.init_qhyccd)(handle) } {
            QHYCCD_SUCCESS => None,
            code => Some(("initialize", code)),
        }
    };
    let Some((step, code)) = failed else {
        return Ok(handle);
    };
    // SAFETY: the handle is open and nothing else holds it yet.
    unsafe { (sdk.close_qhyccd)(handle) };
    Err(DriverError::SdkError(format!(
        "QHY camera {camera_id} opened but did not {step} (SDK code 0x{code:X}). Unplug the \
         camera and plug it in again; if that does not help, power-cycle it."
    )))
}
