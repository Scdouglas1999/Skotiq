//! What a run asks of the imaging camera.

use super::DeviceResult;
use async_trait::async_trait;

/// Image data returned from camera
#[derive(Debug, Clone)]
pub struct ImageData {
    pub width: u32,
    pub height: u32,
    pub data: Vec<u16>,
    pub bits_per_pixel: u32,
    pub exposure_secs: f64,
    pub gain: Option<i32>,
    pub offset: Option<i32>,
    pub temperature: Option<f64>,
    pub filter: Option<String>,
    pub timestamp: i64,
    /// Sensor type: "Monochrome" or "Color"
    pub sensor_type: Option<String>,
    /// The color filter at the frame's pixel (0, 0); `None` for a mono frame.
    pub color_filter: Option<skotiq_device::BayerPattern>,
    /// The camera's own file for this frame (a DSLR's raw file), when it
    /// delivered one.
    pub camera_file: Option<skotiq_device::CameraFile>,
}

impl ImageData {
    /// The 2x2 Bayer cell for the previews that demosaic a frame; `None` for
    /// a mono frame and for X-Trans, which they show as luminance.
    pub fn bayer_cell(&self) -> Option<skotiq_imaging::BayerPattern> {
        match self.color_filter? {
            skotiq_device::BayerPattern::Rggb => Some(skotiq_imaging::BayerPattern::RGGB),
            skotiq_device::BayerPattern::Grbg => Some(skotiq_imaging::BayerPattern::GRBG),
            skotiq_device::BayerPattern::Gbrg => Some(skotiq_imaging::BayerPattern::GBRG),
            skotiq_device::BayerPattern::Bggr => Some(skotiq_imaging::BayerPattern::BGGR),
            skotiq_device::BayerPattern::XTrans(_) => None,
        }
    }
}

/// Binned-pixel camera ROI used for one exposure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CameraSubframe {
    pub start_x: u32,
    pub start_y: u32,
    pub width: u32,
    pub height: u32,
}

/// Everything the camera needs to take one frame.
#[derive(Debug, Clone, PartialEq)]
pub struct ExposureRequest<'a> {
    pub camera_id: &'a str,
    pub duration_secs: f64,
    pub gain: Option<i32>,
    pub offset: Option<i32>,
    pub bin_x: i32,
    pub bin_y: i32,
    /// `None` reads the full sensor.
    pub subframe: Option<CameraSubframe>,
    /// The sequencer's frame-type string ("Light"/"Dark"/"Flat"/"Bias"/
    /// "DarkFlat", case-insensitive). A camera with a mechanical shutter
    /// (Moravian, FLI, some CCDs) keeps it closed for dark and bias frames.
    pub frame_type: &'a str,
}

impl<'a> ExposureRequest<'a> {
    /// A full-sensor light frame, unbinned, at the camera's current gain and
    /// offset.
    pub fn new(camera_id: &'a str, duration_secs: f64) -> Self {
        Self {
            camera_id,
            duration_secs,
            gain: None,
            offset: None,
            bin_x: 1,
            bin_y: 1,
            subframe: None,
            frame_type: "Light",
        }
    }

    pub fn gain(mut self, gain: Option<i32>) -> Self {
        self.gain = gain;
        self
    }

    pub fn offset(mut self, offset: Option<i32>) -> Self {
        self.offset = offset;
        self
    }

    pub fn binning(mut self, bin_x: i32, bin_y: i32) -> Self {
        self.bin_x = bin_x;
        self.bin_y = bin_y;
        self
    }

    pub fn subframe(mut self, subframe: Option<CameraSubframe>) -> Self {
        self.subframe = subframe;
        self
    }

    pub fn frame_type(mut self, frame_type: &'a str) -> Self {
        self.frame_type = frame_type;
        self
    }
}

#[async_trait]
pub trait CameraOps: Send + Sync {
    /// Take one exposure and return the image data.
    async fn camera_start_exposure(&self, request: ExposureRequest<'_>) -> DeviceResult<ImageData>;

    async fn camera_abort_exposure(&self, camera_id: &str) -> DeviceResult<()>;

    /// Set cooler state and target temperature
    async fn camera_set_cooler(
        &self,
        camera_id: &str,
        enabled: bool,
        target_temp: f64,
    ) -> DeviceResult<()>;

    async fn camera_get_temperature(&self, camera_id: &str) -> DeviceResult<f64>;

    async fn camera_get_cooler_power(&self, camera_id: &str) -> DeviceResult<f64>;

    /// Whether the camera's cooler is switched on, as the driver reports it.
    ///
    /// `Ok(None)` means the driver gives no reading. Defaulted so test doubles
    /// and the null ops need not answer; the bridge implementation overrides it.
    async fn camera_get_cooler_on(&self, _camera_id: &str) -> DeviceResult<Option<bool>> {
        Ok(None)
    }

    /// The temperature the cooler is holding the sensor to, in Celsius, while
    /// the cooler is on. `Ok(None)` with the cooler off, no cooler, or no
    /// reading. Defaulted for the same reason as `camera_get_cooler_on`.
    async fn camera_get_cooler_setpoint(&self, _camera_id: &str) -> DeviceResult<Option<f64>> {
        Ok(None)
    }

    /// The camera's UNBINNED pixel pitch in microns, as `(x, y)`.
    ///
    /// `Ok(None)` means the driver does not report one, and the FITS writer
    /// then omits `XPIXSZ`/`YPIXSZ` rather than guessing. Defaulted so a
    /// device layer that has no camera (test doubles, the null ops) does not
    /// have to answer; the bridge implementations override it.
    async fn camera_get_pixel_size_um(&self, _camera_id: &str) -> DeviceResult<Option<(f64, f64)>> {
        Ok(None)
    }

    /// How the app knows this camera — the driver-reported name, with whatever
    /// serial or unique id it has to tell two identical models apart.
    ///
    /// Fills FITS `INSTRUME` when no equipment profile names a camera. Without
    /// it a sequenced frame says nothing at all about which camera took it,
    /// and on a two-camera rig the sensor geometry is the only clue — so the
    /// keyword every stacker and archive groups by is the one keyword absent.
    /// This is the driver's answer, not a profile the operator has to have
    /// remembered to fill in.
    ///
    /// `Ok(None)` means the id is not a connected camera or has no name worth
    /// recording, and the writer then omits `INSTRUME` rather than inventing
    /// one. Defaulted so test doubles and the null ops need not answer.
    async fn camera_get_model(&self, _camera_id: &str) -> DeviceResult<Option<String>> {
        Ok(None)
    }
}
