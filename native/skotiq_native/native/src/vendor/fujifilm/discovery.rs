//! FUJIFILM device discovery.

use super::*;

pub struct FujifilmDeviceInfo {
    pub name: String,
    pub serial_number: Option<String>,
    pub firmware_version: Option<String>,
    pub model: FujifilmModel,
    pub connection_type: String,
}

impl FujifilmDeviceInfo {
    /// How the device catalog addresses this body: its serial number, or its
    /// product name when it reports none.
    pub(crate) fn address(&self) -> &str {
        self.serial_number.as_deref().unwrap_or(&self.name)
    }
}

/// The cameras the SDK enumerates, in enumeration order: entry `n` is the
/// body `XSDK_OpenEx` opens as "ENUM:n". An entry the SDK marks invalid is
/// `None` so the positions of the others stay right.
pub(crate) async fn list_cameras(
    sdk: &FujifilmSdk,
) -> Result<Vec<Option<FujifilmDeviceInfo>>, DriverError> {
    let mut count: c_long = 0;
    for attempt in 1..=3 {
        // SAFETY: XSDK_Detect accepts NULL for the two reserved interface-options pointers (per XAPI.h); `&mut count` is a valid stack out-pointer to c_long; XSDK_DSC_IF_USB is the documented USB interface constant.
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

    if count <= 0 {
        return Ok(Vec::new());
    }

    let mut camera_list = vec![XsdkCameraList::default(); count as usize];
    let mut listed: c_long = count;
    // SAFETY: `camera_list` is a Vec of exactly `count` XsdkCameraList entries (each `#[repr(C, packed)]`); `camera_list.as_mut_ptr()` is a valid pointer to that contiguous buffer; XSDK_Append writes at most `*plCount` entries and updates it to the number written, per XAPI.h.
    let result = unsafe {
        (sdk.append)(
            XSDK_DSC_IF_USB,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut listed,
            camera_list.as_mut_ptr(),
        )
    };
    if result != XSDK_COMPLETE {
        return Err(sdk_error(
            std::ptr::null_mut(),
            sdk,
            "listing the attached cameras",
        ));
    }

    Ok(camera_list
        .iter()
        .take((listed.max(0) as usize).min(camera_list.len()))
        .map(|cam| {
            if !cam.b_valid {
                return None;
            }
            let name = cstr_to_string(&cam.str_product);
            let serial = cstr_to_string(&cam.str_serial_no);
            Some(FujifilmDeviceInfo {
                model: FujifilmModel::from_product_name(&name),
                name,
                serial_number: (!serial.is_empty()).then_some(serial),
                firmware_version: None,
                connection_type: cstr_to_string(&cam.str_framework),
            })
        })
        .collect())
}

pub async fn discover_devices() -> Result<Vec<FujifilmDeviceInfo>, DriverError> {
    let sdk = FujifilmSdk::lock().await?;

    // SAFETY: XSDK_Init accepts `std::ptr::null_mut()` for its reserved parameter per XAPI.h. The "already initialized" error is intentionally swallowed via `let _` because discover may be called repeatedly.
    let _ = unsafe { (sdk.init)(std::ptr::null_mut()) };

    Ok(list_cameras(&sdk).await?.into_iter().flatten().collect())
}

pub fn is_sdk_available() -> bool {
    FujifilmSdk::is_available()
}
