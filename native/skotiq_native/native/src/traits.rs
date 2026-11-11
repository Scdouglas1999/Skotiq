//! Native Driver Traits
//!
//! Defines the common interface that all native drivers must implement.
//! This is similar to NINA's ICameraDevice, IMountDevice, etc. interfaces.

use crate::camera::*;
use async_trait::async_trait;
use std::fmt::Debug;

/// Common interface for all native devices
#[async_trait]
pub trait NativeDevice: Send + Sync + Debug {
    /// Get the unique device ID
    fn id(&self) -> &str;

    /// Get the device name/model
    fn name(&self) -> &str;

    /// Get the vendor name
    fn vendor(&self) -> crate::NativeVendor;

    /// Hardware serial number, when the vendor SDK exposes one for THIS unit.
    ///
    /// This is the only thing a vendor SDK offers that survives a replug: every
    /// `native:{vendor}:{n}` id is an enumeration index, so `n` re-binds to a
    /// different physical device whenever USB re-orders. A serial is what lets
    /// the app notice that.
    ///
    /// Defaults to `None`, and returning `None` is a legitimate answer — plenty
    /// of hardware genuinely has no readable serial (the ASI1600MM-Cool on the
    /// reference rig answers `ASI_ERROR_GENERAL_ERROR` to `ASIGetSerialNumber`
    /// while the ASI178MM beside it returns one). Callers must therefore treat
    /// a serial as a bonus discriminator and fall back to the model/geometry
    /// fingerprint. Never synthesise a stand-in value here: a fabricated serial
    /// is worse than an absent one, because identity checks trust it.
    fn serial_number(&self) -> Option<String> {
        None
    }

    /// Check if the device is connected
    fn is_connected(&self) -> bool;

    /// Connect to the device
    async fn connect(&mut self) -> Result<(), NativeError>;

    /// Disconnect from the device
    async fn disconnect(&mut self) -> Result<(), NativeError>;
}

/// Native camera device interface
///
/// This trait provides all camera operations that native drivers must implement.
/// Similar to NINA's ICameraDevice interface.
#[async_trait]
pub trait NativeCamera: NativeDevice {
    /// Get camera capabilities
    fn capabilities(&self) -> CameraCapabilities;

    /// Get current camera status
    async fn get_status(&self) -> Result<CameraStatus, NativeError>;

    /// Start an exposure
    async fn start_exposure(&mut self, params: ExposureParams) -> Result<(), NativeError>;

    /// Abort current exposure
    async fn abort_exposure(&mut self) -> Result<(), NativeError>;

    /// Check if exposure is complete
    async fn is_exposure_complete(&self) -> Result<bool, NativeError>;

    /// Download the image data from the camera
    async fn download_image(&mut self) -> Result<ImageData, NativeError>;

    /// Set cooler state and, optionally, the target temperature.
    ///
    /// `target_temp == None` means *the caller did not name a setpoint* —
    /// implementations must leave the driver's existing setpoint alone rather
    /// than substituting one. Turning a cooler off needs no setpoint at all, and
    /// inventing one both pushes a temperature the operator never asked for and
    /// fails outright on cameras that reject a set-temperature write.
    async fn set_cooler(
        &mut self,
        enabled: bool,
        target_temp: Option<f64>,
    ) -> Result<(), NativeError>;

    /// Get current sensor temperature
    async fn get_temperature(&self) -> Result<f64, NativeError>;

    /// Get cooler power percentage
    async fn get_cooler_power(&self) -> Result<f64, NativeError>;

    /// Set gain
    async fn set_gain(&mut self, gain: i32) -> Result<(), NativeError>;

    /// Get current gain
    async fn get_gain(&self) -> Result<i32, NativeError>;

    /// Set offset
    async fn set_offset(&mut self, offset: i32) -> Result<(), NativeError>;

    /// Get current offset
    async fn get_offset(&self) -> Result<i32, NativeError>;

    /// Set binning
    async fn set_binning(&mut self, bin_x: i32, bin_y: i32) -> Result<(), NativeError>;

    /// Get current binning
    async fn get_binning(&self) -> Result<(i32, i32), NativeError>;

