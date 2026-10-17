//! Per-brand ToupTek SDK wrapper, loading and helpers.

use super::*;

pub(crate) struct TouptekSdk {
    pub(crate) _library: Library,
    pub(crate) enum_v2: OgmacamEnumV2,
    pub(crate) open: OgmacamOpen,
    pub(crate) close: OgmacamClose,
    pub(crate) stop: OgmacamStop,
    pub(crate) pull_image_v3: OgmacamPullImageV3,
    pub(crate) put_expo_time: OgmacamPutExpoTime,
    pub(crate) get_expo_again: OgmacamGetExpoAGain,
    pub(crate) put_expo_again: OgmacamPutExpoAGain,
    pub(crate) get_expo_again_range: OgmacamGetExpoAGainRange,
    pub(crate) get_temperature: OgmacamGetTemperature,
    pub(crate) put_temperature: OgmacamPutTemperature,
    pub(crate) get_raw_format: OgmacamGetRawFormat,
    pub(crate) put_option: OgmacamPutOption,
    pub(crate) get_option: OgmacamGetOption,
    pub(crate) get_size: OgmacamGetSize,
    pub(crate) put_roi: OgmacamPutRoi,
    pub(crate) get_serial_number: OgmacamGetSerialNumber,
    pub(crate) start_pull_mode_with_callback: OgmacamStartPullModeWithCallback,
    pub(crate) trigger: OgmacamTrigger,
    /// Optional: universally present in modern toupcam-family SDKs; falls back to a
    /// ROI/sensor upper bound for buffer sizing if a white-label lib omits it.
    pub(crate) get_final_size: Option<OgmacamGetFinalSize>,
    pub(crate) version: Option<OgmacamVersion>,
}

// SAFETY: TouptekSdk owns a `libloading::Library` plus a set of plain function pointers (no interior mutability). The function pointers come from a single shared library and only point to compiled code, so sending the struct between threads is sound. All actual calls into these pointers are serialized by `touptek_mutex()` plus the per-camera `Mutex<HandleWrapper>` so the Send marker reflects the real synchronization discipline.
unsafe impl Send for TouptekSdk {}
// SAFETY: &TouptekSdk only exposes immutable function pointers; the loaded Library is read-only after construction. All FFI calls that mutate camera state go through &TouptekSdk and are wrapped in `touptek_mutex()` lock sections, so concurrent &-access never races on shared state.
unsafe impl Sync for TouptekSdk {}

/// Supported Touptek white-label brands and their SDK details.
/// Each entry: (DLL name, function prefix, brand display name)
#[cfg(windows)]
pub(crate) const TOUPTEK_BRANDS: &[(&str, &str, &str)] = &[
    ("ogmacam.dll", "Ogmacam", "OGMA"),
    ("toupcam.dll", "Toupcam", "Touptek"),
    ("altaircam.dll", "Altaircam", "Altair"),
    ("mallincam.dll", "Mallincam", "Mallincam"),
];

#[cfg(target_os = "linux")]
pub(crate) const TOUPTEK_BRANDS: &[(&str, &str, &str)] = &[
    ("libogmacam.so", "Ogmacam", "OGMA"),
    ("libtoupcam.so", "Toupcam", "Touptek"),
    ("libaltaircam.so", "Altaircam", "Altair"),
    ("libmallincam.so", "Mallincam", "Mallincam"),
];

#[cfg(target_os = "macos")]
pub(crate) const TOUPTEK_BRANDS: &[(&str, &str, &str)] = &[
    ("libogmacam.dylib", "Ogmacam", "OGMA"),
    ("libtoupcam.dylib", "Toupcam", "Touptek"),
    ("libaltaircam.dylib", "Altaircam", "Altair"),
    ("libmallincam.dylib", "Mallincam", "Mallincam"),
];

