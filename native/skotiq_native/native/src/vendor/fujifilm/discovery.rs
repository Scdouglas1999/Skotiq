//! FUJIFILM device discovery.

use super::*;

/// Information about a discovered Fujifilm device
pub struct FujifilmDeviceInfo {
    pub name: String,
    pub serial_number: Option<String>,
    pub firmware_version: Option<String>,
    pub model: FujifilmModel,
    pub connection_type: String,
}

/// Discover all connected Fujifilm cameras
pub async fn discover_devices() -> Result<Vec<FujifilmDeviceInfo>, NativeError> {
    let sdk = FujifilmSdk::get().ok_or(NativeError::SdkNotLoaded)?;
    let _lock = fujifilm_mutex().lock().await;

    // Initialize SDK (ignore "already initialized" error)
    // SAFETY: fujifilm_mutex held above; XSDK_Init accepts `std::ptr::null_mut()` for its reserved parameter per XAPI.h documentation. The "already initialized" error is intentionally swallowed via `let _` because discover may be called repeatedly.
    let _ = unsafe { (sdk.init)(std::ptr::null_mut()) };

    let mut devices = Vec::new();

    // Step 1: Detect USB devices with retry logic
    let mut count: c_long = 0;
    for attempt in 1..=3 {
        // SAFETY: fujifilm_mutex held above; XSDK_Detect accepts NULL for the two reserved interface-options pointers (per XAPI.h); `&mut count` is a valid stack out-pointer to c_long; XSDK_DSC_IF_USB is the documented USB interface constant.
        let result = unsafe {
            (sdk.detect)(
                XSDK_DSC_IF_USB,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut count,
            )
        };
        if result == XSDK_COMPLETE && count > 0 {
            break;
        }
        if attempt < 3 {
            tokio::time::sleep(Duration::from_millis(100 * (1 << attempt))).await;
        }
    }

    if count == 0 {
        return Ok(devices);
    }

    // Step 2: Get camera list
    let mut camera_list = vec![XsdkCameraList::default(); count as usize];
    let mut actual_count: c_long = 0;
    // SAFETY: fujifilm_mutex held above; `camera_list` is a Vec of exactly `count` XsdkCameraList entries (each `#[repr(C, packed)]`); `camera_list.as_mut_ptr()` is a valid pointer to that contiguous buffer; XSDK_Append will write at most `count` entries and update `*actual_count` to the number written, per XAPI.h.
    let result = unsafe {
        (sdk.append)(
            XSDK_DSC_IF_USB,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut actual_count,
            camera_list.as_mut_ptr(),
        )
    };

    if result != XSDK_COMPLETE {
        return Err(NativeError::SdkError("XSDK_Append failed".into()));
    }

    // Step 3: Convert to FujifilmDeviceInfo
    for i in 0..actual_count as usize {
        let cam = &camera_list[i];
        if !cam.b_valid {
            continue;
        }

        let name = cstr_to_string(&cam.str_product);
        let serial = cstr_to_string(&cam.str_serial_no);
        let framework = cstr_to_string(&cam.str_framework);

        devices.push(FujifilmDeviceInfo {
            name: name.clone(),
            serial_number: if serial.is_empty() {
                None
            } else {
                Some(serial)
            },
            firmware_version: None,
            model: FujifilmModel::from_product_name(&name),
            connection_type: framework,
        });
    }

    Ok(devices)
}
