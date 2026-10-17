//! SVBony SDK function pointers and loading.

use super::*;

pub(crate) type SvbGetNumOfConnectedCameras = unsafe extern "C" fn() -> c_int;
pub(crate) type SvbGetCameraInfo =
    unsafe extern "C" fn(info: *mut SvbCameraInfo, index: c_int) -> c_int;
pub(crate) type SvbGetCameraProperty =
    unsafe extern "C" fn(camera_id: c_int, prop: *mut SvbCameraProperty) -> c_int;
pub(crate) type SvbGetCameraPropertyEx =
    unsafe extern "C" fn(camera_id: c_int, prop: *mut SvbCameraPropertyEx) -> c_int;
// SVBGetSensorPixelSize(int iCameraID, float *fPixelSize) — pixel size in µm.
// SVB_CAMERA_PROPERTY has NO pixel-size field (unlike ZWO), so this is the only
// source; the reference driver (svbony_base.cpp:760) queries it the same way.
pub(crate) type SvbGetSensorPixelSize =
    unsafe extern "C" fn(camera_id: c_int, pixel_size: *mut f32) -> c_int;
pub(crate) type SvbOpenCamera = unsafe extern "C" fn(camera_id: c_int) -> c_int;
pub(crate) type SvbCloseCamera = unsafe extern "C" fn(camera_id: c_int) -> c_int;
pub(crate) type SvbGetNumOfControls =
    unsafe extern "C" fn(camera_id: c_int, num: *mut c_int) -> c_int;
pub(crate) type SvbGetControlCaps =
    unsafe extern "C" fn(camera_id: c_int, index: c_int, caps: *mut SvbControlCaps) -> c_int;
pub(crate) type SvbGetControlValue = unsafe extern "C" fn(
    camera_id: c_int,
    ctrl_type: c_int,
    value: *mut c_long,
    is_auto: *mut c_int,
) -> c_int;
pub(crate) type SvbSetControlValue = unsafe extern "C" fn(
    camera_id: c_int,
    ctrl_type: c_int,
    value: c_long,
    is_auto: c_int,
) -> c_int;
pub(crate) type SvbSetROIFormat = unsafe extern "C" fn(
    camera_id: c_int,
    start_x: c_int,
    start_y: c_int,
    width: c_int,
    height: c_int,
    bin: c_int,
) -> c_int;
pub(crate) type SvbGetROIFormat = unsafe extern "C" fn(
    camera_id: c_int,
    start_x: *mut c_int,
    start_y: *mut c_int,
    width: *mut c_int,
    height: *mut c_int,
    bin: *mut c_int,
) -> c_int;
pub(crate) type SvbSetOutputImageType =
    unsafe extern "C" fn(camera_id: c_int, img_type: c_int) -> c_int;
pub(crate) type SvbGetOutputImageType =
    unsafe extern "C" fn(camera_id: c_int, img_type: *mut c_int) -> c_int;
pub(crate) type SvbStartVideoCapture = unsafe extern "C" fn(camera_id: c_int) -> c_int;
pub(crate) type SvbStopVideoCapture = unsafe extern "C" fn(camera_id: c_int) -> c_int;
pub(crate) type SvbGetVideoData =
    unsafe extern "C" fn(camera_id: c_int, buf: *mut u8, buf_size: c_long, wait_ms: c_int) -> c_int;
pub(crate) type SvbGetSdkVersion = unsafe extern "C" fn() -> *const c_char;

/// Candidate paths for the SVBony camera SDK, in search order.
pub(crate) fn svbony_candidate_paths() -> Vec<std::path::PathBuf> {
    let lib_name = if cfg!(target_os = "windows") {
        "SVBCameraSDK.dll"
    } else if cfg!(target_os = "macos") {
        "libSVBCameraSDK.dylib"
    } else {
        "libSVBCameraSDK.so"
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
    /// SVBony SDK wrapper with dynamically loaded functions
    vendor_name: "SVBony",
    sdk_struct: SvbonySdk,
    sdk_static: SDK,
    candidate_paths_fn: svbony_candidate_paths,
    symbols: {
        get_num_of_connected_cameras: b"SVBGetNumOfConnectedCameras\0" => SvbGetNumOfConnectedCameras,
        get_camera_info: b"SVBGetCameraInfo\0" => SvbGetCameraInfo,
        get_camera_property: b"SVBGetCameraProperty\0" => SvbGetCameraProperty,
        get_camera_property_ex: b"SVBGetCameraPropertyEx\0" => SvbGetCameraPropertyEx,
        get_sensor_pixel_size: b"SVBGetSensorPixelSize\0" => SvbGetSensorPixelSize,
        open_camera: b"SVBOpenCamera\0" => SvbOpenCamera,
        close_camera: b"SVBCloseCamera\0" => SvbCloseCamera,
        get_num_of_controls: b"SVBGetNumOfControls\0" => SvbGetNumOfControls,
        get_control_caps: b"SVBGetControlCaps\0" => SvbGetControlCaps,
        get_control_value: b"SVBGetControlValue\0" => SvbGetControlValue,
        set_control_value: b"SVBSetControlValue\0" => SvbSetControlValue,
        set_roi_format: b"SVBSetROIFormat\0" => SvbSetROIFormat,
        get_roi_format: b"SVBGetROIFormat\0" => SvbGetROIFormat,
        set_output_image_type: b"SVBSetOutputImageType\0" => SvbSetOutputImageType,
        get_output_image_type: b"SVBGetOutputImageType\0" => SvbGetOutputImageType,
        start_video_capture: b"SVBStartVideoCapture\0" => SvbStartVideoCapture,
        stop_video_capture: b"SVBStopVideoCapture\0" => SvbStopVideoCapture,
        get_video_data: b"SVBGetVideoData\0" => SvbGetVideoData,
        get_sdk_version: b"SVBGetSDKVersion\0" => SvbGetSdkVersion,
    }
}

pub(crate) fn svb_control_value_to_i32(value: i64, label: &str) -> Result<i32, NativeError> {
    i32::try_from(value).map_err(|_| {
        NativeError::SdkError(format!(
            "SVBony SDK returned out-of-range {} value: {}",
            label, value
        ))
    })
}

pub(crate) fn get_sdk() -> Result<&'static SvbonySdk, NativeError> {
    SvbonySdk::get_or_reason().map_err(|reason| NativeError::SdkError(reason.to_string()))
}
