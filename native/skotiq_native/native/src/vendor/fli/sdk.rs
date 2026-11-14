//! FLI SDK function pointers and loading.

use super::*;

pub(crate) type FLIOpen =
    unsafe extern "C" fn(dev: *mut FliDev, name: *const c_char, domain: c_long) -> c_long;
pub(crate) type FLIClose = unsafe extern "C" fn(dev: FliDev) -> c_long;
pub(crate) type FLIGetModel =
    unsafe extern "C" fn(dev: FliDev, model: *mut c_char, len: usize) -> c_long;
pub(crate) type FLIGetSerialString =
    unsafe extern "C" fn(dev: FliDev, serial: *mut c_char, len: usize) -> c_long;
pub(crate) type FLIGetPixelSize =
    unsafe extern "C" fn(dev: FliDev, pixel_x: *mut c_double, pixel_y: *mut c_double) -> c_long;
pub(crate) type FLIGetVisibleArea = unsafe extern "C" fn(
    dev: FliDev,
    ul_x: *mut c_long,
    ul_y: *mut c_long,
    lr_x: *mut c_long,
    lr_y: *mut c_long,
) -> c_long;
pub(crate) type FLISetExposureTime = unsafe extern "C" fn(dev: FliDev, exptime: c_long) -> c_long;
pub(crate) type FLISetImageArea = unsafe extern "C" fn(
    dev: FliDev,
    ul_x: c_long,
    ul_y: c_long,
    lr_x: c_long,
    lr_y: c_long,
) -> c_long;
pub(crate) type FLISetHBin = unsafe extern "C" fn(dev: FliDev, hbin: c_long) -> c_long;
pub(crate) type FLISetVBin = unsafe extern "C" fn(dev: FliDev, vbin: c_long) -> c_long;
pub(crate) type FLISetFrameType = unsafe extern "C" fn(dev: FliDev, frametype: c_long) -> c_long;
pub(crate) type FLIExposeFrame = unsafe extern "C" fn(dev: FliDev) -> c_long;
pub(crate) type FLICancelExposure = unsafe extern "C" fn(dev: FliDev) -> c_long;
pub(crate) type FLIGetExposureStatus =
    unsafe extern "C" fn(dev: FliDev, timeleft: *mut c_long) -> c_long;
pub(crate) type FLISetTemperature =
    unsafe extern "C" fn(dev: FliDev, temperature: c_double) -> c_long;
pub(crate) type FLIGetTemperature =
    unsafe extern "C" fn(dev: FliDev, temperature: *mut c_double) -> c_long;
pub(crate) type FLIGetCoolerPower =
    unsafe extern "C" fn(dev: FliDev, power: *mut c_double) -> c_long;
pub(crate) type FLIGrabRow =
    unsafe extern "C" fn(dev: FliDev, buff: *mut u8, width: usize) -> c_long;
pub(crate) type FLISetBitDepth = unsafe extern "C" fn(dev: FliDev, bitdepth: c_long) -> c_long;
pub(crate) type FLIGetDeviceStatus =
    unsafe extern "C" fn(dev: FliDev, status: *mut c_long) -> c_long;
pub(crate) type FLIGetLibVersion = unsafe extern "C" fn(ver: *mut c_char, len: usize) -> c_long;
pub(crate) type FLICreateList = unsafe extern "C" fn(domain: c_long) -> c_long;
pub(crate) type FLIDeleteList = unsafe extern "C" fn() -> c_long;
pub(crate) type FLIListFirst = unsafe extern "C" fn(
    domain: *mut c_long,
    filename: *mut c_char,
    fnlen: usize,
    name: *mut c_char,
    namelen: usize,
) -> c_long;
pub(crate) type FLIListNext = unsafe extern "C" fn(
    domain: *mut c_long,
    filename: *mut c_char,
    fnlen: usize,
    name: *mut c_char,
    namelen: usize,
) -> c_long;
pub(crate) type FLISetFilterPos = unsafe extern "C" fn(dev: FliDev, filter: c_long) -> c_long;
pub(crate) type FLIGetFilterPos = unsafe extern "C" fn(dev: FliDev, filter: *mut c_long) -> c_long;
pub(crate) type FLIGetFilterCount =
    unsafe extern "C" fn(dev: FliDev, filter: *mut c_long) -> c_long;
pub(crate) type FLIStepMotorAsync = unsafe extern "C" fn(dev: FliDev, steps: c_long) -> c_long;
pub(crate) type FLIGetStepperPosition =
    unsafe extern "C" fn(dev: FliDev, position: *mut c_long) -> c_long;
