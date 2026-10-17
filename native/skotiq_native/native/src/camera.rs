//! Camera-specific types and structures for native drivers

use serde::{Deserialize, Serialize};

/// Camera capabilities
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CameraCapabilities {
    pub can_cool: bool,
    pub can_set_gain: bool,
    pub can_set_offset: bool,
    pub can_set_binning: bool,
    pub can_subframe: bool,
    pub has_shutter: bool,
    pub has_guider_port: bool,
    pub max_bin_x: i32,
    pub max_bin_y: i32,
    pub supports_readout_modes: bool,
}

/// Current camera status
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CameraStatus {
    pub state: CameraState,
    pub sensor_temp: Option<f64>,
    pub cooler_power: Option<f64>,
    pub target_temp: Option<f64>,
    pub cooler_on: bool,
    pub gain: i32,
    pub offset: i32,
    pub bin_x: i32,
    pub bin_y: i32,
    pub exposure_remaining: Option<f64>, // seconds
}

/// Camera operational state
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CameraState {
    Idle,
    Waiting,
    Exposing,
    Reading,
    Downloading,
    Error,
}

/// The kind of frame being captured.
///
/// Drives shutter behavior on cameras with a MECHANICAL SHUTTER (Moravian G-series,
/// FLI, some CCDs): dark/bias frames must be taken with the shutter CLOSED to exclude
/// light, otherwise the "dark" is contaminated and ruins calibration. CMOS cameras
/// without a shutter simply ignore it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum FrameType {
    #[default]
    Light,
    Dark,
    Flat,
    Bias,
    DarkFlat,
}

impl FrameType {
    pub fn as_str(self) -> &'static str {
        match self {
            FrameType::Light => "Light",
            FrameType::Dark => "Dark",
            FrameType::Flat => "Flat",
            FrameType::Bias => "Bias",
            FrameType::DarkFlat => "DarkFlat",
        }
    }

    /// Whether the mechanical shutter should be OPEN during the exposure.
    /// Light and Flat collect light; Dark/Bias/DarkFlat must exclude it.
    pub fn opens_shutter(self) -> bool {
        matches!(self, FrameType::Light | FrameType::Flat)
    }

    /// Parse the sequencer's string frame type (case-insensitive). Unknown values
    /// map to `Light` — the safe default (shutter open, no missed frame).
    pub fn from_str_lenient(s: &str) -> Self {
        match s.trim().to_ascii_lowercase().as_str() {
            "dark" => FrameType::Dark,
            "flat" => FrameType::Flat,
            "bias" => FrameType::Bias,
            "darkflat" | "dark_flat" | "dark flat" => FrameType::DarkFlat,
            _ => FrameType::Light,
        }
    }
}

/// Exposure parameters
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExposureParams {
    pub duration_secs: f64,
    pub gain: Option<i32>,
    pub offset: Option<i32>,
    pub bin_x: i32,
    pub bin_y: i32,
    pub subframe: Option<SubFrame>,
    pub readout_mode: Option<String>, // Vendor-specific readout mode name
    /// Frame kind — drives mechanical-shutter behavior for dark/bias frames.
    #[serde(default)]
    pub frame_type: FrameType,
}

/// Subframe region for partial readout
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubFrame {
    pub start_x: u32,
    pub start_y: u32,
    pub width: u32,
    pub height: u32,
}

/// Sensor information
///
/// # `bit_depth` vs `max_adu` — two DIFFERENT quantities
///
/// Conflating these produced a shipped defect (camera status reported
/// `maxAdu: 4095` for an ASI1600MM whose frames measurably contain values up to
/// 65504), so the contract is spelled out here:
///
/// * [`SensorInfo::bit_depth`] is the **ADC resolution** — how many significant
///   bits the sensor digitises (12 for an ASI1600MM). It describes precision,
///   NOT the numeric range of the delivered samples.
/// * [`SensorInfo::max_adu`] is the **pixel-container full scale** — the largest
///   value that can actually appear in the `u16` pixel buffer this driver hands
///   to the imaging pipeline. Every consumer (flat-frame percent-of-full-scale
///   targets, saturation thresholds, histogram scaling, e-/ADU conversion)
///   compares against real pixel values, so this is the only one of the two
///   that may be used as a full-scale divisor.
///
/// The two differ whenever a vendor SDK left-justifies sub-16-bit samples into
/// the 16-bit container — the norm for 12/14-bit astro CMOS. A 12-bit ADC
/// delivered left-shifted by 4 has `bit_depth: 12` but `max_adu: 65520`
/// (`4095 << 4`), and its samples are all multiples of 16.
/// `skotiq_imaging::fits::ImageValidationOptions::saturation_threshold`
/// documents the same convention from the pipeline side.
///
/// A driver MUST report `max_adu` in container units. Deriving it as
/// `(1 << bit_depth) - 1` is only correct for a sensor whose samples are
/// right-justified (or that is genuinely 16-bit).
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SensorInfo {
    pub width: u32,
    pub height: u32,
    pub pixel_size_x: f64, // microns
    pub pixel_size_y: f64, // microns
    /// Largest value that can appear in the delivered `u16` pixel data. See the
    /// type-level docs — this is NOT `2^bit_depth - 1` for a left-justified
    /// sub-16-bit sensor.
    pub max_adu: u32,
    /// ADC resolution in bits. Describes precision only; see the type-level docs.
    pub bit_depth: u32,
    pub color: bool,
    pub bayer_pattern: Option<BayerPattern>,
}

/// Bayer pattern for color sensors
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BayerPattern {
    Rggb,
    Grbg,
    Gbrg,
    Bggr,
}

