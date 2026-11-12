//! An Alpaca camera. The client holds no state and takes no lock, so an
//! abort reaches the camera while a frame is still being fetched.

use super::{no_preview, Camera, ExposureAborts};
use crate::device::DriverType;
use crate::device_capabilities::DeviceCapabilities;
use crate::device_manager::ops::camera::UNKNOWN_CAMERA_SETTING;
use crate::device_manager::rig::RigDriver;
use crate::dispatch::DeviceOpError;
use crate::error::SkotiqError;
use async_trait::async_trait;
use skotiq_device::{DriverError, ImageData, SubFrame};
use std::sync::Arc;
use tracing::warn;

pub(crate) struct AlpacaCameraHandle {
    device_id: String,
    camera: Arc<skotiq_alpaca::AlpacaCamera>,
    aborts: ExposureAborts,
}

impl AlpacaCameraHandle {
    pub(crate) fn new(device_id: &str, camera: skotiq_alpaca::AlpacaCamera) -> Self {
        Self {
            device_id: device_id.to_string(),
            camera: Arc::new(camera),
            aborts: ExposureAborts::new(),
        }
    }
}

#[async_trait]
impl RigDriver for AlpacaCameraHandle {
    async fn disconnect(&self) -> Result<(), DriverError> {
        Ok(self.camera.disconnect().await?)
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        let device_id = self.device_id.as_str();
        match self.camera.heartbeat().await {
            Ok(rtt_ms) => {
                tracing::trace!("Alpaca camera {} heartbeat: {}ms RTT", device_id, rtt_ms);
                Ok(true)
            }
            Err(e) => {
                tracing::debug!("Alpaca camera {} heartbeat failed: {}", device_id, e);
                Ok(false)
            }
        }
    }
}

#[async_trait]
impl Camera for AlpacaCameraHandle {
    fn aborts(&self) -> &ExposureAborts {
        &self.aborts
    }