    /// Set subframe region
    async fn set_subframe(&mut self, subframe: Option<SubFrame>) -> Result<(), NativeError>;

    /// Get sensor information
    fn get_sensor_info(&self) -> SensorInfo;

    /// Get available readout modes (vendor-specific)
    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, NativeError>;

    /// Set readout mode (vendor-specific)
    async fn set_readout_mode(&mut self, mode: &ReadoutMode) -> Result<(), NativeError>;

    /// Get vendor-specific features (e.g., QHY sensor chamber readings)
    async fn get_vendor_features(&self) -> Result<VendorFeatures, NativeError>;

    /// Get the valid range for gain setting.
    ///
    /// Returns (min_gain, max_gain) tuple.
    /// If the camera does not support gain adjustment, returns Err(NotSupported).
    async fn get_gain_range(&self) -> Result<(i32, i32), NativeError>;

    /// Get the valid range for offset/black level setting.
    ///
    /// Returns (min_offset, max_offset) tuple.
    /// If the camera does not support offset adjustment, returns Err(NotSupported).
    async fn get_offset_range(&self) -> Result<(i32, i32), NativeError>;

    /// Query the camera SDK for manufacturer-recommended gain/offset values.
    ///
    /// Returns a [`CameraRecommendedSettings`] populated with whatever the
    /// vendor SDK actually exposes:
    /// - `unity_gain`: gain value where the sensor reads 1 e-/ADU, if the SDK
    ///   reports it (ZWO publishes the default gain control caps, QHY exposes
    ///   `DefaultGain` as a dedicated control ID, SVBony provides control
    ///   default values).
    /// - `hcg_gain`: high-conversion-gain transition point, if exposed.
    /// - `default_offset`: manufacturer-recommended offset.
    ///
    /// The default implementation returns an empty
    /// [`CameraRecommendedSettings`] (all fields `None`) — this is the honest
    /// answer for vendors whose SDK does not expose these values. Drivers that
    /// CAN query them override this method.
    ///
    /// # Errors
    ///
    /// Returns `Err` only when the SDK call genuinely failed (e.g. camera
    /// disconnected mid-query). A camera that doesn't expose any recommended
    /// settings should return `Ok` with an empty struct — never fabricate a
    /// value.
    async fn get_recommended_settings(
        &self,
    ) -> Result<crate::camera::CameraRecommendedSettings, NativeError> {
        Ok(crate::camera::CameraRecommendedSettings::default())
    }

    /// Query the regulated-cooling temperature range the sensor's TEC can
    /// achieve, as `(min_temp_c, max_temp_c)`.
    ///
    /// `Ok(Some((min, max)))` only when the vendor SDK publishes the achievable
    /// setpoint range — ZWO exposes the `ASI_TARGET_TEMP` control's min/max caps
    /// and overrides this default. `Ok(None)` for the many cameras that report
    /// cooling support but no achievable range, so the UI shows the setpoint
    /// field unclamped. `Err` is reserved for a genuine SDK failure such as a
    /// disconnect mid-query.
    async fn get_cooler_temp_range(&self) -> Result<Option<(f64, f64)>, NativeError> {
        Ok(None)
    }

    /// Shortest and longest exposure the sensor accepts, in SECONDS.
    ///
    /// Same contract as [`Self::get_cooler_temp_range`]: `Ok(None)` when the
    /// driver does not publish a range, `Err` only on a genuine SDK failure. The
    /// ZWO SDK reports it via `ASIGetControlCaps` for `ASI_EXPOSURE`. With the
    /// range absent, `CameraCapabilities.exposure_min`/`exposure_max` are null
    /// and no client can reject an out-of-range exposure before submitting it —
    /// the request then fails late inside the SDK instead of up front, naming
    /// the limit it violated.
    ///
    /// Implementations MUST convert from their SDK's native unit (ZWO reports
    /// microseconds) and MUST NOT narrow through `i32` on the way — a 2000 s
    /// maximum is 2_000_000_000 µs, within a hair of `i32::MAX` and an outright
    /// overflow for cameras that allow longer.
    async fn get_exposure_range(&self) -> Result<Option<(f64, f64)>, NativeError> {
        Ok(None)
    }

