//! QHY SDK loading, discovery configuration and error mapping.

use super::*;

/// QHY SDK library wrapper
pub(crate) type GetQhyccdSdkVersion =
    unsafe extern "C" fn(*mut c_uint, *mut c_uint, *mut c_uint, *mut c_uint) -> c_uint;

pub(crate) struct QhySdk {
    #[allow(dead_code)]
    pub(crate) lib: libloading::Library,

    // Function pointers - Core
    pub(crate) init_sdk: unsafe extern "C" fn() -> c_uint,
    pub(crate) release_sdk: unsafe extern "C" fn() -> c_uint,
    pub(crate) scan_qhyccd: unsafe extern "C" fn() -> c_uint,
    pub(crate) get_qhyccd_id: unsafe extern "C" fn(c_uint, *mut c_char) -> c_uint,
    pub(crate) open_qhyccd: unsafe extern "C" fn(*const c_char) -> QhyCamHandle,
    pub(crate) close_qhyccd: unsafe extern "C" fn(QhyCamHandle) -> c_uint,

    // Camera initialization
    pub(crate) set_qhyccd_stream_mode: unsafe extern "C" fn(QhyCamHandle, c_uint) -> c_uint,
    pub(crate) init_qhyccd: unsafe extern "C" fn(QhyCamHandle) -> c_uint,

    // Camera info
    pub(crate) get_qhyccd_chip_info: unsafe extern "C" fn(
        QhyCamHandle,
        *mut c_double,
        *mut c_double, // chip_w, chip_h
        *mut c_uint,
        *mut c_uint, // image_w, image_h
        *mut c_double,
        *mut c_double, // pixel_w, pixel_h
        *mut c_uint,   // bpp
    ) -> c_uint,
    pub(crate) is_qhyccd_control_available: unsafe extern "C" fn(QhyCamHandle, c_int) -> c_uint,
    pub(crate) get_qhyccd_effective_area: unsafe extern "C" fn(
        QhyCamHandle,
        *mut c_uint,
        *mut c_uint,
        *mut c_uint,
        *mut c_uint,
    ) -> c_uint,

    // Camera control
    pub(crate) set_qhyccd_param: unsafe extern "C" fn(QhyCamHandle, c_int, c_double) -> c_uint,
    pub(crate) get_qhyccd_param: unsafe extern "C" fn(QhyCamHandle, c_int) -> c_double,
    pub(crate) get_qhyccd_param_min_max_step: unsafe extern "C" fn(
        QhyCamHandle,
        c_int,
        *mut c_double,
        *mut c_double,
        *mut c_double,
    ) -> c_uint,
    pub(crate) set_qhyccd_resolution:
        unsafe extern "C" fn(QhyCamHandle, c_uint, c_uint, c_uint, c_uint) -> c_uint,
    pub(crate) set_qhyccd_binmode: unsafe extern "C" fn(QhyCamHandle, c_uint, c_uint) -> c_uint,
    pub(crate) set_qhyccd_bits_mode: unsafe extern "C" fn(QhyCamHandle, c_uint) -> c_uint,

    // Exposure control
    pub(crate) exp_single_frame: unsafe extern "C" fn(QhyCamHandle) -> c_uint,
    pub(crate) get_qhyccd_single_frame: unsafe extern "C" fn(
        QhyCamHandle,
        *mut c_uint,
        *mut c_uint,
        *mut c_uint,
        *mut c_uint,
        *mut u8,
    ) -> c_uint,
    pub(crate) cancel_qhyccd_exposing_and_readout: unsafe extern "C" fn(QhyCamHandle) -> c_uint,
    pub(crate) get_qhyccd_memory_length: unsafe extern "C" fn(QhyCamHandle) -> c_uint,

    // Readout modes
    pub(crate) get_qhyccd_read_mode_name:
        unsafe extern "C" fn(QhyCamHandle, c_uint, *mut c_char) -> c_uint,
    pub(crate) get_qhyccd_number_of_read_modes:
        unsafe extern "C" fn(QhyCamHandle, *mut c_uint) -> c_uint,
    pub(crate) set_qhyccd_read_mode: unsafe extern "C" fn(QhyCamHandle, c_uint) -> c_uint,
    pub(crate) get_qhyccd_read_mode: unsafe extern "C" fn(QhyCamHandle, *mut c_uint) -> c_uint,

