//! Moravian device discovery.

use super::*;

/// Active enumeration sink for SDK callbacks.
pub(crate) static ACTIVE_ENUMERATION_IDS: Mutex<Option<Arc<Mutex<Vec<c_int>>>>> = Mutex::new(None);

/// Callback for camera enumeration (`enum_callback_t`, gxccd.h:63).
pub(crate) unsafe extern "C" fn enumerate_callback(id: c_int) {
    let target = ACTIVE_ENUMERATION_IDS
        .lock()
        .ok()
        .and_then(|guard| guard.as_ref().cloned());
    if let Some(ids) = target {
        if let Ok(mut ids) = ids.lock() {
            ids.push(id);
        }
    }
}

/// Discovered Moravian camera info
#[derive(Debug, Clone)]
pub struct MoravianCameraInfo {
    pub camera_id: c_int,
    pub name: String,
    pub serial_number: Option<String>,
    pub discovery_index: usize,
}

/// Discover all connected Moravian cameras
pub async fn discover_devices() -> Result<Vec<MoravianCameraInfo>, NativeError> {
    let sdk = get_sdk()?;

    // Acquire global SDK mutex for thread safety
    let _lock = moravian_mutex().lock().await;

    let ids_sink = Arc::new(Mutex::new(Vec::new()));
    *ACTIVE_ENUMERATION_IDS
        .lock()
        .unwrap_or_else(|e| e.into_inner()) = Some(ids_sink.clone());

    // Enumerate cameras
    // SAFETY: moravian_mutex held above (single-threaded gxccd SDK access); ACTIVE_ENUMERATION_IDS has been set to `ids_sink` so the callback has a sink to push to; `enumerate_callback` is a properly declared `unsafe extern "C" fn(c_int)` matching the enum_callback_t typedef.
    unsafe { (sdk.enumerate_usb)(enumerate_callback) };
    *ACTIVE_ENUMERATION_IDS
        .lock()
        .unwrap_or_else(|e| e.into_inner()) = None;

    // Collect results
    let ids: Vec<c_int> = ids_sink.lock().unwrap_or_else(|e| e.into_inner()).clone();

    let mut devices = Vec::new();

    for (index, &id) in ids.iter().enumerate() {
        // Temporarily initialize to read camera info, then release.
        // SAFETY: moravian_mutex held above (single-threaded gxccd SDK access); `id` was just emitted by gxccd_enumerate_usb via enumerate_callback so it is a valid camera ID for gxccd_initialize_usb.
        let handle = unsafe { (sdk.initialize_usb)(id) };
        if handle.is_null() {
            continue;
        }

        // Get camera description
        let mut name_buf = [0 as c_char; 256];
        // SAFETY: moravian_mutex held; `handle` was just successfully initialized (non-null check above); name_buf is a 256-byte stack array and we pass its truthful length as `size_t` so the SDK cannot overrun.
        if unsafe {
            (sdk.get_string_parameter)(
                handle,
                GSP_CAMERA_DESCRIPTION,
                name_buf.as_mut_ptr(),
                name_buf.len(),
            )
        } >= 0
        {
            // SAFETY: name_buf is 256 bytes and the SDK guarantees NUL-termination within the buffer on success (>= 0) per gxccd.h:306-311.
            let name = unsafe { std::ffi::CStr::from_ptr(name_buf.as_ptr()) }
                .to_string_lossy()
                .trim()
                .to_string();

            // Get serial number
            let mut serial_buf = [0 as c_char; 64];
            // SAFETY: moravian_mutex held; `handle` is still the successfully-initialized one from above; serial_buf is 64 bytes and its truthful length is passed as `size_t`.
            let serial_number = if unsafe {
                (sdk.get_string_parameter)(
                    handle,
                    GSP_CAMERA_SERIAL,
                    serial_buf.as_mut_ptr(),
                    serial_buf.len(),
                )
            } >= 0
            {
                // SAFETY: serial_buf is 64 bytes; the SDK guarantees NUL-termination on success.
                let serial = unsafe { std::ffi::CStr::from_ptr(serial_buf.as_ptr()) }
                    .to_string_lossy()
                    .trim()
                    .to_string();
                if !serial.is_empty() {
                    Some(serial)
                } else {
                    None
                }
            } else {
                None
            };

            devices.push(MoravianCameraInfo {
                camera_id: id,
                name,
                serial_number,
                discovery_index: index,
            });
        }

        // Release temporary handle
        // SAFETY: moravian_mutex held; `handle` was successfully initialized at the top of this iteration; gxccd_release pairs with gxccd_initialize_usb per gxccd.h:206-211.
        unsafe { (sdk.release)(handle) };
    }

    Ok(devices)
}
