//! Quirk Type Definitions
//!
//! This module defines all the quirk types that can be applied to devices.
//! Quirks are organized by category for easier management.

/// Main quirk enum that wraps all quirk categories
#[derive(Debug, Clone, PartialEq)]
pub enum Quirk {
    /// Temperature-related quirks
    Temperature(TemperatureQuirk),
    /// Position-related quirks (for focusers, filter wheels, rotators)
    Position(PositionQuirk),
    /// Timing-related quirks
    Timing(TimingQuirk),
    /// Discovery-related quirks
    Discovery(DiscoveryQuirk),
    /// Exposure-related quirks
    Exposure(ExposureQuirk),
    /// Communication-related quirks
    Communication(CommunicationQuirk),
    /// Mount-specific quirks
    Mount(MountQuirk),
    /// Camera-specific quirks
    Camera(CameraQuirk),
}

// Temperature quirks

/// Quirks related to temperature reporting
#[derive(Debug, Clone, PartialEq)]
pub enum TemperatureQuirk {
    /// Temperature is reported multiplied by a factor (divide to get real temp)
    ///
    /// Example: ZWO reports temp * 10, so a reading of 200 means 20.0 degrees
    ScaleFactor(f64),

    /// Temperature has a constant offset (add to get real temp)
    ///
    /// Example: Some devices report temp + 5, so a reading of 25 means 20 degrees
    Offset(f64),

    /// Temperature sign is inverted
    ///
    /// Some devices report negative temps as positive and vice versa
    Inverted,

    /// First temperature read after connect is unreliable
    ///
    /// Some cameras (notably some ZWO models) report incorrect temperature
    /// on the first read after connecting. The caller should read twice
    /// and discard the first value.
    SkipFirstRead,

    /// Temperature reading requires a delay after requesting
    ///
    /// Some devices need time between requesting temperature and reading it
    RequiresDelayMs(u64),
}

// Position quirks

/// Quirks related to position reporting (focusers, filter wheels, rotators)
#[derive(Debug, Clone, PartialEq)]
pub enum PositionQuirk {
    /// Position is offset by a constant value
    ///
    /// Example: Device reports position + 100, so 500 means actual position 400
    Offset(i32),

    /// Position axis is inverted
    ///
    /// Moving "forward" actually moves backward and vice versa
    InvertedAxis,

    /// Position may be reported incorrectly immediately after a move
    ///
    /// Some filter wheels report the wrong position right after moving.
    /// Wait this many milliseconds before trusting the reported position.
    DelayAfterMoveMs(u64),

    /// Position wraps around at a maximum value
    ///
    /// For rotators: position 360 wraps to 0
    WrapAroundAt(i32),

    /// Home position is not at zero
    ///
    /// Device considers this position as "home"
    HomeOffset(i32),

    /// Backlash compensation amount
    ///
    /// For focusers: apply this many extra steps when reversing direction
    BacklashSteps(i32),

    /// Focuser step size in microns (real, mechanical travel per motor step).
    ///
    /// SDKs that don't expose this value force a hardcoded fallback in vendor code.
    /// Without the correct per-model value, the focus model's micron axis is wrong
    /// for every focuser whose gear ratio differs from the default. Values must come
    /// from the vendor's published mechanical spec, not from a guess.
    FocuserStepSizeMicrons(f64),
}

// Timing quirks

/// Quirks related to operation timing
#[derive(Debug, Clone, PartialEq)]
pub enum TimingQuirk {
    /// Delay required after connecting before other operations
    DelayAfterConnect(u64),

    /// Delay required after disconnecting before reconnecting
    DelayAfterDisconnect(u64),

    /// Minimum delay between consecutive commands
    DelayBetweenCommands(u64),

    /// Delay required after a specific operation
    DelayAfterOperation {
        operation_name: String,
        delay_ms: u64,
    },

    /// Connection timeout should be extended
    ExtendedConnectionTimeout(u64),

    /// Exposure status polling should use this interval
    ExposurePollingIntervalMs(u64),

    /// USB bandwidth issues require slower communication
    SlowUsbCommunication,
}

// Discovery quirks

/// Quirks related to device discovery
#[derive(Debug, Clone, PartialEq)]
pub enum DiscoveryQuirk {
    /// SDK can crash during discovery - serialize all discovery calls
    RequiresSerializedDiscovery,

    /// SDK discovery is not thread-safe
    NotThreadSafe,

    /// Skip this operation during discovery (can cause crash)
    SkipOperation(String),

    /// Skip multiple operations during discovery
    SkipOperations(Vec<String>),

