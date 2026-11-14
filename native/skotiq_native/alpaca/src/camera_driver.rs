//! An Alpaca camera as a camera driver.
//!
//! The client holds no state and takes no lock, so an abort reaches the
//! camera while a frame is still being fetched.

use crate::{AlpacaCamera, AlpacaError};
use async_trait::async_trait;
use skotiq_device::ascom::camera::{
    cooler_setpoint_to_write, exposes_to_light, frame_geometry, readout_mode_name,
    recorded_exposure_seconds, SensorMembers,
};
use skotiq_device::ascom::sensor_type::{
    bayer_pattern_from_sensor, has_nameable_bayer_order, warn_debayer_skip_once,
};
use skotiq_device::{
    CameraCapabilities, CameraDescription, CameraDriver, CameraReport, CameraState, CameraStatus,
    DeviceDriver, DriverError, ExposureParams, ImageData, ImageMetadata, ReadoutMode, SensorInfo,
    SubFrame, Vendor, VendorFeatures, UNKNOWN_CAMERA_SETTING,
};
use std::sync::{Arc, Mutex};

/// A connected Alpaca camera. A clone is the same camera.
#[derive(Clone)]
pub struct AlpacaCameraDriver {
    camera: Arc<AlpacaCamera>,
    id: String,
    /// Seconds the exposure in progress or last taken was started with,
    /// for a frame whose camera does not report `LastExposureDuration`.
    commanded_seconds: Arc<Mutex<Option<f64>>>,
}

impl AlpacaCameraDriver {
    /// `camera` is connected.
    pub fn new(camera: AlpacaCamera) -> Self {
        let id = format!(
            "alpaca:{}:camera:{}",
            camera.base_url(),
            camera.device_number()
        );
        Self {
            camera: Arc::new(camera),
            id,
            commanded_seconds: Arc::default(),
        }
    }

    pub fn camera(&self) -> &AlpacaCamera {
        &self.camera
    }

    /// The members that describe the sensor. The size and `MaxADU` are
    /// mandatory; the rest a camera may not have.
    async fn sensor(&self) -> Result<SensorInfo, AlpacaError> {
        let camera = &self.camera;
        let (x, y, max_adu, pixel_x, pixel_y, sensor_type, offset_x, offset_y) = tokio::join!(
            camera.camera_x_size(),
            camera.camera_y_size(),
            camera.max_adu(),
            camera.pixel_size_x(),
            camera.pixel_size_y(),
            camera.sensor_type(),
            camera.bayer_offset_x(),
            camera.bayer_offset_y(),
        );
        Ok(SensorMembers {
            camera_x_size: x?,
            camera_y_size: y?,
            max_adu: max_adu?,
            pixel_size_x: pixel_x.ok(),
            pixel_size_y: pixel_y.ok(),
            sensor_type: sensor_type.ok(),
            bayer_offset_x: offset_x.ok(),
            bayer_offset_y: offset_y.ok(),
        }
        .sensor_info())
    }

    /// The name of the read mode in force, for a camera that lists its modes.
    async fn readout_mode_name(&self) -> Option<String> {
        let (mode, modes) = tokio::join!(self.camera.readout_mode(), self.camera.readout_modes());
        readout_mode_name(mode.ok(), modes.ok())
    }
}

impl std::fmt::Debug for AlpacaCameraDriver {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("AlpacaCameraDriver").field(&self.id).finish()
    }
}

/// A failed operation in the server's own words. Whoever shows it reads its
/// kind from the Alpaca error inside.
fn own(error: AlpacaError) -> DriverError {
    DriverError::Backend(Box::new(error))
}