/// Readout mode (vendor-specific)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReadoutMode {
    pub name: String,
    pub description: String,
    pub index: i32,
    pub gain_min: Option<i32>,
    pub gain_max: Option<i32>,
    pub offset_min: Option<i32>,
    pub offset_max: Option<i32>,
}

/// Recommended camera settings sourced from the vendor SDK.
///
/// Populated on a best-effort basis from whatever the vendor SDK exposes:
/// - `unity_gain` is the manufacturer-recommended gain for unity electron-per-ADU
///   operation (or the SDK's published "default gain" when that is the
///   recommended starting point — e.g. QHY's `DefaultGain` control).
/// - `hcg_gain` is the gain at which the sensor transitions to high
///   conversion gain (HCG / dual-gain readout). Only ZWO and QHY publish this
///   programmatically; most vendors document it in the manual instead.
/// - `default_offset` is the manufacturer-recommended bias/offset value.
///
/// All fields are `Option<i32>` because vendor SDKs report these
/// inconsistently. The `notes` string documents what the recommendation
/// is based on so the UI can surface it to the user
/// (e.g. "QHY DefaultGain control = 56").
///
/// Returning `Ok(CameraRecommendedSettings::default())` (all `None`) is the
/// honest answer for cameras whose SDK genuinely doesn't expose unity gain —
/// callers MUST NOT fabricate a value in that case.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CameraRecommendedSettings {
    /// Manufacturer-recommended unity gain (1 e-/ADU), if the SDK exposes it.
    pub unity_gain: Option<i32>,
    /// Gain at which HCG (high conversion gain) engages, if the SDK exposes it.
    pub hcg_gain: Option<i32>,
    /// Manufacturer-recommended default offset/bias, if the SDK exposes it.
    pub default_offset: Option<i32>,
    /// Manufacturer-recommended cooling setpoint in Celsius, if the SDK exposes
    /// it. This is currently always `None`: no vendor SDK we bind exposes a
    /// recommended cooling setpoint (vendors document a "sweet spot" in the
    /// manual rather than via a control ID). The field exists so the
    /// Dart/profile layer has an honest, typed slot for the value the moment a
    /// vendor SDK starts reporting it — fabricating a setpoint here would be a
    /// silent fallback, so we leave it `None` until a real source exists.
    pub recommended_cooling_setpoint_c: Option<f64>,
    /// Human-readable explanation of how the values above were derived.
    /// Empty string when nothing was queryable.
    pub notes: String,
}

/// Vendor-specific features
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct VendorFeatures {
    /// QHY: Sensor chamber air pressure (hPa)
    pub sensor_chamber_pressure: Option<f64>,

    /// QHY: Sensor chamber humidity (%)
    pub sensor_chamber_humidity: Option<f64>,

    /// ZWO/QHY/Player One: USB bandwidth percentage or SDK bandwidth-limit value.
    pub usb_bandwidth: Option<f64>,

    /// ZWO: Hardware binning support
    pub hardware_binning: bool,

    /// ZWO/Player One: Anti-dew heater control
    pub anti_dew_heater: Option<bool>,

    /// Player One: Fan power percentage (0-100)
    pub fan_power: Option<f64>,

    /// Generic: Additional vendor-specific data
    pub custom_data: std::collections::HashMap<String, serde_json::Value>,
}

/// Image data from camera
#[derive(Debug, Clone)]
pub struct ImageData {
    pub width: u32,
    pub height: u32,
    pub data: Vec<u16>, // 16-bit raw data
    pub bits_per_pixel: u32,
    pub bayer_pattern: Option<BayerPattern>,
    pub metadata: ImageMetadata,
}

/// Image metadata
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImageMetadata {
    pub exposure_time: f64,
    pub gain: i32,
    pub offset: i32,
    pub bin_x: i32,
    pub bin_y: i32,
    pub temperature: Option<f64>,
    pub timestamp: chrono::DateTime<chrono::Utc>,
    pub subframe: Option<SubFrame>,
    pub readout_mode: Option<String>,
    pub vendor_data: VendorFeatures,
}

#[cfg(test)]
mod recommended_settings_tests {
    use super::*;

    #[test]
    fn default_recommended_settings_is_all_none() {
        // Per IMG-P3-2 contract: a camera whose SDK exposes nothing must
        // surface as an empty struct so the Dart side knows there is no
        // recommendation to apply (and the profile is left untouched).
        let s = CameraRecommendedSettings::default();
        assert!(s.unity_gain.is_none());
        assert!(s.hcg_gain.is_none());
        assert!(s.default_offset.is_none());
        assert!(s.recommended_cooling_setpoint_c.is_none());
        assert!(s.notes.is_empty());
    }

    #[test]
    fn recommended_settings_roundtrips_via_serde() {
        // Acts as a guard for the FRB bridge surface — the struct must
        // serialize without loss because it crosses the Dart/Rust boundary.
        let s = CameraRecommendedSettings {
            unity_gain: Some(100),
            hcg_gain: None,
            default_offset: Some(30),
            recommended_cooling_setpoint_c: None,
            notes: "ZWO SDK reports default gain = 100".to_string(),
        };
        let json = serde_json::to_string(&s).expect("serialize");
        let back: CameraRecommendedSettings = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(back.unity_gain, Some(100));
        assert_eq!(back.hcg_gain, None);
        assert_eq!(back.default_offset, Some(30));
        assert_eq!(back.recommended_cooling_setpoint_c, None);
        assert_eq!(back.notes, "ZWO SDK reports default gain = 100");
    }
}