    // Color Filter Wheel (CFW) control
    pub(crate) is_qhyccd_cfw_plugged: unsafe extern "C" fn(QhyCamHandle) -> c_uint,

    // SDK metadata. Older QHY SDK builds may not export this, so keep it optional.
    pub(crate) get_sdk_version: Option<GetQhyccdSdkVersion>,
}

// SAFETY: QhySdk holds a libloading::Library plus function pointers. The Library is OS-loaded
// memory pinned for the program lifetime (stored in OnceLock); function pointers are POD. All
// FFI calls go through `qhy_mutex()` so the underlying SDK never sees concurrent traffic.
unsafe impl Send for QhySdk {}
// SAFETY: Same justification as `Send` — every FFI call site holds `qhy_mutex()`, so shared
// references to the function-pointer table cannot trigger concurrent SDK access.
unsafe impl Sync for QhySdk {}

pub(crate) static QHY_SDK: OnceLock<Option<QhySdk>> = OnceLock::new();
pub(crate) static SDK_INITIALIZED: OnceLock<bool> = OnceLock::new();

pub(crate) const QHY_VENDOR_NAME: &str = "QHY Camera";

// Discovery configuration

/// Global flag to enable/disable QHY discovery.
///
/// QHY discovery can be disabled if it causes crashes or hangs on a particular system.
/// Default is `true` (enabled).
pub(crate) static QHY_DISCOVERY_ENABLED: AtomicBool = AtomicBool::new(true);

/// Default timeout for QHY discovery operations in milliseconds.
/// This can be overridden by the quirks database.
pub(crate) const DEFAULT_DISCOVERY_TIMEOUT_MS: u64 = 10000;

/// Configuration for QHY discovery safety measures
#[derive(Debug, Clone)]
pub struct QhyDiscoveryConfig {
    /// Whether discovery is enabled
    pub enabled: bool,
    /// Timeout for discovery operations in milliseconds
    pub timeout_ms: u64,
    /// Whether to use catch_unwind for crash protection
    pub catch_panics: bool,
}

impl Default for QhyDiscoveryConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            timeout_ms: DEFAULT_DISCOVERY_TIMEOUT_MS,
            catch_panics: true,
        }
    }
}

/// Check if QHY discovery is enabled.
pub fn is_qhy_discovery_enabled() -> bool {
    QHY_DISCOVERY_ENABLED.load(Ordering::SeqCst)
}

/// Enable or disable QHY discovery. While disabled, `discover_devices()` returns
/// an empty list without scanning, which is the escape hatch for hosts where the
/// QHY SDK crashes or hangs during enumeration.
pub fn set_qhy_discovery_enabled(enabled: bool) {
    let previous = QHY_DISCOVERY_ENABLED.swap(enabled, Ordering::SeqCst);
    if previous != enabled {
        tracing::info!(
            "QHY discovery {} -> {}",
            if previous { "enabled" } else { "disabled" },
            if enabled { "enabled" } else { "disabled" }
        );
    }
}

/// Get the current QHY discovery configuration, including quirks from the database.
pub(crate) fn get_discovery_config() -> QhyDiscoveryConfig {
    let mut timeout_ms = DEFAULT_DISCOVERY_TIMEOUT_MS;

    // Check quirks database for QHY-specific discovery settings
    let vendor_quirks = crate::quirks::get_quirks_for_vendor(&crate::NativeVendor::Qhy);
    for quirk in vendor_quirks {
        if let crate::quirks::Quirk::Discovery(crate::quirks::DiscoveryQuirk::DiscoveryTimeoutMs(
            timeout,
        )) = quirk
        {
            timeout_ms = timeout;
        }
    }

    QhyDiscoveryConfig {
        enabled: is_qhy_discovery_enabled(),
        timeout_ms,
        catch_panics: true,
    }
}