    async fn start_exposure(
        &self,
        duration: f64,
        gain: Option<i32>,
        offset: Option<i32>,
        bin_x: i32,
        bin_y: i32,
        subframe: Option<SubFrame>,
        frame_type: skotiq_device::FrameType,
    ) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let camera = &self.camera;
        alpaca_start_exposure(
            camera,
            device_id,
            duration,
            gain,
            offset,
            (bin_x, bin_y),
            subframe,
            frame_type,
        )
        .await
    }

    async fn is_exposure_complete(&self) -> Result<bool, DeviceOpError> {
        let camera = &self.camera;
        camera.image_ready().await.map_err(DeviceOpError::from)
    }

    async fn stop_exposure(&self) -> Result<(), DeviceOpError> {
        let camera = &self.camera;
        camera.abort_exposure().await.map_err(DeviceOpError::from)
    }

    async fn read_frame(&self) -> Result<ImageData, DeviceOpError> {
        let device_id = self.device_id.as_str();
        let camera = &self.camera;
        // Use the new download_image_data method
        let (width, height, pixels) = camera.download_image_data().await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!(
                    "Failed to download image from Alpaca camera {}: {}",
                    device_id, e
                ),
                e,
            )
        })?;

        // Get camera metadata
        // Same as the INDI path below: record a failed read as UNKNOWN
        // rather than 0, so it cannot outrank the configured gain and
        // mislabel the frame's FITS header.
        let controls = camera.controls().await;
        let gain = match camera.gain().await {
            Ok(g) => controls.gain.from_wire(g),
            Err(e) => {
                warn!(
                    "Failed to read camera gain for {}: {}. Recording it as \
                     unknown so the configured gain is used instead.",
                    device_id, e
                );
                UNKNOWN_CAMERA_SETTING
            }
        };
        let offset = match camera.offset().await {
            Ok(o) => controls.offset.from_wire(o),
            Err(e) => {
                warn!(
                    "Failed to read camera offset for {}: {}. Recording it as \
                     unknown so the configured offset is used instead.",
                    device_id, e
                );
                UNKNOWN_CAMERA_SETTING
            }
        };
        let bin_x = match camera.bin_x().await {
            Ok(b) => b,
            Err(e) => {
                warn!(
                    "Failed to read camera bin_x for {}: {}. Using default 1.",
                    device_id, e
                );
                1
            }
        };
        let bin_y = match camera.bin_y().await {
            Ok(b) => b,
            Err(e) => {
                warn!(
                    "Failed to read camera bin_y for {}: {}. Using default 1.",
                    device_id, e
                );
                1
            }
        };
        let temp = camera.ccd_temperature().await.ok();
        let exposure_time = match camera.last_exposure_duration().await {
            Ok(d) => d,
            Err(e) => {
                warn!(
                    "Failed to read last exposure duration for {}: {}. Using default 0.0.",
                    device_id, e
                );
                0.0
            }
        };

        // ASCOM ICameraV3 SensorType: 0=Monochrome, 1=Color (direct
        // colour, no Bayer mask), 2=RGGB, 3=CMYG, 4=CMYG2, 5=LRGB.
        // A failed read yields an ordinal outside the enum, which names
        // no family and so produces no Bayer pattern.
        let sensor_type = match camera.sensor_type().await {
            Ok(t) => t,
            Err(e) => {
                warn!(
                    "Failed to read sensor type for {}: {}. Marking sensor type unknown.",
                    device_id, e
                );
                -1
            }
        };
        // Both offsets must be READ, not assumed: they, and never the
        // SensorType ordinal, carry which corner of the 2x2 block holds
        // red. Defaulting a failed read to 0 maps to RGGB —
        // indistinguishable from a genuine RGGB sensor — which transposes
        // red and blue on a BGGR/GRBG one-shot-colour camera and stamps
        // the wrong BAYERPAT into the FITS header, neither of which is
        // recoverable from the saved frame. `None` means "pattern
        // unknown", which leaves the frame undebayered rather than
        // debayered wrongly.
        let (bayer_offset_x, bayer_offset_y) =
            if crate::ascom_sensor_type::has_nameable_bayer_order(sensor_type) {
                match (camera.bayer_offset_x().await, camera.bayer_offset_y().await) {
                    (Ok(x), Ok(y)) => (Some(x), Some(y)),
                    (x, y) => {
                        warn!(
                            "Failed to read bayer offsets for {} (x: {:?}, y: {:?}). \
                             Leaving the Bayer pattern UNKNOWN so the frame is not \
                             debayered with a guessed pattern.",
                            device_id,
                            x.err(),
                            y.err()
                        );
                        (None, None)
                    }
                }
            } else {
                // Nothing to read: no other sensor family carries an
                // RGGB-style order, so the two property round-trips are
                // skipped for every frame off a mono, direct-colour or
                // CMYG/CMYG2/LRGB camera.
                (None, None)
            };
        let bayer_pattern = crate::ascom_sensor_type::bayer_pattern_from_sensor(
            sensor_type,
            bayer_offset_x,
            bayer_offset_y,
        );

        // A colour sensor with no nameable Bayer order leaves this
        // frame undebayered and writes no BAYERPAT card. That is
        // correct for a direct-colour or CMYG/CMYG2/LRGB sensor, but
        // silent for a Bayer one-shot-colour camera whose driver
        // MISREPORTS SensorType as 1 — the OSC gate keys on 2 — and
        // the loss is not recoverable from the saved frame. Say it
        // here, on the download, so the operator reads it in the
        // app's log rather than finding it in the pixels; latched
        // per (device, SensorType) because a legitimately
        // undebayerable camera downloads a frame every exposure.
        crate::ascom_sensor_type::warn_debayer_skip_once(device_id, sensor_type);

        Ok(ImageData {
            width,
            height,
            data: pixels,
            bits_per_pixel: 16,
            bayer_pattern,
            metadata: skotiq_device::ImageMetadata {
                exposure_time,
                gain,
                offset,
                bin_x,
                bin_y,
                temperature: temp,
                timestamp: chrono::Utc::now(),
                subframe: None,
                readout_mode: None,
                vendor_data: skotiq_device::VendorFeatures::default(),
                camera_file: None,
            },
        })
    }

    async fn status(&self) -> Result<crate::device::CameraStatus, DeviceOpError> {
        let device_id = self.device_id.as_str();
        let camera = &self.camera;
        let status = camera.get_status().await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!(
                    "Failed to read Alpaca camera status for {}: {}",
                    device_id, e
                ),
                e,
            )
        })?;
        let capabilities = camera.get_capabilities().await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!(
                    "Failed to read Alpaca camera capabilities for {}: {}",
                    device_id, e
                ),
                e,
            )
        })?;
        let sensor = camera.get_sensor_info().await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!(
                    "Failed to read Alpaca camera sensor info for {}: {}",
                    device_id, e
                ),
                e,
            )
        })?;
        let controls = camera.controls().await;
        let (gain, offset, setpoint) = tokio::join!(camera.gain(), camera.offset(), async {
            if capabilities.can_set_ccd_temperature {
                camera.ccd_temperature_setpoint().await.ok()
            } else {
                None
            }
        });
        let gain = gain.ok().map(|wire| controls.gain.from_wire(wire));
        let offset = offset.ok().map(|wire| controls.offset.from_wire(wire));

        Ok(crate::device::CameraStatus {
            connected: true,
            state: match status.state {
                skotiq_alpaca::CameraState::Idle => crate::device::CameraState::Idle,
                skotiq_alpaca::CameraState::Waiting => crate::device::CameraState::Waiting,
                skotiq_alpaca::CameraState::Exposing => crate::device::CameraState::Exposing,
                skotiq_alpaca::CameraState::Reading => crate::device::CameraState::Reading,
                skotiq_alpaca::CameraState::Downloading => crate::device::CameraState::Download,
                skotiq_alpaca::CameraState::Error => crate::device::CameraState::Error,
            },
            sensor_temp: status.ccd_temperature,
            cooler_power: status.cooler_power,
            target_temp: setpoint,
            cooler_on: status.cooler_on.unwrap_or(false),
            gain: gain.unwrap_or(0),
            offset: offset.unwrap_or(0),
            bin_x: status.bin_x,
            bin_y: status.bin_y,
            sensor_width: sensor.camera_x_size as u32,
            sensor_height: sensor.camera_y_size as u32,
            pixel_size_x: sensor.pixel_size_x,
            pixel_size_y: sensor.pixel_size_y,
            max_adu: sensor.max_adu as u32,
            saturation_adu: None,
            can_cool: capabilities.can_set_ccd_temperature,
            can_set_gain: controls.gain.is_present(),
            can_set_offset: controls.offset.is_present(),
        })
    }

    async fn recommended_settings(
        &self,
    ) -> Result<skotiq_device::CameraRecommendedSettings, DeviceOpError> {
        Ok(skotiq_device::CameraRecommendedSettings::default())
    }

    async fn set_gain(&self, gain: i32) -> Result<(), DeviceOpError> {
        let camera = &self.camera;
        let wire = camera
            .controls()
            .await
            .gain
            .to_wire(gain, "Gain")
            .map_err(DeviceOpError::from)?;
        camera.set_gain(wire).await.map_err(DeviceOpError::from)
    }

    async fn set_offset(&self, offset: i32) -> Result<(), DeviceOpError> {
        let camera = &self.camera;
        let wire = camera
            .controls()
            .await
            .offset
            .to_wire(offset, "Offset")
            .map_err(DeviceOpError::from)?;
        camera.set_offset(wire).await.map_err(DeviceOpError::from)
    }

    async fn set_binning(&self, bin_x: i32, bin_y: i32) -> Result<(), DeviceOpError> {
        let camera = &self.camera;
        camera.set_bin_x(bin_x).await?;
        camera.set_bin_y(bin_y).await?;
        Ok(())
    }

    async fn set_readout_mode(&self, mode_index: i32) -> Result<(), DeviceOpError> {
        let camera = &self.camera;
        camera
            .set_readout_mode(mode_index)
            .await
            .map_err(DeviceOpError::from)
    }

    async fn set_cooler(
        &self,
        enabled: bool,
        target_temp: Option<f64>,
    ) -> Result<(), DeviceOpError> {
        let camera = &self.camera;
        let setpoint = skotiq_device::ascom::camera::cooler_setpoint_to_write(
            enabled,
            target_temp,
            camera.can_set_ccd_temperature().await.ok(),
        );
        if let Some(temp) = setpoint {
            camera.set_ccd_temperature(temp).await?;
        }
        camera.set_cooler_on(enabled).await?;
        Ok(())
    }

    async fn capture_preview(&self) -> Result<Vec<u8>, DeviceOpError> {
        Err(no_preview(DriverType::Alpaca, &self.device_id))
    }

    async fn capabilities(&self, device_id: &str) -> Result<DeviceCapabilities, SkotiqError> {
        crate::device_capabilities::get_alpaca_capabilities(device_id).await
    }
}