pub(crate) type FLIGetStepsRemaining =
    unsafe extern "C" fn(dev: FliDev, steps: *mut c_long) -> c_long;
pub(crate) type FLIGetFocuserExtent =
    unsafe extern "C" fn(dev: FliDev, extent: *mut c_long) -> c_long;
pub(crate) type FLIReadTemperature =
    unsafe extern "C" fn(dev: FliDev, channel: c_long, temperature: *mut c_double) -> c_long;
pub(crate) type FLIGetFilterName =
    unsafe extern "C" fn(dev: FliDev, filter: c_long, name: *mut c_char, len: usize) -> c_long;

/// Library file names for libfli, in search order.
///
/// FLI's Windows SDK ships the 64-bit library as `libfli64.dll` (NINA renames
/// it to `libfli.dll`). The INDI packages for Debian, Ubuntu and Raspberry Pi
/// OS install only the versioned `libfli.so.2` (`libfli.so` comes with the
/// -dev package), and older ones `libfli.so.1`.
fn fli_library_names() -> &'static [&'static str] {
    if cfg!(target_os = "windows") {
        &["libfli.dll", "libfli64.dll"]
    } else if cfg!(target_os = "macos") {
        &["libfli.dylib", "libfli.2.dylib"]
    } else {
        &["libfli.so", "libfli.so.2", "libfli.so.1"]
    }
}

/// Candidate paths for libfli, in search order.
pub(crate) fn fli_candidate_paths() -> Vec<std::path::PathBuf> {
    let names = fli_library_names();
    let dirs: &[&str] = if cfg!(target_os = "linux") {
        &["/usr/lib", "/usr/local/lib"]
    } else if cfg!(target_os = "macos") {
        &["/usr/local/lib", "/opt/homebrew/lib"]
    } else {
        &[]
    };
    let system_paths = dirs
        .iter()
        .flat_map(|dir| names.iter().map(move |name| format!("{dir}/{name}")))
        .collect::<Vec<_>>();
    let system_path_refs = system_paths.iter().map(String::as_str).collect::<Vec<_>>();
    crate::vendor::sdk_loader::vendor_library_candidates(names, &system_path_refs)
}

crate::load_vendor_sdk! {
    /// FLI SDK wrapper with dynamically loaded functions
    vendor_name: "FLI",
    sdk_struct: FliSdk,
    sdk_static: SDK,
    candidate_paths_fn: fli_candidate_paths,
    symbols: {
        open: b"FLIOpen\0" => FLIOpen,
        close: b"FLIClose\0" => FLIClose,
        get_model: b"FLIGetModel\0" => FLIGetModel,
        get_serial_string: b"FLIGetSerialString\0" => FLIGetSerialString,
        get_pixel_size: b"FLIGetPixelSize\0" => FLIGetPixelSize,
        get_visible_area: b"FLIGetVisibleArea\0" => FLIGetVisibleArea,
        set_exposure_time: b"FLISetExposureTime\0" => FLISetExposureTime,
        set_image_area: b"FLISetImageArea\0" => FLISetImageArea,
        set_hbin: b"FLISetHBin\0" => FLISetHBin,
        set_vbin: b"FLISetVBin\0" => FLISetVBin,
        set_frame_type: b"FLISetFrameType\0" => FLISetFrameType,
        expose_frame: b"FLIExposeFrame\0" => FLIExposeFrame,
        cancel_exposure: b"FLICancelExposure\0" => FLICancelExposure,
        get_exposure_status: b"FLIGetExposureStatus\0" => FLIGetExposureStatus,
        set_temperature: b"FLISetTemperature\0" => FLISetTemperature,
        get_temperature: b"FLIGetTemperature\0" => FLIGetTemperature,
        get_cooler_power: b"FLIGetCoolerPower\0" => FLIGetCoolerPower,
        grab_row: b"FLIGrabRow\0" => FLIGrabRow,
        set_bit_depth: b"FLISetBitDepth\0" => FLISetBitDepth,
        get_device_status: b"FLIGetDeviceStatus\0" => FLIGetDeviceStatus,
        get_lib_version: b"FLIGetLibVersion\0" => FLIGetLibVersion,
        create_list: b"FLICreateList\0" => FLICreateList,
        delete_list: b"FLIDeleteList\0" => FLIDeleteList,
        list_first: b"FLIListFirst\0" => FLIListFirst,
        list_next: b"FLIListNext\0" => FLIListNext,
        set_filter_pos: b"FLISetFilterPos\0" => FLISetFilterPos,
        get_filter_pos: b"FLIGetFilterPos\0" => FLIGetFilterPos,
        get_filter_count: b"FLIGetFilterCount\0" => FLIGetFilterCount,
        step_motor_async: b"FLIStepMotorAsync\0" => FLIStepMotorAsync,
        get_stepper_position: b"FLIGetStepperPosition\0" => FLIGetStepperPosition,
        get_steps_remaining: b"FLIGetStepsRemaining\0" => FLIGetStepsRemaining,
        get_focuser_extent: b"FLIGetFocuserExtent\0" => FLIGetFocuserExtent,
        read_temperature: b"FLIReadTemperature\0" => FLIReadTemperature,
        get_filter_name: b"FLIGetFilterName\0" => FLIGetFilterName,
    }
}

