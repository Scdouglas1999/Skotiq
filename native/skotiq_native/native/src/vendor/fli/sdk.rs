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
pub(crate) type FLIStepMotor = unsafe extern "C" fn(dev: FliDev, steps: c_long) -> c_long;
pub(crate) type FLIStepMotorAsync = unsafe extern "C" fn(dev: FliDev, steps: c_long) -> c_long;
pub(crate) type FLIGetStepperPosition =
    unsafe extern "C" fn(dev: FliDev, position: *mut c_long) -> c_long;
pub(crate) type FLIGetStepsRemaining =
    unsafe extern "C" fn(dev: FliDev, steps: *mut c_long) -> c_long;
pub(crate) type FLIGetFocuserExtent =
    unsafe extern "C" fn(dev: FliDev, extent: *mut c_long) -> c_long;
pub(crate) type FLIReadTemperature =
    unsafe extern "C" fn(dev: FliDev, channel: c_long, temperature: *mut c_double) -> c_long;
pub(crate) type FLIEndExposure = unsafe extern "C" fn(dev: FliDev) -> c_long;

/// Candidate paths for libfli, in search order.
pub(crate) fn fli_candidate_paths() -> Vec<std::path::PathBuf> {
    let lib_name = if cfg!(target_os = "windows") {
        "libfli.dll"
    } else if cfg!(target_os = "macos") {
        "libfli.dylib"
    } else {
        "libfli.so"
    };
    let system_paths = if cfg!(target_os = "linux") {
        vec![
            format!("/usr/lib/{lib_name}"),
            format!("/usr/local/lib/{lib_name}"),
        ]
    } else if cfg!(target_os = "macos") {
        vec![
            format!("/usr/local/lib/{lib_name}"),
            format!("/opt/homebrew/lib/{lib_name}"),
        ]
    } else {
        Vec::new()
    };
    let system_path_refs = system_paths.iter().map(String::as_str).collect::<Vec<_>>();
    crate::vendor::sdk_loader::vendor_library_candidates(&[lib_name], &system_path_refs)
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
        step_motor: b"FLIStepMotor\0" => FLIStepMotor,
        step_motor_async: b"FLIStepMotorAsync\0" => FLIStepMotorAsync,
        get_stepper_position: b"FLIGetStepperPosition\0" => FLIGetStepperPosition,
        get_steps_remaining: b"FLIGetStepsRemaining\0" => FLIGetStepsRemaining,
        get_focuser_extent: b"FLIGetFocuserExtent\0" => FLIGetFocuserExtent,
        read_temperature: b"FLIReadTemperature\0" => FLIReadTemperature,
        end_exposure: b"FLIEndExposure\0" => FLIEndExposure,
    }
}

pub(crate) fn get_sdk() -> Result<&'static FliSdk, NativeError> {
    FliSdk::get_or_reason().map_err(|reason| NativeError::SdkError(reason.to_string()))
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

pub(crate) fn check_fli_error(result: c_long, context: &str) -> Result<(), NativeError> {
    if result == 0 {
        Ok(())
    } else {
        tracing::error!(
            "FLI SDK error during '{}': error code {}. Check device connection and driver installation.",
            context, result
        );
        Err(NativeError::SdkError(format!(
            "FLI {}: error code {}. Ensure device is connected and libfli driver is installed.",
            context, result
        )))
    }
}

pub(crate) fn close_fli_handle(sdk: &FliSdk, handle: &mut FliDev) {
    if *handle == FLI_INVALID_DEVICE {
        return;
    }

    // SAFETY: caller holds fli_mutex and handle was returned by a successful FLIOpen.
    unsafe { (sdk.close)(*handle) };
    *handle = FLI_INVALID_DEVICE;
}