/// `error` as the failure of one step of an operation, keeping its kind.
fn failed(what: &str, error: AlpacaError) -> DriverError {
    let words = format!("Failed to {what}: {error}");
    match DriverError::from(error) {
        DriverError::NotConnected => DriverError::NotConnected,
        DriverError::Disconnected => DriverError::Disconnected,
        DriverError::NotSupported => DriverError::NotSupported,
        DriverError::Timeout(_) => DriverError::Timeout(words),
        DriverError::InvalidParameter(_) => DriverError::InvalidParameter(words),
        _ => DriverError::Backend(words.into()),
    }
}

#[async_trait]
impl DeviceDriver for AlpacaCameraDriver {
    fn id(&self) -> &str {
        &self.id
    }

    fn name(&self) -> &str {
        &self.id
    }

    fn vendor(&self) -> Vendor {
        Vendor::Ascom
    }

    /// A value of this type is a camera that was connected;
    /// [`CameraDriver::heartbeat`] asks the server whether it still is.
    fn is_connected(&self) -> bool {
        true
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        self.camera.connect().await.map_err(own)
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        self.camera.disconnect().await.map_err(own)
    }
}

#[async_trait]
impl CameraDriver for AlpacaCameraDriver {
    /// Not kept; see `describe`.
    fn capabilities(&self) -> CameraCapabilities {
        CameraCapabilities::default()
    }

    /// One quick, unretried read. A server that does not answer is a camera
    /// that is not connected, not a failed probe.
    async fn heartbeat(&self) -> Result<bool, DriverError> {
        match self.camera.heartbeat().await {
            Ok(rtt_ms) => {
                tracing::trace!("Alpaca camera {} heartbeat: {}ms RTT", self.id, rtt_ms);
                Ok(true)
            }
            Err(e) => {
                tracing::debug!("Alpaca camera {} heartbeat failed: {}", self.id, e);
                Ok(false)
            }
        }
    }

    async fn report(&self) -> Result<CameraReport, DriverError> {
        let camera = &self.camera;
        let status = camera
            .get_status()
            .await
            .map_err(|e| failed("read Alpaca camera status", e))?;
        let can_cool = camera.can_set_ccd_temperature().await.unwrap_or(false);
        let sensor = self
            .sensor()
            .await
            .map_err(|e| failed("read Alpaca camera sensor info", e))?;
        let controls = camera.controls().await;
        let (gain, offset, setpoint) = tokio::join!(camera.gain(), camera.offset(), async {
            if can_cool {
                camera.ccd_temperature_setpoint().await.ok()
            } else {
                None
            }
        });
        let gain = gain.ok().map(|wire| controls.gain.from_wire(wire));
        let offset = offset.ok().map(|wire| controls.offset.from_wire(wire));
        Ok(CameraReport {
            status: CameraStatus {
                state: match status.state {
                    crate::CameraState::Idle => CameraState::Idle,
                    crate::CameraState::Waiting => CameraState::Waiting,
                    crate::CameraState::Exposing => CameraState::Exposing,
                    crate::CameraState::Reading => CameraState::Reading,
                    crate::CameraState::Downloading => CameraState::Downloading,
                    crate::CameraState::Error => CameraState::Error,
                },
                sensor_temp: status.ccd_temperature,
                cooler_power: status.cooler_power,
                target_temp: setpoint,
                cooler_on: status.cooler_on,
                gain: gain.unwrap_or(0),
                offset: offset.unwrap_or(0),
                bin_x: status.bin_x,
                bin_y: status.bin_y,
                exposure_remaining: None,
            },
            sensor,
            can_cool,
            can_set_gain: controls.gain.is_present(),
            can_set_offset: controls.offset.is_present(),
        })
    }

    async fn get_status(&self) -> Result<CameraStatus, DriverError> {
        Ok(self.report().await?.status)
    }

