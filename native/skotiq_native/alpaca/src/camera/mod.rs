//! Alpaca Camera API implementation

mod download;
mod image_array;
mod image_bytes;

use image_array::*;
use image_bytes::*;

use crate::AlpacaError;
use skotiq_device::ascom::{CameraState, SensorType};
use std::time::Duration;

/// Camera status aggregate for parallel status query
#[derive(Debug, Clone)]
pub struct CameraStatus {
    pub state: CameraState,
    pub connected: bool,
    pub image_ready: bool,
    pub percent_completed: Option<i32>,
    pub ccd_temperature: Option<f64>,
    pub cooler_on: Option<bool>,
    pub cooler_power: Option<f64>,
    pub bin_x: i32,
    pub bin_y: i32,
}

/// Camera capabilities for determining what features are available
#[derive(Debug, Clone)]
pub struct CameraCapabilities {
    pub can_abort_exposure: bool,
    pub can_stop_exposure: bool,
    pub can_asymmetric_bin: bool,
    pub can_pulse_guide: bool,
    pub can_fast_readout: bool,
    pub can_set_ccd_temperature: bool,
    pub can_get_cooler_power: bool,
    pub has_shutter: bool,
    pub max_bin_x: i32,
    pub max_bin_y: i32,
}

#[derive(Debug, Clone)]
pub struct CameraSensorInfo {
    pub camera_x_size: i32,
    pub camera_y_size: i32,
    pub pixel_size_x: f64,
    pub pixel_size_y: f64,
    pub max_adu: i32,
    pub sensor_type: SensorType,
    pub sensor_name: String,
    pub bayer_offset_x: Option<i32>,
    pub bayer_offset_y: Option<i32>,
}

#[derive(Debug, Clone)]
pub struct CameraSubframe {
    pub start_x: i32,
    pub start_y: i32,
    pub num_x: i32,
    pub num_y: i32,
}

/// Comprehensive camera status aggregate for parallel status query
/// Includes all status, gain/offset, binning, and subframe in a single query
#[derive(Debug, Clone)]
pub struct CameraFullStatus {
    pub state: CameraState,
    pub connected: bool,
    pub image_ready: bool,
    pub percent_completed: Option<i32>,
    pub ccd_temperature: Option<f64>,
    pub cooler_on: Option<bool>,
    pub cooler_power: Option<f64>,
    pub heat_sink_temperature: Option<f64>,
    pub gain: Option<i32>,
    pub offset: Option<i32>,
    pub bin_x: i32,
    pub bin_y: i32,
    pub start_x: i32,
    pub start_y: i32,
    pub num_x: i32,
    pub num_y: i32,
}

/// Alpaca image-array element types as carried in the JSON `Type` field.
///
/// The parser branches on `Type` so it knows whether a fractional pixel is
/// legitimate (Double/Single) or a corruption signal (any integer Type);
/// coercing every token to `i64`/`f64` zero-fills on anything unexpected.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImageArrayElementType {
    /// Type 0 - server omitted/unknown
    Unknown = 0,
    Int16 = 1,
    Int32 = 2,
    Double = 3,
    /// Type 4 - Single (float32)
    Single = 4,
    UInt64 = 5,
    /// Type 6 - Byte (UInt8)
    Byte = 6,
    Int64 = 7,
    UInt16 = 8,
}

impl ImageArrayElementType {
    fn from_i64(v: i64) -> Self {
        match v {
            0 => Self::Unknown,
            1 => Self::Int16,
            2 => Self::Int32,
            3 => Self::Double,
            4 => Self::Single,
            5 => Self::UInt64,
            6 => Self::Byte,
            7 => Self::Int64,
            8 => Self::UInt16,
            // Why: an unknown Type is a deliberate hard fail — see
            // `parse_image_array_json` which converts this branch to
            // `AlpacaError::UnsupportedImageArray`.
            _ => Self::Unknown,
        }
    }

    fn is_floating(self) -> bool {
        matches!(self, Self::Double | Self::Single)
    }
}

/// Result of a successful Alpaca image-array download.
///
/// `pixels` is laid out **planar**: `[plane_0_pixels..., plane_1_pixels..., ...]`,
/// each plane stored row-major (`y * width + x`). For rank-2 monochrome,
/// `planes == 1` and the layout is identical to the historical `Vec<u16>`
/// produced by `download_image_data_typed`.
#[derive(Debug, Clone)]
pub struct ImageArrayResult {
    pub width: u32,
    pub height: u32,
    pub planes: u32,
    pub pixels: Vec<u16>,
    pub element_type: ImageArrayElementType,
}

alpaca_device!(AlpacaCamera, Camera);

impl AlpacaCamera {
    skotiq_device::ascom_camera_members!(alpaca_member);

    // - Value: 2D/3D array of i32 pixel values
    // - Type: data type (1=Int16, 2=Int32, 3=Double, etc.)
    // - Rank: 2 for mono, 3 for color
    pub async fn image_array(&self) -> Result<String, AlpacaError> {
        self.client.get("imagearray").await
    }