pub(crate) fn qhy_candidate_library_paths() -> Vec<PathBuf> {
    if cfg!(target_os = "windows") {
        vec![
            PathBuf::from("qhyccd.dll"),
            PathBuf::from("C:\\Program Files\\QHYCCD\\AllInOne\\sdk\\x64\\qhyccd.dll"),
            PathBuf::from("C:\\Program Files (x86)\\QHYCCD\\AllInOne\\sdk\\qhyccd.dll"),
        ]
    } else if cfg!(target_os = "macos") {
        vec![
            PathBuf::from("libqhyccd.dylib"),
            PathBuf::from("/usr/local/lib/libqhyccd.dylib"),
            PathBuf::from("/Library/Frameworks/QHYCCD.framework/QHYCCD"),
        ]
    } else {
        crate::vendor::sdk_loader::vendor_library_candidates(
            &["libqhyccd.so", "libqhyccd.so.21"],
            &["/usr/lib/libqhyccd.so", "/usr/local/lib/libqhyccd.so"],
        )
    }
}

pub(crate) unsafe fn resolve_qhy_symbol<T: Copy>(
    library: &libloading::Library,
    library_path: &Path,
    symbol_name_with_nul: &'static [u8],
    symbol_name_for_log: &'static str,
) -> Result<T, crate::vendor::sdk_loader::VendorLoadError> {
    crate::vendor::sdk_loader::resolve_symbol::<T>(
        QHY_VENDOR_NAME,
        library,
        library_path,
        symbol_name_with_nul,
        symbol_name_for_log,
    )
}