    /// Discovery requires SDK to be initialized first
    RequiresSdkInit,

    /// Discovery can hang - use this timeout in milliseconds
    DiscoveryTimeoutMs(u64),

    /// Discovery may return stale results - re-scan after this many seconds
    CacheTtlSeconds(u64),

    /// SDK may not report all devices on first scan
    RequiresMultipleScans(u32),
}

// Exposure quirks

/// Quirks related to camera exposures
#[derive(Debug, Clone, PartialEq)]
pub enum ExposureQuirk {
    /// Minimum exposure time is higher than SDK reports
    MinExposureMs(u64),

    /// Maximum exposure time is lower than SDK reports
    MaxExposureSecs(f64),

    /// Exposure time needs to be set in a specific unit
    ExposureTimeUnit(ExposureTimeUnit),

    /// Camera needs a "warm-up" exposure before real exposures
    WarmupExposureNeeded,

    /// Download may timeout - use extended timeout
    ExtendedDownloadTimeoutSecs(u64),

    /// Abort exposure command doesn't work reliably
    AbortUnreliable,

    /// Status polling returns wrong state during exposure
    PollingUnreliable,

    /// Dark frame mode requires specific handling
    DarkFrameRequiresShutter,
}

/// Units for exposure time
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ExposureTimeUnit {
    /// Microseconds
    Microseconds,
    /// Milliseconds
    Milliseconds,
    /// Seconds
    Seconds,
    /// Hundredths of a second
    Centiseconds,
}

// Communication quirks

/// Quirks related to device communication
#[derive(Debug, Clone, PartialEq)]
pub enum CommunicationQuirk {
    /// Serial port needs specific baud rate
    RequiredBaudRate(u32),

    /// Serial port needs specific settings
    SerialConfig {
        data_bits: u8,
        stop_bits: u8,
        parity: String,
    },

    /// Commands need a specific line ending
    LineEnding(String),

    /// Commands need a specific prefix
    CommandPrefix(String),

    /// Commands need a specific suffix
    CommandSuffix(String),

    /// Response parsing needs special handling
    ResponseFormat(String),

    /// USB needs specific endpoint configuration
    UsbEndpointConfig { read_ep: u8, write_ep: u8 },

    /// Device may drop connection under load
    UnreliableConnection,

    /// Retry failed commands this many times
    RetryCount(u32),
}

// Mount quirks

/// Quirks specific to telescope mounts
#[derive(Debug, Clone, PartialEq)]
pub enum MountQuirk {
    /// Direction buttons are inverted
    InvertedNorthSouth,
    InvertedEastWest,

    /// Slew speeds are in different units than expected
    SlewSpeedScale(f64),

    /// Goto precision is limited
    GotoPrecisionArcsec(f64),

    /// Park command doesn't work - use goto instead
    ParkUsingGoto {
        alt: f64,
        az: f64,
    },

    /// Home command requires specific sequence
    HomeSequence(Vec<String>),

    /// Tracking rate has an error
    TrackingRateCorrection(f64),

    /// Pier side reporting is inverted
    InvertedPierSide,

    /// Meridian flip logic needs adjustment
    MeridianFlipOffset(f64),

    /// Sync command needs special handling
    SyncRequiresAlignment,

    /// Guide rate is in different units
    GuideRateScale(f64),
}

// Camera quirks

/// Quirks specific to cameras
#[derive(Debug, Clone, PartialEq)]
pub enum CameraQuirk {
    /// Gain values need scaling
    GainScale(f64),

    /// Offset values need scaling
    OffsetScale(f64),

    /// Bayer pattern is different than reported
    ActualBayerPattern(String),

    /// Bit depth is different than reported
    ActualBitDepth(u8),

    /// ROI dimensions must be multiples of this value
    RoiMultiple(u32),

    /// Maximum binning is lower than reported
    MaxBinning(u8),

    /// USB bandwidth limit should be set
    UsbBandwidthLimit(u32),

    /// High-speed mode needs specific configuration
    HighSpeedModeConfig { usb_limit: u32, ddr_enable: bool },

    /// Cooler has limited range
    CoolerRange { min_temp: f64, max_temp: f64 },

    /// Cooler power reporting is inaccurate
    CoolerPowerScale(f64),

    /// Readout mode names don't match actual modes
    ReadoutModeMapping(Vec<(String, u32)>),
}

// Helper implementations