    /// Every `CanXxx` member and the bin limits are optional: an unanswered
    /// one reads as the feature absent. ICameraV4 has no set-point limits.
    async fn describe(&self) -> CameraDescription {
        let camera = &self.camera;
        let controls = camera.controls().await;
        let sensor = self.sensor().await.unwrap_or_else(|e| {
            tracing::warn!("Alpaca camera {} did not describe its sensor: {e}", self.id);
            SensorInfo::default()
        });
        let max_bin_x = camera.max_bin_x().await.unwrap_or(1);
        let max_bin_y = camera.max_bin_y().await.unwrap_or(1);
        let readout_modes = self.get_readout_modes().await.unwrap_or_default();
        let exposure_range = match (camera.exposure_min().await, camera.exposure_max().await) {
            (Ok(min), Ok(max)) => Some((min, max)),
            _ => None,
        };
        CameraDescription {
            capabilities: CameraCapabilities {
                can_cool: camera.can_set_ccd_temperature().await.unwrap_or(false),
                can_set_gain: controls.gain.is_present(),
                can_set_offset: controls.offset.is_present(),
                can_set_binning: max_bin_x > 1 || max_bin_y > 1,
                can_subframe: true,
                has_shutter: camera.has_shutter().await.unwrap_or(false),
                has_guider_port: false,
                max_bin_x,
                max_bin_y,
                supports_readout_modes: !readout_modes.is_empty(),
            },
            sensor,
            gain_range: controls.gain.range(),
            offset_range: controls.offset.range(),
            iso_speeds: controls.gain.iso_speeds(),
            readout_modes,
            cooler_temp_range: None,
            exposure_range,
            can_abort_exposure: camera.can_abort_exposure().await.unwrap_or(false),
            can_stop_exposure: camera.can_stop_exposure().await.unwrap_or(false),
            can_asymmetric_bin: camera.can_asymmetric_bin().await.unwrap_or(false),
            sensor_type: None,
        }
    }

    /// One exposure by the ASCOM camera rules both transports share
    /// (`skotiq_device::ascom::camera`): binning, then the whole frame in
    /// binned pixels, then gain and offset in the camera's own mode, then
    /// `StartExposure` with the shutter closed for darks and biases.
    async fn start_exposure(&mut self, params: ExposureParams) -> Result<(), DriverError> {
        let camera = &self.camera;
        let id = &self.id;
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
        let bin = (params.bin_x, params.bin_y);
        let frame = frame_geometry(sensor, max_bin, bin, params.subframe.as_ref())
            .map_err(|e| DriverError::Backend(e.to_string().into()))?;

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

        // Gain and offset are optional members: a camera without them, or
        // one that refuses the value, still exposes at its current setting.
        let controls = camera.controls().await;
        if let Some(requested) = params.gain {
            match controls.gain.to_wire(requested, "Gain") {
                Ok(wire) => {
                    if let Err(e) = camera.set_gain(wire).await {
                        tracing::warn!("Alpaca camera {id} refused gain {requested}; exposing at its current gain: {e}");
                    }
                }
                Err(DriverError::NotSupported) => {}
                Err(e) => tracing::warn!("Alpaca camera {id}: {e}; exposing at its current gain"),
            }
        }
        if let Some(requested) = params.offset {
            match controls.offset.to_wire(requested, "Offset") {
                Ok(wire) => {
                    if let Err(e) = camera.set_offset(wire).await {
                        tracing::warn!("Alpaca camera {id} refused offset {requested}; exposing at its current offset: {e}");
                    }
                }
                Err(DriverError::NotSupported) => {}
                Err(e) => tracing::warn!("Alpaca camera {id}: {e}; exposing at its current offset"),
            }
        }
        camera
            .start_exposure(params.duration_secs, exposes_to_light(params.frame_type))
            .await
            .map_err(own)?;
        *self
            .commanded_seconds
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = Some(params.duration_secs);
        Ok(())
    }

    async fn abort_exposure(&mut self) -> Result<(), DriverError> {
        self.camera.abort_exposure().await.map_err(own)
    }

    async fn is_exposure_complete(&self) -> Result<bool, DriverError> {
        self.camera.image_ready().await.map_err(own)
    }