impl TouptekSdk {
    pub(crate) fn load(dll_name: &str, func_prefix: &str) -> Result<Self, NativeError> {
        let system_paths = if cfg!(target_os = "linux") {
            vec![
                format!("/usr/lib/{dll_name}"),
                format!("/usr/local/lib/{dll_name}"),
            ]
        } else if cfg!(target_os = "macos") {
            vec![
                format!("/usr/local/lib/{dll_name}"),
                format!("/opt/homebrew/lib/{dll_name}"),
            ]
        } else {
            Vec::new()
        };
        let system_path_refs = system_paths.iter().map(String::as_str).collect::<Vec<_>>();
        let candidates =
            crate::vendor::sdk_loader::vendor_library_candidates(&[dll_name], &system_path_refs);

        let mut last_error = None;
        let mut loaded = None;
        for path in &candidates {
            // SAFETY: libloading::Library::new performs platform dynamic loading; `dll_name`
            // comes from the compile-time TOUPTEK_BRANDS constant array. Errors are
            // accumulated and reported as NativeError::SdkError rather than UB.
            match unsafe { Library::new(path) } {
                Ok(library) => {
                    tracing::info!("Loaded {} SDK from {}", dll_name, path.display());
                    loaded = Some(library);
                    break;
                }
                Err(e) => {
                    last_error = Some(e.to_string());
                }
            }
        }
        let library = loaded.ok_or_else(|| {
            NativeError::SdkError(format!(
                "Failed to load {} from {} candidate paths: {}",
                dll_name,
                candidates.len(),
                last_error.unwrap_or_else(|| "no candidate paths supplied".to_string())
            ))
        })?;

        // Build symbol names dynamically from the function prefix
        let sym = |suffix: &str| -> Vec<u8> {
            let mut name = format!("{}_{}", func_prefix, suffix);
            name.push('\0');
            name.into_bytes()
        };

        // SAFETY: each `library.get::<FnType>(&sym(...))` returns a `Symbol` that we immediately deref with `*` to copy out the function pointer. `sym()` always emits a NUL-terminated byte string (push('\0') is unconditional) satisfying libloading's contract. The C ABI signatures declared above use `extern "system"` and match the Touptek/Ogmacam SDK header convention. The loaded `library` is moved into the returned TouptekSdk so the function pointers remain valid for the cached SDK's lifetime (stored in `static SDKS: OnceLock<Mutex<HashMap<...>>>`).
        unsafe {
            Ok(Self {
                enum_v2: *library.get::<OgmacamEnumV2>(&sym("EnumV2")).map_err(|e| {
                    NativeError::SdkError(format!("Symbol error in {}: {}", dll_name, e))
                })?,
                open: *library.get::<OgmacamOpen>(&sym("Open")).map_err(|e| {
                    NativeError::SdkError(format!("Symbol error in {}: {}", dll_name, e))
                })?,
                close: *library.get::<OgmacamClose>(&sym("Close")).map_err(|e| {
                    NativeError::SdkError(format!("Symbol error in {}: {}", dll_name, e))
                })?,
                stop: *library.get::<OgmacamStop>(&sym("Stop")).map_err(|e| {
                    NativeError::SdkError(format!("Symbol error in {}: {}", dll_name, e))
                })?,
                pull_image_v3: *library
                    .get::<OgmacamPullImageV3>(&sym("PullImageV3"))
                    .map_err(|e| {
                        NativeError::SdkError(format!("Symbol error in {}: {}", dll_name, e))
                    })?,
                put_expo_time: *library
                    .get::<OgmacamPutExpoTime>(&sym("put_ExpoTime"))
                    .map_err(|e| {
                        NativeError::SdkError(format!("Symbol error in {}: {}", dll_name, e))
                    })?,
                get_expo_again: *library
                    .get::<OgmacamGetExpoAGain>(&sym("get_ExpoAGain"))
                    .map_err(|e| {
                        NativeError::SdkError(format!("Symbol error in {}: {}", dll_name, e))
                    })?,
                put_expo_again: *library
                    .get::<OgmacamPutExpoAGain>(&sym("put_ExpoAGain"))
                    .map_err(|e| {
                        NativeError::SdkError(format!("Symbol error in {}: {}", dll_name, e))
                    })?,
                get_expo_again_range: *library
                    .get::<OgmacamGetExpoAGainRange>(&sym("get_ExpoAGainRange"))
                    .map_err(|e| {
                        NativeError::SdkError(format!("Symbol error in {}: {}", dll_name, e))
                    })?,
                get_temperature: *library
                    .get::<OgmacamGetTemperature>(&sym("get_Temperature"))
                    .map_err(|e| {
                        NativeError::SdkError(format!("Symbol error in {}: {}", dll_name, e))
                    })?,
                put_temperature: *library
                    .get::<OgmacamPutTemperature>(&sym("put_Temperature"))
                    .map_err(|e| {
                        NativeError::SdkError(format!("Symbol error in {}: {}", dll_name, e))
                    })?,
                get_raw_format: *library
                    .get::<OgmacamGetRawFormat>(&sym("get_RawFormat"))
                    .map_err(|e| {
                        NativeError::SdkError(format!("Symbol error in {}: {}", dll_name, e))
                    })?,
                put_option: *library
                    .get::<OgmacamPutOption>(&sym("put_Option"))
                    .map_err(|e| {
                        NativeError::SdkError(format!("Symbol error in {}: {}", dll_name, e))
                    })?,
                get_option: *library
                    .get::<OgmacamGetOption>(&sym("get_Option"))
                    .map_err(|e| {
                        NativeError::SdkError(format!("Symbol error in {}: {}", dll_name, e))
                    })?,
                get_size: *library
                    .get::<OgmacamGetSize>(&sym("get_Size"))
                    .map_err(|e| {
                        NativeError::SdkError(format!("Symbol error in {}: {}", dll_name, e))
                    })?,
                put_roi: *library.get::<OgmacamPutRoi>(&sym("put_Roi")).map_err(|e| {
                    NativeError::SdkError(format!("Symbol error in {}: {}", dll_name, e))
                })?,
                get_serial_number: *library
                    .get::<OgmacamGetSerialNumber>(&sym("get_SerialNumber"))
                    .map_err(|e| {
                        NativeError::SdkError(format!("Symbol error in {}: {}", dll_name, e))
                    })?,
                start_pull_mode_with_callback: *library
                    .get::<OgmacamStartPullModeWithCallback>(&sym("StartPullModeWithCallback"))
                    .map_err(|e| {
                        NativeError::SdkError(format!("Symbol error in {}: {}", dll_name, e))
                    })?,
                trigger: *library
                    .get::<OgmacamTrigger>(&sym("Trigger"))
                    .map_err(|e| {
                        NativeError::SdkError(format!("Symbol error in {}: {}", dll_name, e))
                    })?,
                get_final_size: library
                    .get::<OgmacamGetFinalSize>(&sym("get_FinalSize"))
                    .ok()
                    .map(|symbol| *symbol),
                version: library
                    .get::<OgmacamVersion>(&sym("Version"))
                    .ok()
                    .map(|symbol| *symbol),
                _library: library,
            })
        }
    }
}

