//! DSLR / mirrorless camera detection.

use super::*;

/// Detected DSLR/mirrorless camera info from autodetect
#[derive(Debug, Clone)]
pub struct DetectedGPhoto2Camera {
    pub model: String,
    pub port: String,
    pub index: usize,
    pub device_id: String,
    pub sdk_version: Option<String>,
}

pub(crate) unsafe fn gphoto2_version_from_array(versions: *const *const c_char) -> Option<String> {
    if versions.is_null() {
        return None;
    }

    // SAFETY: caller guarantees `versions` is the const char** returned by libgphoto2.
    let first = unsafe { *versions };
    if first.is_null() {
        return None;
    }

    // SAFETY: libgphoto2 returns static, NUL-terminated version strings.
    let version = unsafe { CStr::from_ptr(first) }
        .to_string_lossy()
        .trim()
        .to_string();
    (!version.is_empty()).then_some(format!("libgphoto2 v{version}"))
}

pub(crate) fn sdk_version_from_sdk(sdk: &GPhoto2Sdk) -> Option<String> {
    let library_version = sdk.library_version?;
    // SAFETY: gp_library_version(GP_VERSION_SHORT=0) returns a const char** array owned by
    // libgphoto2. We read only the first short-version entry.
    unsafe { gphoto2_version_from_array(library_version(0)) }
}

/// Detect all connected gPhoto2-compatible cameras.
///
/// Returns a list of detected cameras with their model names and USB ports.
/// This function uses `gp_camera_autodetect` to find all connected PTP cameras.
pub fn detect_gphoto2_cameras() -> Vec<DetectedGPhoto2Camera> {
    let sdk = match GPhoto2Sdk::installed() {
        Ok(sdk) => sdk,
        Err(_) => return Vec::new(),
    };

    // Unlocked on purpose: device discovery calls this synchronous function
    // without the gphoto2 lock and cannot wait for it here. `connect` runs the
    // same scan under its guard.
    detect_cameras_with(sdk.unlocked())
}

/// The autodetect scan itself, for a caller that already has the function
/// table: `connect` under its guard, or `detect_gphoto2_cameras`.
pub(crate) fn detect_cameras_with(sdk: &GPhoto2Sdk) -> Vec<DetectedGPhoto2Camera> {
    // SAFETY: All `gp_*` calls are paired with their explicit free/unref calls
    // before this block exits — `context_unref` matches `context_new`, `list_free`
    // matches `list_new`. Out-pointers (`list`) and the stack-owned `count` are valid
    // local addresses for the duration of the call.
    unsafe {
        let sdk_version = sdk_version_from_sdk(sdk);
        let context = (sdk.context_new)();
        if context.is_null() {
            tracing::error!("gPhoto2: Failed to create context");
            return Vec::new();
        }

        let mut list: *mut CameraList = std::ptr::null_mut();
        let ret = (sdk.list_new)(&mut list);
        if ret < GP_OK || list.is_null() {
            tracing::error!("gPhoto2: Failed to create camera list: {}", ret);
            (sdk.context_unref)(context);
            return Vec::new();
        }

        let ret = (sdk.camera_autodetect)(list, context);
        if ret < GP_OK {
            tracing::debug!("gPhoto2: No cameras detected (code {})", ret);
            (sdk.list_free)(list);
            (sdk.context_unref)(context);
            return Vec::new();
        }

        let count = (sdk.list_count)(list);
        let mut cameras = Vec::new();

        for i in 0..count {
            let mut name_ptr: *const c_char = std::ptr::null();
            let mut value_ptr: *const c_char = std::ptr::null();

            if (sdk.list_get_name)(list, i, &mut name_ptr) >= GP_OK
                && (sdk.list_get_value)(list, i, &mut value_ptr) >= GP_OK
            {
                let model = if !name_ptr.is_null() {
                    CStr::from_ptr(name_ptr).to_string_lossy().to_string()
                } else {
                    format!("Unknown Camera {}", i)
                };

                let port = if !value_ptr.is_null() {
                    CStr::from_ptr(value_ptr).to_string_lossy().to_string()
                } else {
                    String::new()
                };

                cameras.push(DetectedGPhoto2Camera {
                    device_id: build_device_id(i as usize, &model, &port),
                    model,
                    port,
                    index: i as usize,
                    sdk_version: sdk_version.clone(),
                });
            }
        }

        (sdk.list_free)(list);
        (sdk.context_unref)(context);

        tracing::info!("gPhoto2: Detected {} cameras", cameras.len());
        for cam in &cameras {
            tracing::info!("  - {} on {}", cam.model, cam.port);
        }

        cameras
    }
}

/// The attached camera a connect opens: the one on the recorded port when it
/// is still this model there, else the only attached camera of this model (a
/// USB replug gives a body a new port number). `model_key` is the model as a
/// device address carries it (`sanitize_id` of libgphoto2's name).
pub(crate) fn select_camera<'a>(
    detected: &'a [DetectedGPhoto2Camera],
    model_key: &str,
    port: &str,
) -> Result<&'a DetectedGPhoto2Camera, DriverError> {
    let is_model = |c: &&DetectedGPhoto2Camera| sanitize_id(&c.model) == model_key;
    if let Some(same) = detected
        .iter()
        .filter(is_model)
        .find(|c| !port.is_empty() && c.port == port)
    {
        return Ok(same);
    }
    let mut same_model = detected.iter().filter(is_model);
    match (same_model.next(), same_model.next()) {
        (Some(only), None) => {
            if !port.is_empty() {
                tracing::info!(
                    "gPhoto2: {} is now on {} (it was on {})",
                    only.model,
                    only.port,
                    port
                );
            }
            Ok(only)
        }
        (None, _) => Err(DriverError::DeviceNotFound(format!(
            "gPhoto2: no {model_key} camera is attached. Check that it is switched on, \
             connected by USB and set to PC (PTP) connection mode."
        ))),
        (Some(first), Some(_)) => Err(DriverError::InvalidDevice(format!(
            "gPhoto2: several {} bodies are attached and none is on {port}, the port this \
             one was found on. Search for devices again and pick the body.",
            first.model
        ))),
    }
}

pub fn is_sdk_available() -> bool {
    GPhoto2Sdk::is_available()
}