pub(crate) fn load_qhy_sdk() -> Option<QhySdk> {
    let candidate_paths = qhy_candidate_library_paths();
    let (lib, library_path) =
        match crate::vendor::sdk_loader::open_vendor_library(QHY_VENDOR_NAME, &candidate_paths) {
            Ok(pair) => pair,
            Err(e) => {
                tracing::debug!("{}: SDK unavailable: {}", QHY_VENDOR_NAME, e);
                return None;
            }
        };

    // SAFETY: each FFI signature below mirrors qhyccd.h for the named symbol.
    // The `lib` handle is stored in QhySdk so resolved function pointers cannot
    // outlive the library that owns them.
    let sdk = unsafe {
        (|| -> Result<QhySdk, crate::vendor::sdk_loader::VendorLoadError> {
            Ok(QhySdk {
                init_sdk: resolve_qhy_symbol(
                    &lib,
                    &library_path,
                    b"InitQHYCCDResource\0",
                    "InitQHYCCDResource",
                )?,
                release_sdk: resolve_qhy_symbol(
                    &lib,
                    &library_path,
                    b"ReleaseQHYCCDResource\0",
                    "ReleaseQHYCCDResource",
                )?,
                scan_qhyccd: resolve_qhy_symbol(
                    &lib,
                    &library_path,
                    b"ScanQHYCCD\0",
                    "ScanQHYCCD",
                )?,
                get_qhyccd_id: resolve_qhy_symbol(
                    &lib,
                    &library_path,
                    b"GetQHYCCDId\0",
                    "GetQHYCCDId",
                )?,
                open_qhyccd: resolve_qhy_symbol(
                    &lib,
                    &library_path,
                    b"OpenQHYCCD\0",
                    "OpenQHYCCD",
                )?,
                close_qhyccd: resolve_qhy_symbol(
                    &lib,
                    &library_path,
                    b"CloseQHYCCD\0",
                    "CloseQHYCCD",
                )?,
                set_qhyccd_stream_mode: resolve_qhy_symbol(
                    &lib,
                    &library_path,
                    b"SetQHYCCDStreamMode\0",
                    "SetQHYCCDStreamMode",
                )?,
                init_qhyccd: resolve_qhy_symbol(
                    &lib,
                    &library_path,
                    b"InitQHYCCD\0",
                    "InitQHYCCD",
                )?,
                get_qhyccd_chip_info: resolve_qhy_symbol(
                    &lib,
                    &library_path,
                    b"GetQHYCCDChipInfo\0",
                    "GetQHYCCDChipInfo",
                )?,
                is_qhyccd_control_available: resolve_qhy_symbol(
                    &lib,
                    &library_path,
                    b"IsQHYCCDControlAvailable\0",
                    "IsQHYCCDControlAvailable",
                )?,
                get_qhyccd_effective_area: resolve_qhy_symbol(
                    &lib,
                    &library_path,
                    b"GetQHYCCDEffectiveArea\0",
                    "GetQHYCCDEffectiveArea",
                )?,
                set_qhyccd_param: resolve_qhy_symbol(
                    &lib,
                    &library_path,
                    b"SetQHYCCDParam\0",
                    "SetQHYCCDParam",
                )?,
                get_qhyccd_param: resolve_qhy_symbol(
                    &lib,
                    &library_path,
                    b"GetQHYCCDParam\0",
                    "GetQHYCCDParam",
                )?,
                get_qhyccd_param_min_max_step: resolve_qhy_symbol(
                    &lib,
                    &library_path,
                    b"GetQHYCCDParamMinMaxStep\0",
                    "GetQHYCCDParamMinMaxStep",
                )?,
                set_qhyccd_resolution: resolve_qhy_symbol(
                    &lib,
                    &library_path,
                    b"SetQHYCCDResolution\0",
                    "SetQHYCCDResolution",
                )?,
                set_qhyccd_binmode: resolve_qhy_symbol(
                    &lib,
                    &library_path,
                    b"SetQHYCCDBinMode\0",
                    "SetQHYCCDBinMode",
                )?,
                set_qhyccd_bits_mode: resolve_qhy_symbol(
                    &lib,
                    &library_path,
                    b"SetQHYCCDBitsMode\0",
                    "SetQHYCCDBitsMode",
                )?,
                exp_single_frame: resolve_qhy_symbol(
                    &lib,
                    &library_path,
                    b"ExpQHYCCDSingleFrame\0",
                    "ExpQHYCCDSingleFrame",
                )?,
                get_qhyccd_single_frame: resolve_qhy_symbol(
                    &lib,
                    &library_path,
                    b"GetQHYCCDSingleFrame\0",
                    "GetQHYCCDSingleFrame",
                )?,
                cancel_qhyccd_exposing_and_readout: resolve_qhy_symbol(
                    &lib,
                    &library_path,
                    b"CancelQHYCCDExposingAndReadout\0",
                    "CancelQHYCCDExposingAndReadout",
                )?,
                get_qhyccd_memory_length: resolve_qhy_symbol(
                    &lib,
                    &library_path,
                    b"GetQHYCCDMemLength\0",
                    "GetQHYCCDMemLength",
                )?,
                get_qhyccd_read_mode_name: resolve_qhy_symbol(
                    &lib,
                    &library_path,
                    b"GetQHYCCDReadModeName\0",
                    "GetQHYCCDReadModeName",
                )?,
                get_qhyccd_number_of_read_modes: resolve_qhy_symbol(
                    &lib,
                    &library_path,
                    b"GetQHYCCDNumberOfReadModes\0",
                    "GetQHYCCDNumberOfReadModes",
                )?,
                set_qhyccd_read_mode: resolve_qhy_symbol(
                    &lib,
                    &library_path,
                    b"SetQHYCCDReadMode\0",
                    "SetQHYCCDReadMode",
                )?,
                get_qhyccd_read_mode: resolve_qhy_symbol(
                    &lib,
                    &library_path,
                    b"GetQHYCCDReadMode\0",
                    "GetQHYCCDReadMode",
                )?,
                is_qhyccd_cfw_plugged: resolve_qhy_symbol(
                    &lib,
                    &library_path,
                    b"IsQHYCCDCFWPlugged\0",
                    "IsQHYCCDCFWPlugged",
                )?,
                get_sdk_version: match lib.get::<GetQhyccdSdkVersion>(b"GetQHYCCDSDKVersion\0") {
                    Ok(symbol) => Some(*symbol),
                    Err(error) => {
                        tracing::debug!(
                            "{}: optional symbol GetQHYCCDSDKVersion unavailable in {}: {}",
                            QHY_VENDOR_NAME,
                            library_path.display(),
                            error
                        );
                        None
                    }
                },
                lib,
            })
        })()
    };

    match sdk {
        Ok(sdk) => {
            tracing::info!("{}: all required symbols resolved", QHY_VENDOR_NAME);
            Some(sdk)
        }
        Err(e) => {
            tracing::error!(
                "{}: SDK present but symbol resolution failed: {}",
                QHY_VENDOR_NAME,
                e
            );
            None
        }
    }
}