    async fn download_image(&mut self) -> Result<ImageData, DriverError> {
        let camera = &self.camera;
        let id = &self.id;
        let (width, height, pixels) = camera
            .download_image_data()
            .await
            .map_err(|e| failed("download image from Alpaca camera", e))?;

        // A read that fails is recorded as unknown, not as 0: a 0 would be
        // taken for the camera's setting and written into the frame's header
        // in place of the one the exposure was configured with.
        let controls = camera.controls().await;
        let gain = match camera.gain().await {
            Ok(wire) => controls.gain.from_wire(wire),
            Err(e) => {
                tracing::warn!(
                    "Failed to read camera gain for {id}: {e}. Recording it as unknown so the \
                     configured gain is used instead."
                );
                UNKNOWN_CAMERA_SETTING
            }
        };
        let offset = match camera.offset().await {
            Ok(wire) => controls.offset.from_wire(wire),
            Err(e) => {
                tracing::warn!(
                    "Failed to read camera offset for {id}: {e}. Recording it as unknown so the \
                     configured offset is used instead."
                );
                UNKNOWN_CAMERA_SETTING
            }
        };
        let bin_x = camera.bin_x().await.unwrap_or_else(|e| {
            tracing::warn!("Failed to read camera bin_x for {id}: {e}. Using default 1.");
            1
        });
        let bin_y = camera.bin_y().await.unwrap_or_else(|e| {
            tracing::warn!("Failed to read camera bin_y for {id}: {e}. Using default 1.");
            1
        });
        let temperature = camera.ccd_temperature().await.ok();
        let commanded = *self
            .commanded_seconds
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let reported = camera.last_exposure_duration().await.inspect_err(|e| {
            tracing::warn!(
                "Failed to read last exposure duration for {id}: {e}. Recording the {commanded:?} s \
                 the exposure was started with."
            );
        });
        let exposure_time = recorded_exposure_seconds(reported.ok(), commanded);
        let readout_mode = self.readout_mode_name().await;

        // A failed read yields an ordinal outside the `SensorType` enum,
        // which names no family and so no Bayer pattern.
        let sensor_type = camera.sensor_type().await.unwrap_or_else(|e| {
            tracing::warn!("Failed to read sensor type for {id}: {e}. Marking it unknown.");
            -1
        });
        // The offsets, never the `SensorType` ordinal, say which corner of
        // the 2x2 block holds red. A failed read leaves the pattern unknown
        // and the frame undebayered: a guessed pattern transposes red and
        // blue on a BGGR or GRBG sensor, and that cannot be recovered from
        // the saved frame.
        let (bayer_offset_x, bayer_offset_y) = if has_nameable_bayer_order(sensor_type) {
            match (camera.bayer_offset_x().await, camera.bayer_offset_y().await) {
                (Ok(x), Ok(y)) => (Some(x), Some(y)),
                (x, y) => {
                    tracing::warn!(
                        "Failed to read bayer offsets for {id} (x: {:?}, y: {:?}). Leaving the \
                         Bayer pattern unknown so the frame is not debayered with a guessed \
                         pattern.",
                        x.err(),
                        y.err()
                    );
                    (None, None)
                }
            }
        } else {
            (None, None)
        };
        let bayer_pattern = bayer_pattern_from_sensor(sensor_type, bayer_offset_x, bayer_offset_y);
        // A colour sensor with no nameable Bayer order is said once per
        // camera and sensor type, where the operator reads it in the log.
        warn_debayer_skip_once(id, sensor_type);

        Ok(ImageData {
            width,
            height,
            data: pixels,
            bits_per_pixel: 16,
            bayer_pattern: bayer_pattern.map(Into::into),
            metadata: ImageMetadata {
                exposure_time,
                gain,
                offset,
                bin_x,
                bin_y,
                temperature,
                timestamp: chrono::Utc::now(),
                subframe: None,
                readout_mode,
                vendor_data: VendorFeatures::default(),
                camera_file: None,
            },
        })
    }