/// What one libfli return code means for a call that asks a device to do
/// something it may not have.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum FliCapabilityAnswer {
    /// The device did it.
    Done,
    /// The device has no such control. libfli answers a command a model does
    /// not implement with a negative errno from a small documented set, not
    /// with a device-specific failure.
    NotSupported(c_long),
    /// The call reached the device and failed.
    Failed(c_long),
}

/// libfli's "this device has no such command" answers, as negative errno.
///
/// `EINVAL` is in the set because libfli's per-model dispatch returns it for a
/// command a model does not implement; the others are the generic
/// not-implemented codes. Everything else is a real failure.
const FLI_NOT_SUPPORTED: [c_long; 4] = [
    -22, // EINVAL
    -25, // ENOTTY
    -38, // ENOSYS
    -95, // EOPNOTSUPP
];

/// Classify a libfli return code for an optional capability.
pub(crate) fn fli_capability_answer(result: c_long) -> FliCapabilityAnswer {
    if result == 0 {
        FliCapabilityAnswer::Done
    } else if FLI_NOT_SUPPORTED.contains(&result) {
        FliCapabilityAnswer::NotSupported(result)
    } else {
        FliCapabilityAnswer::Failed(result)
    }
}

/// What a libfli failure code means, in words a user can act on. libfli
/// returns negative errno values; the C runtimes agree on the small ones and
/// differ on ETIMEDOUT (110 with glibc and macOS 60, 138 with MSVC).
pub(crate) fn fli_error_text(code: c_long) -> String {
    let meaning = match -code {
        5 => Some("the device did not answer over USB"),
        6 | 19 => Some("the device is not attached; check the USB cable and its power"),
        13 | 16 => Some("the device is in use by another program"),
        12 => Some("libfli ran out of memory"),
        60 | 110 | 138 => Some("the device timed out"),
        22 => Some("the device refused the request"),
        _ => None,
    };
    match meaning {
        Some(meaning) => format!("{meaning} (libfli code {code})"),
        None => format!("libfli code {code}"),
    }
}

pub(crate) fn check_fli_error(result: c_long, context: &str) -> Result<(), DriverError> {
    if result == 0 {
        Ok(())
    } else {
        let text = fli_error_text(result);
        tracing::error!("FLI {} failed: {}", context, text);
        let detail = format!("FLI {context} failed: {text}");
        Err(match -result {
            // Not attached: the caller reconnects it. The words are logged above;
            // the bridge names the device in its not-connected message.
            6 | 19 => DriverError::Disconnected,
            60 | 110 | 138 => DriverError::Timeout(detail),
            22 => DriverError::InvalidParameter(detail),
            _ => DriverError::SdkError(detail),
        })
    }
}

pub(crate) fn close_fli_handle(sdk: &FliSdk, handle: &mut FliDev) {
    if *handle == FLI_INVALID_DEVICE {
        return;
    }

    // SAFETY: the caller passes the table from its SDK guard and handle was returned by a successful FLIOpen.
    unsafe { (sdk.close)(*handle) };
    *handle = FLI_INVALID_DEVICE;
}

#[cfg(test)]
mod error_kind_tests {
    use super::*;

    /// A camera pulled off the bus is a lost device the run reconnects; a
    /// timeout and a refused value keep their own kinds and libfli's meaning.
    #[test]
    fn libfli_codes_reach_callers_as_the_failure_they_name() {
        assert!(matches!(
            check_fli_error(-19, "expose"),
            Err(DriverError::Disconnected)
        ));
        assert!(matches!(
            check_fli_error(-110, "download"),
            Err(DriverError::Timeout(text)) if text.contains("the device timed out")
        ));
        assert!(matches!(
            check_fli_error(-22, "set gain"),
            Err(DriverError::InvalidParameter(text)) if text.contains("refused the request")
        ));
        assert!(matches!(
            check_fli_error(-5, "expose"),
            Err(DriverError::SdkError(text)) if text.contains("did not answer over USB")
        ));
    }
}