impl QhySdk {
    /// Load the QHY SDK library
    pub(crate) fn load() -> Option<Self> {
        load_qhy_sdk()
    }

    /// Get the global SDK instance
    pub(crate) fn get() -> Option<&'static QhySdk> {
        QHY_SDK.get_or_init(Self::load).as_ref()
    }

    /// Initialize the SDK (must be called once before use)
    pub(crate) fn ensure_initialized() -> Result<(), NativeError> {
        if *SDK_INITIALIZED.get_or_init(|| {
            if let Some(sdk) = Self::get() {
                // SAFETY: InitQHYCCDResource takes no arguments and returns a c_uint status.
                // OnceLock::get_or_init guarantees this initializer runs at most once globally,
                // so no concurrent SDK access can occur during initialization.
                let result = unsafe { (sdk.init_sdk)() };
                if result == 0 {
                    // QHYCCD_SUCCESS
                    tracing::info!("QHY SDK initialized successfully");
                    true
                } else {
                    tracing::error!("Failed to initialize QHY SDK: error {}", result);
                    false
                }
            } else {
                false
            }
        }) {
            Ok(())
        } else {
            Err(NativeError::SdkNotLoaded)
        }
    }
}

pub(crate) fn sdk_version_from_sdk(sdk: &QhySdk) -> Option<String> {
    let get_sdk_version = sdk.get_sdk_version?;
    let mut year = 0;
    let mut month = 0;
    let mut day = 0;
    let mut subday = 0;

    // SAFETY: GetQHYCCDSDKVersion takes four valid c_uint out-pointers and writes SDK
    // version components. It has no device-handle dependency.
    let result = unsafe { get_sdk_version(&mut year, &mut month, &mut day, &mut subday) };
    if result == 0 && year > 0 {
        Some(format!("QHY SDK v{year}.{month:02}.{day:02}.{subday}"))
    } else {
        tracing::debug!(
            "QHY SDK version query failed or returned an invalid version: result={}, year={}, month={}, day={}, subday={}",
            result,
            year,
            month,
            day,
            subday
        );
        None
    }
}

/// QHY SDK error codes (from qhyccdstruct.h)
/// These error codes are returned by QHYCCD SDK functions.
#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(dead_code)]
pub(crate) enum QhyError {
    Success = 0,
    Error = 0xFFFFFFFF,
    ReadDirectly = 0x2001,
    ReadOpenMem = 0x2002,
    ReadError = 0x2003,
    InitResource = 0x0001,
    ReleaseResource = 0x0002,
    InitCamera = 0x0003,
    CloseCamera = 0x0004,
    InitClass = 0x0005,
    SetFWError = 0x0006,
    SetHDR = 0x0007,
    GetMemLength = 0x0008,
}