    async fn set_cooler(
        &mut self,
        enabled: bool,
        target_temp: Option<f64>,
    ) -> Result<(), DriverError> {
        let setpoint = cooler_setpoint_to_write(
            enabled,
            target_temp,
            self.camera.can_set_ccd_temperature().await.ok(),
        );
        if let Some(temp) = setpoint {
            self.camera.set_ccd_temperature(temp).await.map_err(own)?;
        }
        self.camera.set_cooler_on(enabled).await.map_err(own)
    }

    async fn get_temperature(&self) -> Result<f64, DriverError> {
        self.camera.ccd_temperature().await.map_err(own)
    }

    async fn get_cooler_power(&self) -> Result<f64, DriverError> {
        self.camera.cooler_power().await.map_err(own)
    }

    async fn set_gain(&mut self, gain: i32) -> Result<(), DriverError> {
        let wire = self.camera.controls().await.gain.to_wire(gain, "Gain")?;
        self.camera.set_gain(wire).await.map_err(own)
    }

    async fn get_gain(&self) -> Result<i32, DriverError> {
        let wire = self.camera.gain().await.map_err(own)?;
        Ok(self.camera.controls().await.gain.from_wire(wire))
    }

    async fn set_offset(&mut self, offset: i32) -> Result<(), DriverError> {
        let wire = self
            .camera
            .controls()
            .await
            .offset
            .to_wire(offset, "Offset")?;
        self.camera.set_offset(wire).await.map_err(own)
    }

    async fn get_offset(&self) -> Result<i32, DriverError> {
        let wire = self.camera.offset().await.map_err(own)?;
        Ok(self.camera.controls().await.offset.from_wire(wire))
    }

    async fn set_binning(&mut self, bin_x: i32, bin_y: i32) -> Result<(), DriverError> {
        self.camera.set_bin_x(bin_x).await.map_err(own)?;
        self.camera.set_bin_y(bin_y).await.map_err(own)
    }

    async fn get_binning(&self) -> Result<(i32, i32), DriverError> {
        Ok((
            self.camera.bin_x().await.map_err(own)?,
            self.camera.bin_y().await.map_err(own)?,
        ))
    }

    /// The frame is set with every exposure, from its own parameters.
    async fn set_subframe(&mut self, _subframe: Option<SubFrame>) -> Result<(), DriverError> {
        Err(DriverError::NotSupported)
    }

    /// Not kept; see `describe` and `report`.
    fn get_sensor_info(&self) -> SensorInfo {
        SensorInfo::default()
    }

    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, DriverError> {
        Ok(self
            .camera
            .readout_modes()
            .await
            .map_err(own)?
            .into_iter()
            .enumerate()
            .map(|(index, name)| ReadoutMode {
                name,
                description: String::new(),
                // Why: a camera has a handful of readout modes.
                index: index as i32,
                gain_min: None,
                gain_max: None,
                offset_min: None,
                offset_max: None,
            })
            .collect())
    }

    async fn set_readout_mode(&mut self, mode: &ReadoutMode) -> Result<(), DriverError> {
        self.camera.set_readout_mode(mode.index).await.map_err(own)
    }

    async fn get_iso_speeds(&self) -> Result<Vec<i32>, DriverError> {
        Ok(self.camera.controls().await.gain.iso_speeds())
    }

    async fn get_vendor_features(&self) -> Result<VendorFeatures, DriverError> {
        Ok(VendorFeatures::default())
    }

    async fn get_gain_range(&self) -> Result<(i32, i32), DriverError> {
        Ok((
            self.camera.gain_min().await.map_err(own)?,
            self.camera.gain_max().await.map_err(own)?,
        ))
    }

    async fn get_offset_range(&self) -> Result<(i32, i32), DriverError> {
        Ok((
            self.camera.offset_min().await.map_err(own)?,
            self.camera.offset_max().await.map_err(own)?,
        ))
    }
}
