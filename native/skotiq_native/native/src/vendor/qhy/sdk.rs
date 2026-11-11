//! QHY SDK loading, discovery configuration and error mapping.

use super::*;

pub(crate) type GetQhyccdSdkVersion =
    unsafe extern "C" fn(*mut c_uint, *mut c_uint, *mut c_uint, *mut c_uint) -> c_uint;

crate::load_vendor_sdk! {
    /// QHY camera SDK function table (qhyccd.dll / libqhyccd). The filter wheel
    /// is driven through the same library and therefore the same lock.
    vendor_name: QHY_VENDOR_NAME,
    sdk_struct: QhySdk,
    sdk_static: QHY_SDK,
    candidate_paths_fn: qhy_candidate_library_paths,
    symbols: {
        init_sdk: b"InitQHYCCDResource\0"
            => unsafe extern "C" fn() -> c_uint,
        release_sdk: b"ReleaseQHYCCDResource\0"
            => unsafe extern "C" fn() -> c_uint,
        scan_qhyccd: b"ScanQHYCCD\0"
            => unsafe extern "C" fn() -> c_uint,
        get_qhyccd_id: b"GetQHYCCDId\0"
            => unsafe extern "C" fn(c_uint, *mut c_char) -> c_uint,
        open_qhyccd: b"OpenQHYCCD\0"
            => unsafe extern "C" fn(*const c_char) -> QhyCamHandle,
        close_qhyccd: b"CloseQHYCCD\0"
            => unsafe extern "C" fn(QhyCamHandle) -> c_uint,
        set_qhyccd_stream_mode: b"SetQHYCCDStreamMode\0"
            => unsafe extern "C" fn(QhyCamHandle, c_uint) -> c_uint,
        init_qhyccd: b"InitQHYCCD\0"
            => unsafe extern "C" fn(QhyCamHandle) -> c_uint,
        get_qhyccd_chip_info: b"GetQHYCCDChipInfo\0"
            => unsafe extern "C" fn(QhyCamHandle, *mut c_double, *mut c_double, *mut c_uint, *mut c_uint, *mut c_double, *mut c_double, *mut c_uint) -> c_uint,
        is_qhyccd_control_available: b"IsQHYCCDControlAvailable\0"
            => unsafe extern "C" fn(QhyCamHandle, c_int) -> c_uint,
        get_qhyccd_effective_area: b"GetQHYCCDEffectiveArea\0"
            => unsafe extern "C" fn(QhyCamHandle, *mut c_uint, *mut c_uint, *mut c_uint, *mut c_uint) -> c_uint,
        set_qhyccd_param: b"SetQHYCCDParam\0"
            => unsafe extern "C" fn(QhyCamHandle, c_int, c_double) -> c_uint,
        get_qhyccd_param: b"GetQHYCCDParam\0"
            => unsafe extern "C" fn(QhyCamHandle, c_int) -> c_double,
        get_qhyccd_param_min_max_step: b"GetQHYCCDParamMinMaxStep\0"
            => unsafe extern "C" fn(QhyCamHandle, c_int, *mut c_double, *mut c_double, *mut c_double) -> c_uint,
        set_qhyccd_resolution: b"SetQHYCCDResolution\0"
            => unsafe extern "C" fn(QhyCamHandle, c_uint, c_uint, c_uint, c_uint) -> c_uint,
        set_qhyccd_binmode: b"SetQHYCCDBinMode\0"
            => unsafe extern "C" fn(QhyCamHandle, c_uint, c_uint) -> c_uint,
        set_qhyccd_bits_mode: b"SetQHYCCDBitsMode\0"
            => unsafe extern "C" fn(QhyCamHandle, c_uint) -> c_uint,
        exp_single_frame: b"ExpQHYCCDSingleFrame\0"
            => unsafe extern "C" fn(QhyCamHandle) -> c_uint,
        get_qhyccd_single_frame: b"GetQHYCCDSingleFrame\0"
            => unsafe extern "C" fn(QhyCamHandle, *mut c_uint, *mut c_uint, *mut c_uint, *mut c_uint, *mut u8) -> c_uint,
        cancel_qhyccd_exposing_and_readout: b"CancelQHYCCDExposingAndReadout\0"
            => unsafe extern "C" fn(QhyCamHandle) -> c_uint,
        get_qhyccd_memory_length: b"GetQHYCCDMemLength\0"
            => unsafe extern "C" fn(QhyCamHandle) -> c_uint,
        get_qhyccd_read_mode_name: b"GetQHYCCDReadModeName\0"
            => unsafe extern "C" fn(QhyCamHandle, c_uint, *mut c_char) -> c_uint,
        get_qhyccd_number_of_read_modes: b"GetQHYCCDNumberOfReadModes\0"
            => unsafe extern "C" fn(QhyCamHandle, *mut c_uint) -> c_uint,
        set_qhyccd_read_mode: b"SetQHYCCDReadMode\0"
            => unsafe extern "C" fn(QhyCamHandle, c_uint) -> c_uint,
        get_qhyccd_read_mode: b"GetQHYCCDReadMode\0"
            => unsafe extern "C" fn(QhyCamHandle, *mut c_uint) -> c_uint,
        is_qhyccd_cfw_plugged: b"IsQHYCCDCFWPlugged\0"
            => unsafe extern "C" fn(QhyCamHandle) -> c_uint,
    },
    optional_symbols: {
        // Older QHY SDK builds do not export this.
        get_sdk_version: b"GetQHYCCDSDKVersion\0" => GetQhyccdSdkVersion,
    }
}

/// Result of the one-time `InitQHYCCDResource` call (the SDK's return code).
pub(crate) static SDK_INITIALIZED: OnceLock<c_uint> = OnceLock::new();

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

impl QhySdk {
    /// Initialize the SDK (once per process) before its first use.
    ///
    /// A library that is not installed reports `SdkNotInstalled`; a library
    /// that loads but whose `InitQHYCCDResource` fails reports `SdkError`, so
    /// a broken install keeps warning instead of looking absent.
    pub(crate) fn ensure_initialized() -> Result<(), NativeError> {
        let sdk = Self::installed()?;
        let result = *SDK_INITIALIZED.get_or_init(|| {
            // Unlocked on purpose: every caller runs this before it takes the
            // SDK lock, `OnceLock` lets exactly one caller through, and no
            // other QHY call can be in flight because every path into the SDK
            // starts here.
            // SAFETY: InitQHYCCDResource takes no arguments and returns a c_uint status.
            let result = unsafe { (sdk.unlocked().init_sdk)() };
            if result == 0 {
                // QHYCCD_SUCCESS
                tracing::info!("QHY SDK initialized successfully");
            } else {
                tracing::error!("Failed to initialize QHY SDK: error {}", result);
            }
            result
        });
        if result == 0 {
            Ok(())
        } else {
            Err(NativeError::SdkError(format!(
                "QHY SDK failed to initialize: InitQHYCCDResource returned error {}",
                result
            )))
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