    /// Capture a live-view / preview frame as JPEG bytes when the driver supports it.
    async fn capture_preview(&self) -> Result<Vec<u8>, NativeError> {
        Err(NativeError::NotSupported)
    }
}

/// Tracking rate for mount
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrackingRate {
    Sidereal = 0,
    Lunar = 1,
    Solar = 2,
    King = 3,
    Custom = 4,
}

/// Native mount/telescope device interface
#[async_trait]
pub trait NativeMount: NativeDevice {
    /// Slew to coordinates (RA in hours, Dec in degrees)
    async fn slew_to_coordinates(
        &mut self,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> Result<(), NativeError>;

    /// Get current coordinates
    async fn get_coordinates(&self) -> Result<(f64, f64), NativeError>;

    /// Sync to coordinates
    async fn sync_to_coordinates(
        &mut self,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> Result<(), NativeError>;

    /// Park the mount
    async fn park(&mut self) -> Result<(), NativeError>;

    /// Unpark the mount
    async fn unpark(&mut self) -> Result<(), NativeError>;

    /// Check if mount is slewing
    async fn is_slewing(&self) -> Result<bool, NativeError>;

    /// Check if mount is parked
    async fn is_parked(&self) -> Result<bool, NativeError>;

    /// Pulse guide (for autoguiding)
    async fn pulse_guide(
        &mut self,
        direction: GuideDirection,
        duration_ms: u32,
    ) -> Result<(), NativeError>;

    /// Abort current slew
    async fn abort_slew(&mut self) -> Result<(), NativeError>;

    /// Set tracking enabled/disabled
    async fn set_tracking(&mut self, enabled: bool) -> Result<(), NativeError>;

    /// Get tracking state
    async fn get_tracking(&self) -> Result<bool, NativeError>;

    /// Set tracking rate
    async fn set_tracking_rate(&mut self, rate: TrackingRate) -> Result<(), NativeError>;

    /// Get tracking rate
    async fn get_tracking_rate(&self) -> Result<TrackingRate, NativeError>;

    /// Check if mount supports slewing
    fn can_slew(&self) -> bool;

    /// Check if mount supports sync
    fn can_sync(&self) -> bool;

    /// Check if mount supports pulse guide
    fn can_pulse_guide(&self) -> bool;

    /// Check if mount supports setting tracking rate
    fn can_set_tracking_rate(&self) -> bool;

    /// Get side of pier
    async fn get_side_of_pier(&self) -> Result<PierSide, NativeError>;

    /// Get Alt/Az coordinates
    async fn get_alt_az(&self) -> Result<(f64, f64), NativeError>;

    /// Get local sidereal time
    async fn get_sidereal_time(&self) -> Result<f64, NativeError>;

    /// Read the site the mount is configured for.
    ///
    /// Defaults to `NotSupported`. A mount whose site cannot be read must say
    /// so: a fabricated site would be compared against the computer's and
    /// silently "agree".
    async fn get_site(&self) -> Result<MountSiteInfo, NativeError> {
        Err(NativeError::NotSupported)
    }

    /// Write the site into the mount.
    async fn set_site(&mut self, _site: MountSiteInfo) -> Result<(), NativeError> {
        Err(NativeError::NotSupported)
    }

    /// Read the mount's clock and UTC offset.
    async fn get_clock(&self) -> Result<MountClock, NativeError> {
        Err(NativeError::NotSupported)
    }

    /// Write the clock and UTC offset into the mount.
    async fn set_clock(&mut self, _clock: MountClock) -> Result<(), NativeError> {
        Err(NativeError::NotSupported)
    }

    /// Whether this mount has a home command [`NativeMount::find_home`] can
    /// send.
    ///
    /// Answered from the protocol, not by probing the hardware: a mount either
    /// speaks a home command or it does not. Defaults to `false` alongside the
    /// `NotSupported` default of `find_home`, so the two can never disagree.
    fn can_find_home(&self) -> bool {
        false
    }

    /// Send the mount to its mechanical home position.
    ///
    /// Defaults to `NotSupported` because most serial protocols have no home
    /// command at all. A mount that cannot home must SAY so — silently
    /// no-opping would report success while the mount never moved.
    async fn find_home(&mut self) -> Result<(), NativeError> {
        Err(NativeError::NotSupported)
    }

    /// Whether the mount is sitting at its home position.
    ///
    /// Same default and the same reason: `false` would be a fabricated
    /// answer, and the status layer distinguishes "unsupported" from "no".
    async fn at_home(&self) -> Result<bool, NativeError> {
        Err(NativeError::NotSupported)
    }

    /// Whether [`NativeMount::set_park`] can store the current position as
    /// the park position. Answered from the protocol, and defaults to `false`
    /// alongside the `NotSupported` default of `set_park`.
    fn can_set_park(&self) -> bool {
        false
    }

    /// Store the mount's current position as its park position.
    ///
    /// Defaults to `NotSupported`: most serial protocols park at a fixed or
    /// hand-controller-configured pose and have no command to move it.
    async fn set_park(&mut self) -> Result<(), NativeError> {
        Err(NativeError::NotSupported)
    }
}

/// Where the mount believes it is standing.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MountSiteInfo {
    /// Degrees north, negative south.
    pub latitude_deg: f64,
    /// Degrees EAST of Greenwich, negative west. Note that the LX200 wire
    /// format is west-positive; drivers convert, callers never see that.
    pub longitude_deg: f64,
    /// Metres above sea level, when the protocol carries it.
    pub elevation_m: Option<f64>,
}

/// What the mount believes the time is.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MountClock {
    /// Seconds since the Unix epoch, UTC.
    pub utc_unix_seconds: i64,
    /// Hours EAST of UTC, in the ordinary sense: US Eastern Standard is -5.0.
    pub utc_offset_hours: f64,
}