    /// Get comprehensive camera status in a single parallel query
    pub async fn get_status(&self) -> Result<CameraStatus, AlpacaError> {
        let (
            state,
            connected,
            image_ready,
            percent_completed,
            ccd_temperature,
            cooler_on,
            cooler_power,
            bin_x,
            bin_y,
        ) = tokio::join!(
            self.camera_state(),
            self.is_connected(),
            self.image_ready(),
            self.percent_completed(),
            self.ccd_temperature(),
            self.cooler_on(),
            self.cooler_power(),
            self.bin_x(),
            self.bin_y(),
        );

        Ok(CameraStatus {
            state: state?,
            connected: connected?,
            image_ready: image_ready?,
            percent_completed: percent_completed.ok(),
            ccd_temperature: ccd_temperature.ok(),
            cooler_on: cooler_on.ok(),
            cooler_power: cooler_power.ok(),
            bin_x: bin_x?,
            bin_y: bin_y?,
        })
    }

    /// Get camera capabilities in a single parallel query
    pub async fn get_capabilities(&self) -> Result<CameraCapabilities, AlpacaError> {
        let (
            can_abort_exposure,
            can_stop_exposure,
            can_asymmetric_bin,
            can_pulse_guide,
            can_fast_readout,
            can_set_ccd_temperature,
            can_get_cooler_power,
            has_shutter,
            max_bin_x,
            max_bin_y,
        ) = tokio::join!(
            self.can_abort_exposure(),
            self.can_stop_exposure(),
            self.can_asymmetric_bin(),
            self.can_pulse_guide(),
            self.can_fast_readout(),
            self.can_set_ccd_temperature(),
            self.can_get_cooler_power(),
            self.has_shutter(),
            self.max_bin_x(),
            self.max_bin_y(),
        );

        Ok(CameraCapabilities {
            can_abort_exposure: can_abort_exposure?,
            can_stop_exposure: can_stop_exposure?,
            can_asymmetric_bin: can_asymmetric_bin?,
            can_pulse_guide: can_pulse_guide?,
            can_fast_readout: can_fast_readout?,
            can_set_ccd_temperature: can_set_ccd_temperature?,
            can_get_cooler_power: can_get_cooler_power?,
            has_shutter: has_shutter?,
            max_bin_x: max_bin_x?,
            max_bin_y: max_bin_y?,
        })
    }

    /// Get camera sensor information in a single parallel query
    pub async fn get_sensor_info(&self) -> Result<CameraSensorInfo, AlpacaError> {
        let (
            camera_x_size,
            camera_y_size,
            pixel_size_x,
            pixel_size_y,
            max_adu,
            sensor_type,
            sensor_name,
            bayer_offset_x,
            bayer_offset_y,
        ) = tokio::join!(
            self.camera_x_size(),
            self.camera_y_size(),
            self.pixel_size_x(),
            self.pixel_size_y(),
            self.max_adu(),
            self.sensor_type(),
            self.sensor_name(),
            self.bayer_offset_x(),
            self.bayer_offset_y(),
        );

        Ok(CameraSensorInfo {
            camera_x_size: camera_x_size?,
            camera_y_size: camera_y_size?,
            pixel_size_x: pixel_size_x?,
            pixel_size_y: pixel_size_y?,
            max_adu: max_adu?,
            sensor_type: SensorType::from(sensor_type?),
            sensor_name: sensor_name?,
            bayer_offset_x: bayer_offset_x.ok(),
            bayer_offset_y: bayer_offset_y.ok(),
        })
    }

    /// Get camera subframe settings in a single parallel query
    pub async fn get_subframe(&self) -> Result<CameraSubframe, AlpacaError> {
        let (start_x, start_y, num_x, num_y) =
            tokio::join!(self.start_x(), self.start_y(), self.num_x(), self.num_y(),);

        Ok(CameraSubframe {
            start_x: start_x?,
            start_y: start_y?,
            num_x: num_x?,
            num_y: num_y?,
        })
    }

    /// Get comprehensive camera status in a single parallel query
    /// This includes state, temperature, cooling, gain/offset, binning, and subframe
    /// Use this for efficient status polling instead of making multiple individual calls
    pub async fn get_full_status(&self) -> Result<CameraFullStatus, AlpacaError> {
        let (
            state,
            connected,
            image_ready,
            percent_completed,
            ccd_temperature,
            cooler_on,
            cooler_power,
            heat_sink_temperature,
            gain,
            offset,
            bin_x,
            bin_y,
            start_x,
            start_y,
            num_x,
            num_y,
        ) = tokio::join!(
            self.camera_state(),
            self.is_connected(),
            self.image_ready(),
            self.percent_completed(),
            self.ccd_temperature(),
            self.cooler_on(),
            self.cooler_power(),
            self.heat_sink_temperature(),
            self.gain(),
            self.offset(),
            self.bin_x(),
            self.bin_y(),
            self.start_x(),
            self.start_y(),
            self.num_x(),
            self.num_y(),
        );

        Ok(CameraFullStatus {
            // Core state - these are critical and should propagate errors
            state: state?,
            connected: connected?,
            image_ready: image_ready?,
            percent_completed: percent_completed.ok(),
            // Temperature/cooling - may not be available on all cameras
            ccd_temperature: ccd_temperature.ok(),
            cooler_on: cooler_on.ok(),
            cooler_power: cooler_power.ok(),
            heat_sink_temperature: heat_sink_temperature.ok(),
            // Gain and offset - may not be available on all cameras
            gain: gain.ok(),
            offset: offset.ok(),
            // Binning - critical settings
            bin_x: bin_x?,
            bin_y: bin_y?,
            // Subframe - critical settings
            start_x: start_x?,
            start_y: start_y?,
            num_x: num_x?,
            num_y: num_y?,
        })
    }
}