/// One Alpaca exposure, by the ASCOM camera rules both transports share
/// (`skotiq_device::ascom::camera`): binning, then the whole frame in binned
/// pixels, then gain and offset in the camera's own mode, then
/// `StartExposure` with the shutter closed for darks and biases.
#[allow(clippy::too_many_arguments)]
async fn alpaca_start_exposure(
    camera: &skotiq_alpaca::AlpacaCamera,
    device_id: &str,
    duration: f64,
    gain: Option<i32>,
    offset: Option<i32>,
    bin: (i32, i32),
    subframe: Option<SubFrame>,
    frame_type: skotiq_device::FrameType,
) -> Result<(), DeviceOpError> {
    use skotiq_device::ascom::camera::{exposes_to_light, frame_geometry};
    let failed = |what: &str, e: skotiq_alpaca::AlpacaError| {
        DeviceOpError::caused_by(
            Some(device_id.to_string()),
            format!("Failed to {what} on Alpaca camera {device_id}: {e}"),
            e,
        )
    };
    let (sensor_x, sensor_y, max_bin_x, max_bin_y) = tokio::join!(
        camera.camera_x_size(),
        camera.camera_y_size(),
        camera.max_bin_x(),
        camera.max_bin_y(),
    );
    let sensor = (
        sensor_x.map_err(|e| failed("read CameraXSize", e))?,
        sensor_y.map_err(|e| failed("read CameraYSize", e))?,
    );
    let max_bin = (max_bin_x.unwrap_or(1), max_bin_y.unwrap_or(1));
    let frame = frame_geometry(sensor, max_bin, bin, subframe.as_ref())
        .map_err(|e| DeviceOpError::hardware(Some(device_id.to_string()), e.to_string()))?;

    camera
        .set_bin_x(bin.0)
        .await
        .map_err(|e| failed("set BinX", e))?;
    camera
        .set_bin_y(bin.1)
        .await
        .map_err(|e| failed("set BinY", e))?;
    camera
        .set_start_x(frame.start_x)
        .await
        .map_err(|e| failed("set StartX", e))?;
    camera
        .set_start_y(frame.start_y)
        .await
        .map_err(|e| failed("set StartY", e))?;
    camera
        .set_num_x(frame.num_x)
        .await
        .map_err(|e| failed("set NumX", e))?;
    camera
        .set_num_y(frame.num_y)
        .await
        .map_err(|e| failed("set NumY", e))?;

    // Gain and offset are optional members: a camera without them, or one that
    // refuses the value, still exposes at its current setting (as INDI does).
    let controls = camera.controls().await;
    if let Some(requested) = gain {
        match controls.gain.to_wire(requested, "Gain") {
            Ok(wire) => {
                if let Err(e) = camera.set_gain(wire).await {
                    warn!("Alpaca camera {device_id} refused gain {requested}; exposing at its current gain: {e}");
                }
            }
            Err(skotiq_device::DriverError::NotSupported) => {}
            Err(e) => warn!("Alpaca camera {device_id}: {e}; exposing at its current gain"),
        }
    }
    if let Some(requested) = offset {
        match controls.offset.to_wire(requested, "Offset") {
            Ok(wire) => {
                if let Err(e) = camera.set_offset(wire).await {
                    warn!("Alpaca camera {device_id} refused offset {requested}; exposing at its current offset: {e}");
                }
            }
            Err(skotiq_device::DriverError::NotSupported) => {}
            Err(e) => warn!("Alpaca camera {device_id}: {e}; exposing at its current offset"),
        }
    }
    camera
        .start_exposure(duration, exposes_to_light(frame_type))
        .await
        .map_err(DeviceOpError::from)
}