/// Multi-brand SDK storage. Each brand's SDK is loaded lazily on first use.
pub(crate) static SDKS: OnceLock<Mutex<HashMap<String, Result<TouptekSdk, String>>>> =
    OnceLock::new();

pub(crate) fn get_sdks() -> &'static Mutex<HashMap<String, Result<TouptekSdk, String>>> {
    SDKS.get_or_init(|| Mutex::new(HashMap::new()))
}

pub(crate) fn get_sdk_for_brand(brand: &str) -> Result<(), NativeError> {
    let sdks = get_sdks();
    let mut map = sdks.lock().unwrap_or_else(|e| e.into_inner());
    if map.contains_key(brand) {
        return map
            .get(brand)
            .unwrap()
            .as_ref()
            .map(|_| ())
            .map_err(|e| NativeError::SdkError(e.clone()));
    }

    // Find the brand's DLL info
    let brand_info = TOUPTEK_BRANDS
        .iter()
        .find(|(_, _, name)| name.eq_ignore_ascii_case(brand))
        .ok_or_else(|| NativeError::SdkError(format!("Unknown Touptek brand: {}", brand)))?;

    match TouptekSdk::load(brand_info.0, brand_info.1) {
        Ok(sdk) => {
            map.insert(brand.to_string(), Ok(sdk));
            Ok(())
        }
        Err(e) => {
            let msg = e.to_string();
            map.insert(brand.to_string(), Err(msg.clone()));
            Err(NativeError::SdkError(msg))
        }
    }
}

