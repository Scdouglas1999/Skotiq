//! Alpaca Camera API implementation

mod download;
mod image_array;
mod image_bytes;

use image_array::*;
use image_bytes::*;

use crate::AlpacaError;
use skotiq_device::ascom::camera::{CameraControl, CameraControls, Probe};
use skotiq_device::ascom::CameraState;
use std::time::Duration;

/// Camera status aggregate for parallel status query
#[derive(Debug)]
pub struct CameraStatus {
    pub state: CameraState,
    pub connected: bool,
    pub image_ready: bool,
    pub percent_completed: Option<i32>,
    pub ccd_temperature: Option<f64>,
    pub cooler_on: Option<bool>,
    pub cooler_power: Option<f64>,
    /// As the camera answered: a failed read is the caller's to resolve.
    pub bin_x: Result<i32, AlpacaError>,
    pub bin_y: Result<i32, AlpacaError>,
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
/// each plane stored row-major (`y * width + x`), the layout of `ImageData`.
/// The wire carries the ASCOM array `[x][y]` (height changing fastest); the
/// decoders reorder it.
#[derive(Debug, Clone)]
pub struct ImageArrayResult {
    pub width: u32,
    pub height: u32,
    pub planes: u32,
    pub pixels: Vec<u16>,
    pub element_type: ImageArrayElementType,
}

alpaca_device!(AlpacaCamera, Camera, {
    controls: std::sync::OnceLock<CameraControls>,
});

impl AlpacaCamera {
    skotiq_device::ascom_camera_members!(alpaca_member);

    /// How this camera offers gain and offset, read once per connection (a
    /// wrapper is made for each connect).
    pub async fn controls(&self) -> CameraControls {
        if let Some(controls) = self.controls.get() {
            return controls.clone();
        }
        fn probe<T>(read: Result<T, AlpacaError>) -> Probe<T> {
            Probe::from(read.map_err(skotiq_device::DriverError::from))
        }
        let (gain, gains, gain_min, gain_max, offset, offsets, offset_min, offset_max) = tokio::join!(
            self.gain(),
            self.gains(),
            self.gain_min(),
            self.gain_max(),
            self.offset(),
            self.offsets(),
            self.offset_min(),
            self.offset_max(),
        );
        let controls = CameraControls {
            gain: CameraControl::detect(
                probe(gain),
                probe(gains),
                probe(gain_min),
                probe(gain_max),
            ),
            offset: CameraControl::detect(
                probe(offset),
                probe(offsets),
                probe(offset_min),
                probe(offset_max),
            ),
        };
        self.controls.get_or_init(|| controls).clone()
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
            bin_x,
            bin_y,
        })
    }
}