/// Full-scale ADU of the delivered pixel container for a QHY camera.
///
/// QHY splits this into two separate SDK queries:
///
/// * `GetQHYCCDChipInfo`'s `bpp` is the **container** depth (8 or 16). The SDK
///   manual calls it "Image data bit depth", and it is what
///   `SetQHYCCDBitsMode`/`CONTROL_TRANSFERBIT` set.
/// * `GetQHYCCDParam(OutputDataActualBits)` is the **ADC precision** — "the
///   actual number of bits of raw data output by the chip" (SDK manual §21).
///
/// The manual is explicit that sub-16-bit ADCs are left-justified into the
/// 16-bit container. §14 ("Set digit and image data format"):
///
/// > Note that the output image data of digits and the original data bits may
/// > not be consistent, such as camera raw data for the 12, then if set camera
/// > output 16-bit data, inside the camera can be in the original data of low
/// > zero padding, converted to 16 bits of data
///
/// and §21 again: "the 16-bit image data can be obtained by adding the low zero
/// position". Zero-padding the *low* bits means the ADC bits sit high, so a
/// 12-bit QHY in 16-bit transfer mode reaches `4095 << 4 = 65520`, not 4095.
/// §22 exposes the same fact at runtime: "Get the alignment format of the camera
/// output data. If the return value is 1, it indicates high alignment; if the
/// return value is 0, it indicates low alignment." (QHYCCD SDK API manual v2.6,
/// `QHYCCD SDK API MENU_EN.pdf`.) An independent user report of a ToupTek camera
/// asks for "scaled 16 bit FITS files like you have with ZWO or QHY cameras"
/// — <https://indilib.org/forum/ccds-dslrs/12316>.
///
/// `container_bits < 16` (the 8-bit transfer mode) is a genuine byte container:
/// the SDK takes the high bits, so the ceiling is 255 regardless of the ADC.
/// Unknown `actual_bits`, or an ADC at least as wide as the container, take the
/// container's own ceiling rather than underflowing to 0, which would report
/// "this camera cannot produce any signal". A `container_bits` outside 1..=16 is
/// an unpopulated SDK field, not a 1-bit sensor, and falls back to 16 for the
/// same reason.
pub(crate) fn container_max_adu(
    container_bits: u32,
    actual_bits: Option<u32>,
    high_aligned: bool,
) -> u32 {
    let container_bits = if (1..=16).contains(&container_bits) {
        container_bits
    } else {
        16
    };
    let container_max = (1u32 << container_bits) - 1;
    let Some(actual_bits) = actual_bits.filter(|bits| (1..container_bits).contains(bits)) else {
        return container_max;
    };
    if high_aligned {
        ((1u32 << actual_bits) - 1) << (container_bits - actual_bits)
    } else {
        (1u32 << actual_bits) - 1
    }
}

/// Check QHY error and convert to NativeError with detailed error mapping
pub(crate) fn check_qhy_error(code: c_uint, operation: &str) -> Result<(), NativeError> {
    match code {
        0 => Ok(()), // QHYCCD_SUCCESS

        // Initialization errors
        0x0001 => Err(NativeError::SdkError(format!(
            "{}: Failed to initialize QHYCCD resources - SDK may not be properly installed",
            operation
        ))),
        0x0002 => Err(NativeError::SdkError(format!(
            "{}: Failed to release QHYCCD resources",
            operation
        ))),
        0x0003 => Err(NativeError::SdkError(format!(
            "{}: Failed to initialize camera - check USB connection",
            operation
        ))),
        0x0004 => Err(NativeError::Disconnected),
        0x0005 => Err(NativeError::SdkError(format!(
            "{}: Failed to initialize camera class",
            operation
        ))),
        0x0006 => Err(NativeError::SdkError(format!(
            "{}: Filter wheel operation failed",
            operation
        ))),
        0x0007 => Err(NativeError::SdkError(format!(
            "{}: HDR mode setting failed",
            operation
        ))),
        0x0008 => Err(NativeError::SdkError(format!(
            "{}: Failed to get memory length for image buffer",
            operation
        ))),

        // Read errors
        0x2001 => Err(NativeError::SdkError(format!(
            "{}: Direct read failed",
            operation
        ))),
        0x2002 => Err(NativeError::SdkError(format!(
            "{}: Memory open read failed",
            operation
        ))),
        0x2003 => Err(NativeError::SdkError(format!(
            "{}: Read operation failed - check USB connection",
            operation
        ))),

        // Timeout (common error)
        11 => Err(NativeError::Timeout(format!(
            "{}: Operation timed out - exposure may be in progress or camera unresponsive",
            operation
        ))),

        // Generic error (0xFFFFFFFF)
        0xFFFFFFFF => Err(NativeError::SdkError(format!(
            "{}: General error - camera may be in use by another application or disconnected",
            operation
        ))),

        // Unknown error
        _ => Err(NativeError::SdkError(format!(
            "{}: Unknown QHY error code 0x{:X}",
            operation, code
        ))),
    }
}