pub(crate) fn with_sdk<F, R>(brand: &str, f: F) -> Result<R, NativeError>
where
    F: FnOnce(&TouptekSdk) -> Result<R, NativeError>,
{
    get_sdk_for_brand(brand)?;
    let sdks = get_sdks();
    let map = sdks.lock().unwrap_or_else(|e| e.into_inner());
    let sdk = map
        .get(brand)
        .unwrap()
        .as_ref()
        .map_err(|e| NativeError::SdkError(e.clone()))?;
    f(sdk)
}

pub(crate) fn open_touptek_device(
    sdk: &TouptekSdk,
    device_id: &str,
) -> Result<HOgmacam, NativeError> {
    if device_id.is_empty() {
        return Err(NativeError::SdkError(
            "Touptek SDK returned an empty stable device ID".to_string(),
        ));
    }

    #[cfg(windows)]
    {
        let wide_id: Vec<u16> = device_id.encode_utf16().chain(std::iter::once(0)).collect();
        // SAFETY: `wide_id` is a live, NUL-terminated UTF-16 string matching the Windows
        // Touptek-family Open(const wchar_t*) ABI. The SDK copies/consumes it during this call.
        Ok(unsafe { (sdk.open)(wide_id.as_ptr() as *const c_void) })
    }

    #[cfg(not(windows))]
    {
        let c_id = CString::new(device_id).map_err(|_| {
            NativeError::SdkError("Touptek device ID contains an interior NUL".to_string())
        })?;
        // SAFETY: `c_id` is a live, NUL-terminated C string matching the non-Windows
        // Touptek-family Open(const char*) ABI. The SDK copies/consumes it during this call.
        Ok(unsafe { (sdk.open)(c_id.as_ptr() as *const c_void) })
    }
}

pub(crate) fn touptek_static_cstr(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }

    // SAFETY: Touptek-family Version functions return static, NUL-terminated C strings
    // owned by the loaded SDK shared library.
    let value = unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .trim()
        .to_string();
    (!value.is_empty()).then_some(value)
}

pub(crate) fn sdk_version_from_sdk(sdk: &TouptekSdk, brand: &str) -> Option<String> {
    let version = sdk.version?;
    // SAFETY: <Prefix>_Version takes no arguments and returns a static C string.
    touptek_static_cstr(unsafe { version() }).map(|value| format!("{brand} SDK v{value}"))
}

pub(crate) fn touptek_temperature_result(
    camera_name: &str,
    sdk_result: i32,
    temperature_tenths_c: i16,
) -> Result<f64, NativeError> {
    if sdk_result >= 0 {
        Ok(temperature_tenths_c as f64 / 10.0)
    } else {
        tracing::error!(
            "Touptek get_Temperature() failed for camera '{}'. Error code: {}",
            camera_name,
            sdk_result
        );
        Err(NativeError::SdkError(format!(
            "Failed to read temperature from Touptek camera '{}'. SDK error: {}. Camera may not have a temperature sensor.",
            camera_name, sdk_result
        )))
    }
}

pub(crate) fn make_touptek_fourcc(code: [u8; 4]) -> u32 {
    (code[0] as u32) | ((code[1] as u32) << 8) | ((code[2] as u32) << 16) | ((code[3] as u32) << 24)
}

pub(crate) fn touptek_bayer_pattern_from_fourcc(fourcc: u32) -> Option<BayerPattern> {
    match fourcc {
        v if v == make_touptek_fourcc(*b"RGGB") => Some(BayerPattern::Rggb),
        v if v == make_touptek_fourcc(*b"GRBG") => Some(BayerPattern::Grbg),
        v if v == make_touptek_fourcc(*b"GBRG") => Some(BayerPattern::Gbrg),
        v if v == make_touptek_fourcc(*b"BGGR") => Some(BayerPattern::Bggr),
        _ => None,
    }
}