/// Side of Pier
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PierSide {
    East,
    West,
    Unknown,
}

/// Native focuser device interface
#[async_trait]
pub trait NativeFocuser: NativeDevice {
    /// Move to absolute position
    async fn move_to(&mut self, position: i32) -> Result<(), NativeError>;

    /// Move relative by steps
    async fn move_relative(&mut self, steps: i32) -> Result<(), NativeError>;

    /// Get current position
    async fn get_position(&self) -> Result<i32, NativeError>;

    /// Check if focuser is moving
    async fn is_moving(&self) -> Result<bool, NativeError>;

    /// Halt movement
    async fn halt(&mut self) -> Result<(), NativeError>;

    /// Get temperature (if available)
    async fn get_temperature(&self) -> Result<Option<f64>, NativeError>;

    /// Get maximum position
    fn get_max_position(&self) -> i32;

    /// Get step size
    fn get_step_size(&self) -> f64;
}

/// Native filter wheel device interface
#[async_trait]
pub trait NativeFilterWheel: NativeDevice {
    /// Move to filter position (0-indexed)
    async fn move_to_position(&mut self, position: i32) -> Result<(), NativeError>;

    /// Get current filter position
    async fn get_position(&self) -> Result<i32, NativeError>;

    /// Check if filter wheel is moving
    async fn is_moving(&self) -> Result<bool, NativeError>;

    /// Get number of filter slots
    fn get_filter_count(&self) -> i32;

    /// Get filter names
    async fn get_filter_names(&self) -> Result<Vec<String>, NativeError>;

    /// Set filter name
    async fn set_filter_name(&mut self, position: i32, name: String) -> Result<(), NativeError>;
}

/// Error type for native driver operations
#[derive(Debug, thiserror::Error)]
pub enum NativeError {
    #[error("Device not connected")]
    NotConnected,

    #[error("Device disconnected")]
    Disconnected,

    #[error("Device not found: {0}")]
    DeviceNotFound(String),

    #[error("Invalid device: {0}")]
    InvalidDevice(String),

    #[error("SDK error: {0}")]
    SdkError(String),

    #[error("SDK not loaded")]
    SdkNotLoaded,

    #[error("Invalid parameter: {0}")]
    InvalidParameter(String),

    #[error("Operation not supported")]
    NotSupported,

    #[error("Operation timeout: {0}")]
    Timeout(String),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Unknown error: {0}")]
    Unknown(String),
}

/// Guide direction for mount pulse guiding
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GuideDirection {
    North,
    South,
    East,
    West,
}
