//! ToupTek-family camera discovery.

use super::*;

/// Information about a discovered Touptek camera
#[derive(Debug, Clone)]
pub struct TouptekDeviceInfo {
    pub camera_id: String,
    pub name: String,
    pub serial_number: Option<String>,
    pub discovery_index: usize,
    pub model_flags: u64,
    /// Upper bound of the fan-speed scale reported by the model table. Fan speed runs
    /// over the closed interval `[0, max_fan_speed]`, so a percentage needs this value.
    pub max_fan_speed: u32,
    pub width: u32,
    pub height: u32,
    pub pixel_size_x: f32,
    pub pixel_size_y: f32,
    /// Which brand SDK this camera was discovered through
    pub brand: String,
    pub sdk_version: Option<String>,
}

/// Stable SDK IDs captured by discovery, keyed by the legacy brand/index selector used by
/// the bridge. A camera snapshots the ID in `new()` and thereafter opens by that ID, so a
/// later enumeration reorder cannot redirect an existing camera object to different hardware.
pub(crate) static DISCOVERED_DEVICE_IDS: OnceLock<Mutex<HashMap<(String, usize), String>>> =
    OnceLock::new();

pub(crate) fn discovered_device_ids() -> &'static Mutex<HashMap<(String, usize), String>> {
    DISCOVERED_DEVICE_IDS.get_or_init(|| Mutex::new(HashMap::new()))
}

#[cfg(windows)]
pub(crate) fn touptek_device_string(value: &[OgmacamChar; 64]) -> String {
    let len = value.iter().position(|&c| c == 0).unwrap_or(value.len());
    String::from_utf16_lossy(&value[..len])
}

#[cfg(not(windows))]
pub(crate) fn touptek_device_string(value: &[OgmacamChar; 64]) -> String {
    let len = value.iter().position(|&c| c == 0).unwrap_or(value.len());
    let bytes: Vec<u8> = value[..len].iter().map(|&c| c as u8).collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

pub(crate) fn enumerate_brand_devices_from_sdk(
    sdk: &TouptekSdk,
    brand: &str,
) -> Vec<TouptekDeviceInfo> {
    let mut devices = Vec::new();
    let sdk_version = sdk_version_from_sdk(sdk, brand);
    // SAFETY: OgmacamDeviceV2 is `#[repr(C)]` containing only fixed-size character arrays
    // plus a raw model pointer; all-zero is valid for both character representations and
    // for the null pointer. OGMACAM_MAX matches the SDK's documented enumeration cap.
    let mut arr: Vec<OgmacamDeviceV2> = vec![unsafe { std::mem::zeroed() }; OGMACAM_MAX];
    // SAFETY: caller (discover_devices / discover_devices_for_brand) holds touptek_mutex; `arr.as_mut_ptr()` points to a contiguous buffer of OGMACAM_MAX `#[repr(C)]` OgmacamDeviceV2 entries; OgmacamEnumV2 fills at most OGMACAM_MAX entries and returns the count, per the SDK header.
    let count = unsafe { (sdk.enum_v2)(arr.as_mut_ptr()) };

    // Why: count is c_uint (u32) returned by OgmacamEnumV2; widening u32 -> usize is
    // value-preserving on every Tier 1 target.
    for i in 0..count as usize {
        let dev = &arr[i];

        let name = touptek_device_string(&dev.displayname);
        let id = touptek_device_string(&dev.id);

        let (flags, max_fan_speed, width, height, pixel_x, pixel_y) = if !dev.model.is_null() {
            // SAFETY: `dev.model` was just verified non-null on the line above; it points to a `#[repr(C)]` OgmacamModelV2 owned by the SDK shared library (string tables live in the .rdata segment) so the pointer remains valid for the lifetime of the loaded library — which is held by the cached TouptekSdk in `static SDKS`. We borrow a shared reference (no mutation), which is sound for the borrow scope.
            let model = unsafe { &*dev.model };
            let res = model.res[0];
            (
                model.flag,
                model.maxfanspeed,
                res.width,
                res.height,
                model.xpixsz,
                model.ypixsz,
            )
        } else {
            (0, 0, 0, 0, 0.0, 0.0)
        };

        devices.push(TouptekDeviceInfo {
            camera_id: id,
            name,
            serial_number: None,
            discovery_index: i,
            model_flags: flags,
            max_fan_speed,
            width,
            height,
            pixel_size_x: pixel_x,
            pixel_size_y: pixel_y,
            brand: brand.to_string(),
            sdk_version: sdk_version.clone(),
        });
    }

    let brand_key = brand.to_ascii_lowercase();
    let mut cached_ids = discovered_device_ids()
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    cached_ids.retain(|(cached_brand, _), _| cached_brand != &brand_key);
    for device in &devices {
        cached_ids.insert(
            (brand_key.clone(), device.discovery_index),
            device.camera_id.clone(),
        );
    }

    devices
}

/// Discover connected Touptek cameras across all supported brands
///
/// Iterates over all known Touptek white-label SDKs, attempts to load each,
/// and enumerates cameras from each successfully loaded SDK.
pub async fn discover_devices() -> Result<Vec<TouptekDeviceInfo>, NativeError> {
    // Acquire global SDK mutex for thread safety
    let _lock = touptek_mutex().lock().await;

    let mut devices = Vec::new();
    let mut loaded_sdk_count = 0usize;
    let mut load_errors = Vec::new();

    for &(dll_name, _func_prefix, brand_name) in TOUPTEK_BRANDS {
        if let Err(err) = get_sdk_for_brand(brand_name) {
            tracing::debug!(
                "Touptek brand SDK '{}' ({}) not available, skipping",
                brand_name,
                dll_name
            );
            load_errors.push((
                brand_name.to_string(),
                dll_name.to_string(),
                err.to_string(),
            ));
            continue;
        }
        loaded_sdk_count += 1;

        let brand_devices = with_sdk(brand_name, |sdk| {
            Ok(enumerate_brand_devices_from_sdk(sdk, brand_name))
        })?;

        if !brand_devices.is_empty() {
            tracing::info!("Found {} {} cameras", brand_devices.len(), brand_name);
        }
        devices.extend(brand_devices);
    }

    if loaded_sdk_count == 0 {
        let err = touptek_no_sdk_loaded_error(&load_errors);
        tracing::warn!("{}", err);
        return Err(err);
    }

    Ok(devices)
}

/// Discover connected Touptek cameras for a specific brand only
pub async fn discover_devices_for_brand(
    brand: &str,
) -> Result<Vec<TouptekDeviceInfo>, NativeError> {
    let _lock = touptek_mutex().lock().await;

    get_sdk_for_brand(brand)?;

    with_sdk(brand, |sdk| {
        Ok(enumerate_brand_devices_from_sdk(sdk, brand))
    })
}