impl Quirk {
    /// Get a human-readable description of this quirk
    pub fn description(&self) -> String {
        match self {
            Quirk::Temperature(t) => match t {
                TemperatureQuirk::ScaleFactor(f) => {
                    format!("Temperature scaled by {}", f)
                }
                TemperatureQuirk::Offset(o) => format!("Temperature offset by {}", o),
                TemperatureQuirk::Inverted => "Temperature sign inverted".to_string(),
                TemperatureQuirk::SkipFirstRead => "First temperature read unreliable".to_string(),
                TemperatureQuirk::RequiresDelayMs(ms) => {
                    format!("Temperature read requires {}ms delay", ms)
                }
            },
            Quirk::Position(p) => match p {
                PositionQuirk::Offset(o) => format!("Position offset by {}", o),
                PositionQuirk::InvertedAxis => "Position axis inverted".to_string(),
                PositionQuirk::DelayAfterMoveMs(ms) => {
                    format!("{}ms delay after move", ms)
                }
                PositionQuirk::WrapAroundAt(v) => format!("Position wraps at {}", v),
                PositionQuirk::HomeOffset(o) => format!("Home position at {}", o),
                PositionQuirk::BacklashSteps(s) => format!("Backlash compensation: {} steps", s),
                PositionQuirk::FocuserStepSizeMicrons(um) => {
                    format!("Focuser step size: {} um/step", um)
                }
            },
            Quirk::Timing(t) => match t {
                TimingQuirk::DelayAfterConnect(ms) => {
                    format!("{}ms delay after connect", ms)
                }
                TimingQuirk::DelayAfterDisconnect(ms) => {
                    format!("{}ms delay after disconnect", ms)
                }
                TimingQuirk::DelayBetweenCommands(ms) => {
                    format!("{}ms between commands", ms)
                }
                TimingQuirk::DelayAfterOperation {
                    operation_name,
                    delay_ms,
                } => {
                    format!("{}ms delay after {}", delay_ms, operation_name)
                }
                TimingQuirk::ExtendedConnectionTimeout(ms) => {
                    format!("Extended connection timeout: {}ms", ms)
                }
                TimingQuirk::ExposurePollingIntervalMs(ms) => {
                    format!("Exposure polling interval: {}ms", ms)
                }
                TimingQuirk::SlowUsbCommunication => "Slow USB communication".to_string(),
            },
            Quirk::Discovery(d) => match d {
                DiscoveryQuirk::RequiresSerializedDiscovery => {
                    "Discovery must be serialized".to_string()
                }
                DiscoveryQuirk::NotThreadSafe => "Discovery not thread-safe".to_string(),
                DiscoveryQuirk::SkipOperation(op) => {
                    format!("Skip {} during discovery", op)
                }
                DiscoveryQuirk::SkipOperations(ops) => {
                    format!("Skip during discovery: {:?}", ops)
                }
                DiscoveryQuirk::RequiresSdkInit => "SDK init required for discovery".to_string(),
                DiscoveryQuirk::DiscoveryTimeoutMs(ms) => {
                    format!("Discovery timeout: {}ms", ms)
                }
                DiscoveryQuirk::CacheTtlSeconds(s) => {
                    format!("Discovery cache TTL: {}s", s)
                }
                DiscoveryQuirk::RequiresMultipleScans(n) => {
                    format!("Requires {} discovery scans", n)
                }
            },
            Quirk::Exposure(e) => match e {
                ExposureQuirk::MinExposureMs(ms) => {
                    format!("Minimum exposure: {}ms", ms)
                }
                ExposureQuirk::MaxExposureSecs(s) => {
                    format!("Maximum exposure: {}s", s)
                }
                ExposureQuirk::ExposureTimeUnit(u) => {
                    format!("Exposure time unit: {:?}", u)
                }
                ExposureQuirk::WarmupExposureNeeded => "Warmup exposure needed".to_string(),
                ExposureQuirk::ExtendedDownloadTimeoutSecs(s) => {
                    format!("Extended download timeout: {}s", s)
                }
                ExposureQuirk::AbortUnreliable => "Abort exposure unreliable".to_string(),
                ExposureQuirk::PollingUnreliable => "Exposure polling unreliable".to_string(),
                ExposureQuirk::DarkFrameRequiresShutter => {
                    "Dark frame requires mechanical shutter".to_string()
                }
            },
            Quirk::Communication(c) => match c {
                CommunicationQuirk::RequiredBaudRate(b) => {
                    format!("Required baud rate: {}", b)
                }
                CommunicationQuirk::SerialConfig {
                    data_bits,
                    stop_bits,
                    parity,
                } => {
                    format!("Serial config: {}{}N{}", data_bits, parity, stop_bits)
                }
                CommunicationQuirk::LineEnding(e) => {
                    format!("Line ending: {:?}", e)
                }
                CommunicationQuirk::CommandPrefix(p) => {
                    format!("Command prefix: {:?}", p)
                }
                CommunicationQuirk::CommandSuffix(s) => {
                    format!("Command suffix: {:?}", s)
                }
                CommunicationQuirk::ResponseFormat(f) => {
                    format!("Response format: {}", f)
                }
                CommunicationQuirk::UsbEndpointConfig { read_ep, write_ep } => {
                    format!("USB endpoints: read={}, write={}", read_ep, write_ep)
                }
                CommunicationQuirk::UnreliableConnection => "Connection may drop".to_string(),
                CommunicationQuirk::RetryCount(n) => {
                    format!("Retry count: {}", n)
                }
            },
            Quirk::Mount(m) => match m {
                MountQuirk::InvertedNorthSouth => "N/S buttons inverted".to_string(),
                MountQuirk::InvertedEastWest => "E/W buttons inverted".to_string(),
                MountQuirk::SlewSpeedScale(s) => format!("Slew speed scale: {}", s),
                MountQuirk::GotoPrecisionArcsec(p) => {
                    format!("Goto precision: {}\"", p)
                }
                MountQuirk::ParkUsingGoto { alt, az } => {
                    format!("Park using goto: alt={}, az={}", alt, az)
                }
                MountQuirk::HomeSequence(seq) => {
                    format!("Home sequence: {:?}", seq)
                }
                MountQuirk::TrackingRateCorrection(c) => {
                    format!("Tracking rate correction: {}", c)
                }
                MountQuirk::InvertedPierSide => "Pier side inverted".to_string(),
                MountQuirk::MeridianFlipOffset(o) => {
                    format!("Meridian flip offset: {}", o)
                }
                MountQuirk::SyncRequiresAlignment => "Sync requires prior alignment".to_string(),
                MountQuirk::GuideRateScale(s) => format!("Guide rate scale: {}", s),
            },
            Quirk::Camera(c) => match c {
                CameraQuirk::GainScale(s) => format!("Gain scale: {}", s),
                CameraQuirk::OffsetScale(s) => format!("Offset scale: {}", s),
                CameraQuirk::ActualBayerPattern(p) => {
                    format!("Actual Bayer pattern: {}", p)
                }
                CameraQuirk::ActualBitDepth(b) => format!("Actual bit depth: {}", b),
                CameraQuirk::RoiMultiple(m) => format!("ROI multiple: {}", m),
                CameraQuirk::MaxBinning(b) => format!("Max binning: {}x{}", b, b),
                CameraQuirk::UsbBandwidthLimit(l) => {
                    format!("USB bandwidth limit: {}", l)
                }
                CameraQuirk::HighSpeedModeConfig {
                    usb_limit,
                    ddr_enable,
                } => {
                    format!("High-speed: usb={}, ddr={}", usb_limit, ddr_enable)
                }
                CameraQuirk::CoolerRange { min_temp, max_temp } => {
                    format!("Cooler range: {} to {}", min_temp, max_temp)
                }
                CameraQuirk::CoolerPowerScale(s) => format!("Cooler power scale: {}", s),
                CameraQuirk::ReadoutModeMapping(m) => {
                    format!("Readout mode mapping: {:?}", m)
                }
            },
        }
    }

    /// Get the category of this quirk
    pub fn category(&self) -> &'static str {
        match self {
            Quirk::Temperature(_) => "Temperature",
            Quirk::Position(_) => "Position",
            Quirk::Timing(_) => "Timing",
            Quirk::Discovery(_) => "Discovery",
            Quirk::Exposure(_) => "Exposure",
            Quirk::Communication(_) => "Communication",
            Quirk::Mount(_) => "Mount",
            Quirk::Camera(_) => "Camera",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_quirk_description() {
        let quirk = Quirk::Temperature(TemperatureQuirk::ScaleFactor(10.0));
        assert!(quirk.description().contains("10"));

        let quirk = Quirk::Position(PositionQuirk::InvertedAxis);
        assert!(quirk.description().contains("inverted"));
    }

    #[test]
    fn test_quirk_category() {
        let quirk = Quirk::Temperature(TemperatureQuirk::ScaleFactor(10.0));
        assert_eq!(quirk.category(), "Temperature");

        let quirk = Quirk::Mount(MountQuirk::InvertedNorthSouth);
        assert_eq!(quirk.category(), "Mount");
    }
}