pub(crate) fn touptek_fourcc_to_string(fourcc: u32) -> String {
    let bytes = [
        (fourcc & 0xff) as u8,
        ((fourcc >> 8) & 0xff) as u8,
        ((fourcc >> 16) & 0xff) as u8,
        ((fourcc >> 24) & 0xff) as u8,
    ];
    String::from_utf8_lossy(&bytes).to_string()
}

/// Full-scale ADU of the delivered pixel container for a ToupTek-family camera.
///
/// **This vendor is right-justified**, which is why `(1 << bit_depth) - 1` is
/// correct here and must NOT be "fixed" the way ZWO/SVBony/Player One were. Do
/// not left-shift this into the 16-bit container.
///
/// Evidence:
///
/// * The SDK's own histogram is indexed by pixel value and sized
///   `1 << bitdepth` (`SDKs/Touptek/inc/ogmacam.h:616-624`,
///   `PIOGMACAM_HISTOGRAM_CALLBACKV2`). A 12-bit camera's histogram has 4096
///   bins, so delivered samples span 0..=4095; left-justified samples would
///   need 65536.
/// * Black level, a pedestal subtracted from the delivered data, is expressed
///   in native-bit-depth units rather than container units:
///   `OGMACAM_BLACKLEVEL8_MAX 31`, `..._12_MAX (31 * 16)`, `..._16_MAX (31 * 256)`
///   (`SDKs/Touptek/inc/ogmacam.h:217-222`); INDI's toupbase scales its offset
///   control the same way (`bLevelStep = 1 << (m_maxBitDepth - 8)`).
/// * Measured on an Orion G16 (ToupTek ATR3CMOS16000KPA, 12-bit) through the
///   INDI toupbase driver, which passes the SDK buffer through unshifted: pixel
///   values never exceed 4095
///   (<https://indilib.org/forum/ccds-dslrs/12316-touptek-14-and-12-bit-scaling-issues.html>).
///   The ×16 scaling lives in ToupTek's *ASCOM* layer, above the SDK this
///   driver uses.
///
/// `bit_depth` comes from `Ogmacam_get_RawFormat`, which reports the raw format's
/// own bits-per-pixel, so container and precision coincide for this vendor.
pub(crate) fn max_adu_from_bit_depth(bit_depth: u32) -> u32 {
    if bit_depth >= 32 {
        u32::MAX
    } else {
        (1u32 << bit_depth).saturating_sub(1)
    }
}

pub(crate) fn touptek_no_sdk_loaded_error(load_errors: &[(String, String, String)]) -> NativeError {
    let details = load_errors
        .iter()
        .map(|(brand, library, error)| format!("{brand} ({library}): {error}"))
        .collect::<Vec<_>>()
        .join("; ");

    NativeError::SdkError(format!(
        "No Touptek-family SDK libraries could be loaded. Install at least one supported SDK DLL/shared library or add it to the process library path. Tried: {details}"
    ))
}

pub(crate) fn read_touptek_raw_format(
    sdk: &TouptekSdk,
    handle: HOgmacam,
    camera_name: &str,
) -> (Option<BayerPattern>, Option<u32>) {
    let mut fourcc: c_uint = 0;
    let mut bits_per_pixel: c_uint = 0;
    // SAFETY: caller holds touptek_mutex and `handle` is the open camera handle.
    // The two out-pointers reference valid, distinct stack locals as required by
    // the ToupCam/Ogmacam SDK's get_RawFormat signature.
    let result = unsafe { (sdk.get_raw_format)(handle, &mut fourcc, &mut bits_per_pixel) };
    if result < 0 {
        tracing::warn!(
            "Touptek get_RawFormat() failed for camera '{}'. SDK error: {}",
            camera_name,
            result
        );
        return (None, None);
    }

    let pattern = touptek_bayer_pattern_from_fourcc(fourcc);
    if pattern.is_none() {
        tracing::warn!(
            "Touptek camera '{}' reported non-Bayer raw format '{}' ({} bpp); leaving Bayer pattern unknown",
            camera_name,
            touptek_fourcc_to_string(fourcc),
            bits_per_pixel
        );
    }
    let bit_depth = if bits_per_pixel > 0 {
        Some(bits_per_pixel)
    } else {
        None
    };
    (pattern, bit_depth)
}
