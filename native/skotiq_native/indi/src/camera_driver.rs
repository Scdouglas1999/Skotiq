//! An INDI CCD as a camera driver.
//!
//! `IndiCamera` is a name on its server's shared connection, so a value made
//! for one call is the same camera as any other.

use crate::frame::decode_frame;
use crate::protocol::names::*;
use crate::{CcdFrameType, IndiCamera, IndiClient, IndiError, IndiPropertyType};
use async_trait::async_trait;
use skotiq_device::{
    BayerPattern, CameraCapabilities, CameraDescription, CameraDriver, CameraReport, CameraState,
    CameraStatus, DeviceDriver, DriverError, ExposureParams, FrameType, ImageData, ImageMetadata,
    ReadoutMode, SensorInfo, SubFrame, Vendor, VendorFeatures, UNKNOWN_CAMERA_SETTING,
};

impl std::fmt::Debug for IndiCamera {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("IndiCamera").field(&self.device_name()).finish()
    }
}

/// A failed operation in the driver's own words. Whoever shows it reads its
/// kind from the INDI error inside.
fn own(error: IndiError) -> DriverError {
    DriverError::Backend(Box::new(error))
}

fn failed(what: &str, error: IndiError) -> DriverError {
    let words = format!("{what}: {error}");
    match DriverError::from(error) {
        DriverError::NotConnected => DriverError::NotConnected,
        DriverError::Disconnected => DriverError::Disconnected,
        DriverError::NotSupported => DriverError::NotSupported,
        DriverError::Timeout(_) => DriverError::Timeout(words),
        DriverError::InvalidParameter(_) => DriverError::InvalidParameter(words),
        _ => DriverError::Backend(words.into()),
    }
}

/// Whether the word a driver puts in `CCD_SENSOR_TYPE` names a colour sensor.
fn names_a_colour_sensor(sensor_type: &str) -> bool {
    let word = sensor_type.to_ascii_lowercase();
    ["color", "colour", "bayer", "cfa", "rgb", "osc"]
        .iter()
        .any(|colour| word.contains(colour))
}

/// A read mode is named by its label, or by its element when the driver
/// gives it no label.
fn mode_name(mode: crate::IndiReadoutMode) -> String {
    if mode.label.is_empty() {
        mode.element
    } else {
        mode.label
    }
}

impl IndiCamera {
    /// The sensor from `CCD_INFO`, which every CCD driver defines, and its
    /// colour from `CCD_CFA` and `CCD_SENSOR_TYPE`, which a mono one omits.
    async fn sensor(&self, client: &IndiClient) -> Result<SensorInfo, DriverError> {
        let device = self.device_name();
        let info = |element: &'static str, what: &'static str| async move {
            client
                .get_number(device, CCD_INFO, element)
                .await
                .ok_or_else(|| self.missing(&format!("CCD_INFO.{element}"), what))
        };
        // Why: INDI numbers are f64 on the wire; these are whole pixel
        // counts and bit depths.
        let width = info(CCD_MAX_X, "sensor width").await? as u32;
        let height = info(CCD_MAX_Y, "sensor height").await? as u32;
        let pixel_size_x = info(CCD_PIXEL_SIZE_X, "pixel size").await?;
        let pixel_size_y = info(CCD_PIXEL_SIZE_Y, "pixel size").await?;
        let bit_depth = info(CCD_BITSPERPIXEL, "ADU scaling").await? as u32;
        if bit_depth == 0 {
            return Err(DriverError::Backend(
                format!("INDI camera {device} reported invalid CCD_INFO.CCD_BITSPERPIXEL=0.")
                    .into(),
            ));
        }
        let max_adu = match client
            .get_number(device, CCD_MAX_PIXEL_VALUE, CCD_MAX_PIXEL_VALUE)
            .await
        {
            Some(value) => Some(value),
            None => client.get_number(device, CCD_INFO, CCD_MAX_PIXEL).await,
        };
        let max_adu = match max_adu {
            Some(value) => value.max(0.0) as u32,
            None if bit_depth >= 32 => u32::MAX,
            None => (1u32 << bit_depth) - 1,
        };
        let cfa = client.get_property_value(device, CCD_CFA, CFA_TYPE).await;
        let colour_word = self
            .sensor_type(client)
            .await
            .is_some_and(|word| names_a_colour_sensor(&word));
        Ok(SensorInfo {
            width,
            height,
            pixel_size_x,
            pixel_size_y,
            max_adu,
            bit_depth,
            color: cfa.is_some() || colour_word,
            bayer_pattern: cfa.as_deref().and_then(BayerPattern::from_fits_name),
            saturation_adu: None,
        })
    }

    /// The element that is On in `CCD_SENSOR_TYPE`.
    async fn sensor_type(&self, client: &IndiClient) -> Option<String> {
        let device = self.device_name();
        let prop = client.get_property(device, CCD_SENSOR_TYPE).await?;
        for element in prop.elements {
            if client
                .get_switch(device, CCD_SENSOR_TYPE, &element)
                .await
                .unwrap_or(false)
            {
                return Some(element);
            }
        }
        None
    }

    fn missing(&self, element: &str, what: &str) -> DriverError {
        DriverError::Backend(
            format!(
                "INDI camera {} missing required property {element}; cannot determine {what}.",
                self.device_name()
            )
            .into(),
        )
    }

    /// `CCD_FRAME_TYPE` for a frame kind; a dark flat is a dark to the
    /// camera.
    fn frame_type(kind: FrameType) -> CcdFrameType {
        match kind {
            FrameType::Light => CcdFrameType::Light,
            FrameType::Dark | FrameType::DarkFlat => CcdFrameType::Dark,
            FrameType::Flat => CcdFrameType::Flat,
            FrameType::Bias => CcdFrameType::Bias,
        }
    }
}

#[async_trait]
impl DeviceDriver for IndiCamera {
    fn id(&self) -> &str {
        self.device_name()
    }

    fn name(&self) -> &str {
        self.device_name()
    }

    fn vendor(&self) -> Vendor {
        Vendor::Indi
    }

    /// A value of this type is a device that was connected;
    /// [`CameraDriver::heartbeat`] asks the server whether it still is.
    fn is_connected(&self) -> bool {
        true
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        IndiCamera::connect(self).await.map_err(own)
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        IndiCamera::disconnect(self).await.map_err(own)
    }
}

#[async_trait]
impl CameraDriver for IndiCamera {
    /// Not kept; see `describe`.
    fn capabilities(&self) -> CameraCapabilities {
        CameraCapabilities::default()
    }

    async fn heartbeat(&self) -> Result<bool, DriverError> {
        self.check().await.map_err(own)
    }

    async fn report(&self) -> Result<CameraReport, DriverError> {
        let device = self.device_name();
        let client = self.client().read().await;
        let sensor_temp = client
            .get_number(device, CCD_TEMPERATURE, CCD_TEMPERATURE_VALUE)
            .await;
        let cooler_on = client.get_switch(device, CCD_COOLER, COOLER_ON).await;
        let bin_x = client
            .get_number(device, CCD_BINNING, HOR_BIN)
            .await
            .ok_or_else(|| self.missing("CCD_BINNING.HOR_BIN", "current binning"))?;
        let bin_y = client
            .get_number(device, CCD_BINNING, VER_BIN)
            .await
            .ok_or_else(|| self.missing("CCD_BINNING.VER_BIN", "current binning"))?;
        // CCD_EXPOSURE is Busy while the camera exposes. Its value is the
        // time left during an exposure, but at rest a driver may leave the
        // last or the default duration in it.
        if !client.has_property(device, CCD_EXPOSURE).await {
            return Err(self.missing("CCD_EXPOSURE.CCD_EXPOSURE_VALUE", "camera state"));
        }
        let exposing = client.is_property_busy(device, CCD_EXPOSURE).await;
        let sensor = self.sensor(&client).await?;
        let gain = match client.get_number(device, CCD_GAIN, GAIN).await {
            Some(value) => Some(value),
            None => client.get_number(device, CCD_CONTROLS, CONTROLS_GAIN).await,
        };
        let offset = client.get_number(device, CCD_OFFSET, OFFSET).await;
        let cooler_power = client
            .get_number(device, CCD_COOLER_POWER, CCD_COOLER_VALUE)
            .await;
        Ok(CameraReport {
            status: CameraStatus {
                state: if exposing {
                    CameraState::Exposing
                } else {
                    CameraState::Idle
                },
                sensor_temp,
                cooler_power,
                target_temp: None,
                cooler_on,
                gain: gain.map_or(0, |v| v as i32),
                offset: offset.map_or(0, |v| v as i32),
                bin_x: bin_x as i32,
                bin_y: bin_y as i32,
                exposure_remaining: None,
            },
            sensor,
            can_cool: cooler_on.is_some(),
            can_set_gain: gain.is_some(),
            can_set_offset: offset.is_some(),
        })
    }

    async fn get_status(&self) -> Result<CameraStatus, DriverError> {
        Ok(self.report().await?.status)
    }

    /// From the properties the driver defines. The set-point range is the
    /// `CCD_TEMPERATURE` limits the driver also clamps a set-point to.
    async fn describe(&self) -> CameraDescription {
        let device = self.device_name();
        let properties = crate::kind::defined_properties(self.client(), device).await;
        let defines = |name: &str| properties.iter().any(|p| p.name == name);
        let max_bin_x = self.try_get_max_bin_x().await.ok().flatten().unwrap_or(0);
        let max_bin_y = self.try_get_max_bin_y().await.ok().flatten().unwrap_or(0);
        let readout_modes = CameraDriver::get_readout_modes(self)
            .await
            .unwrap_or_default();
        let gain_range = IndiCamera::get_gain_range(self).await;
        let client = self.client().read().await;
        let sensor = self.sensor(&client).await.unwrap_or_else(|e| {
            tracing::warn!("INDI camera {device} did not describe its sensor: {e}");
            SensorInfo::default()
        });
        let sensor_type = self.sensor_type(&client).await;
        let cooler_temp_range = client
            .get_number_limits(device, CCD_TEMPERATURE, CCD_TEMPERATURE_VALUE)
            .await
            .and_then(|limits| Some((limits.min?, limits.max?)));
        drop(client);
        CameraDescription {
            capabilities: CameraCapabilities {
                can_cool: defines(CCD_COOLER) || defines(CCD_TEMPERATURE),
                can_set_gain: defines(CCD_GAIN) || defines(CCD_CONTROLS),
                can_set_offset: defines(CCD_OFFSET),
                can_set_binning: defines(CCD_BINNING),
                can_subframe: defines(CCD_FRAME),
                has_shutter: false,
                has_guider_port: false,
                max_bin_x,
                max_bin_y,
                supports_readout_modes: !readout_modes.is_empty(),
            },
            sensor,
            gain_range,
            offset_range: None,
            iso_speeds: Vec::new(),
            readout_modes,
            cooler_temp_range,
            exposure_range: None,
            can_abort_exposure: defines(CCD_ABORT_EXPOSURE),
            can_stop_exposure: false,
            can_asymmetric_bin: max_bin_x != max_bin_y,
            sensor_type,
        }
    }

    /// Gain and offset are written when asked for; a camera without them, or
    /// one that refuses the value, exposes at its current setting. Then the
    /// binning, the frame (the whole sensor in binned pixels without a
    /// subframe), the frame type, and the exposure.
    async fn start_exposure(&mut self, params: ExposureParams) -> Result<(), DriverError> {
        let device = self.device_name().to_string();
        let mut client = self.client().write().await;
        for (value, element, what) in [
            (params.gain, CONTROLS_GAIN, "gain"),
            (params.offset, CONTROLS_OFFSET, "offset"),
        ] {
            let Some(value) = value else { continue };
            if let Err(e) = client
                .set_number(&device, CCD_CONTROLS, element, f64::from(value))
                .await
            {
                tracing::warn!(
                    "Failed to set INDI camera {what} (device may not support it): {e}"
                );
            }
        }
        client
            .set_number(&device, CCD_BINNING, HOR_BIN, f64::from(params.bin_x))
            .await
            .map_err(|e| failed("Failed to set INDI camera horizontal binning", e))?;
        client
            .set_number(&device, CCD_BINNING, VER_BIN, f64::from(params.bin_y))
            .await
            .map_err(|e| failed("Failed to set INDI camera vertical binning", e))?;
        let (x, y, width, height) = match &params.subframe {
            Some(roi) => (
                f64::from(roi.start_x),
                f64::from(roi.start_y),
                f64::from(roi.width),
                f64::from(roi.height),
            ),
            None => {
                let mut size = [0.0; 2];
                for (side, element) in size.iter_mut().zip([CCD_MAX_X, CCD_MAX_Y]) {
                    *side = client
                        .get_number(&device, CCD_INFO, element)
                        .await
                        .filter(|value| value.is_finite() && *value > 0.0)
                        .ok_or_else(|| {
                            DriverError::Backend(
                                format!(
                                    "INDI camera did not report {element} for full-frame reset"
                                )
                                .into(),
                            )
                        })?;
                }
                (
                    0.0,
                    0.0,
                    size[0] / f64::from(params.bin_x),
                    size[1] / f64::from(params.bin_y),
                )
            }
        };
        client
            .set_numbers(
                &device,
                CCD_FRAME,
                &[("X", x), ("Y", y), (WIDTH, width), (HEIGHT, height)],
            )
            .await
            .map_err(|e| failed("Failed to set INDI camera frame geometry", e))?;
        // A camera with a shutter keeps it closed for a dark or a bias only
        // when it is told the frame type.
        if client.has_property(&device, CCD_FRAME_TYPE).await {
            drop(client);
            if let Err(e) = self.set_frame_type(Self::frame_type(params.frame_type)).await {
                tracing::warn!(
                    "INDI camera {device} refused frame type {:?}: {e}",
                    params.frame_type
                );
            }
            client = self.client().write().await;
        }
        // A frame kept from an earlier exposure is not this one's.
        for element in [CCD1, CCD2] {
            client.clear_blob(&device, element, element).await;
        }
        client
            .set_number(&device, CCD_EXPOSURE, CCD_EXPOSURE_VALUE, params.duration_secs)
            .await
            .map_err(own)
    }

    async fn abort_exposure(&mut self) -> Result<(), DriverError> {
        IndiCamera::abort_exposure(self).await.map_err(own)
    }

    async fn is_exposure_complete(&self) -> Result<bool, DriverError> {
        let client = self.client().read().await;
        if let Some(left) = client
            .get_number(self.device_name(), CCD_EXPOSURE, CCD_EXPOSURE_VALUE)
            .await
        {
            return Ok(left <= 0.0);
        }
        if client
            .is_property_busy(self.device_name(), CCD_EXPOSURE)
            .await
        {
            return Ok(false);
        }
        Err(DriverError::Backend(
            format!(
                "INDI camera {} exposure status is unavailable (missing CCD_EXPOSURE_VALUE)",
                self.device_name()
            )
            .into(),
        ))
    }

    async fn download_image(&mut self) -> Result<ImageData, DriverError> {
        let data = self.read_frame().await.map_err(own)?;
        let device = self.device_name();
        // Only a BLOB that does not say its own size is given the sensor's.
        let sensor = (
            self.get_sensor_width().await.map_or(1920, |w| w as u32),
            self.get_sensor_height().await.map_or(1080, |h| h as u32),
        );
        let (bin_x, bin_y) = match self
            .get_binning_or_default(std::time::Duration::from_millis(0))
            .await
        {
            Ok(binning) => binning,
            Err(e) => {
                tracing::warn!("Failed to read INDI binning for {device}: {e}. Using (1, 1).");
                (1, 1)
            }
        };
        // A read that fails is recorded as unknown, not as 0: a 0 would be
        // taken for the camera's setting and written into the frame's header
        // in place of the one the exposure was configured with.
        let setting = |read: Result<i32, IndiError>, what: &str| match read {
            Ok(value) => value,
            Err(e) => {
                tracing::warn!(
                    "Failed to read INDI {what} for {device}: {e}. Recording it as unknown so \
                     the configured {what} is used instead."
                );
                UNKNOWN_CAMERA_SETTING
            }
        };
        let gain = setting(self.get_gain().await, "gain");
        let offset = setting(self.get_offset().await, "offset");
        let frame = decode_frame(&data, sensor).map_err(own)?;
        Ok(ImageData {
            width: frame.width,
            height: frame.height,
            data: frame.pixels,
            bits_per_pixel: 16,
            bayer_pattern: None,
            metadata: ImageMetadata {
                exposure_time: 0.0,
                gain,
                offset,
                bin_x,
                bin_y,
                temperature: self.get_temperature().await.ok(),
                timestamp: chrono::Utc::now(),
                subframe: None,
                readout_mode: None,
                vendor_data: VendorFeatures::default(),
                camera_file: None,
            },
        })
    }

    /// The cooler switch, then the set-point when one is named.
    async fn set_cooler(
        &mut self,
        enabled: bool,
        target_temp: Option<f64>,
    ) -> Result<(), DriverError> {
        let device = self.device_name().to_string();
        let mut client = self.client().write().await;
        let element = if enabled { COOLER_ON } else { COOLER_OFF };
        client
            .set_switch(&device, CCD_COOLER, element, true)
            .await
            .map_err(own)?;
        if let Some(temp) = target_temp {
            client
                .set_number(&device, CCD_TEMPERATURE, CCD_TEMPERATURE_VALUE, temp)
                .await
                .map_err(own)?;
        }
        Ok(())
    }

    async fn get_temperature(&self) -> Result<f64, DriverError> {
        IndiCamera::get_temperature(self).await.map_err(own)
    }

    async fn get_cooler_power(&self) -> Result<f64, DriverError> {
        IndiCamera::get_cooler_power(self)
            .await
            .ok_or(DriverError::NotSupported)
    }

    async fn set_gain(&mut self, gain: i32) -> Result<(), DriverError> {
        let device = self.device_name().to_string();
        self.client()
            .write()
            .await
            .set_number(&device, CCD_CONTROLS, CONTROLS_GAIN, f64::from(gain))
            .await
            .map_err(own)
    }

    async fn get_gain(&self) -> Result<i32, DriverError> {
        IndiCamera::get_gain(self).await.map_err(own)
    }

    async fn set_offset(&mut self, offset: i32) -> Result<(), DriverError> {
        let device = self.device_name().to_string();
        self.client()
            .write()
            .await
            .set_number(&device, CCD_CONTROLS, CONTROLS_OFFSET, f64::from(offset))
            .await
            .map_err(own)
    }

    async fn get_offset(&self) -> Result<i32, DriverError> {
        IndiCamera::get_offset(self).await.map_err(own)
    }

    async fn set_binning(&mut self, bin_x: i32, bin_y: i32) -> Result<(), DriverError> {
        let device = self.device_name().to_string();
        let mut client = self.client().write().await;
        client
            .set_number(&device, CCD_BINNING, HOR_BIN, f64::from(bin_x))
            .await
            .map_err(own)?;
        client
            .set_number(&device, CCD_BINNING, VER_BIN, f64::from(bin_y))
            .await
            .map_err(own)
    }

    async fn get_binning(&self) -> Result<(i32, i32), DriverError> {
        match self.try_get_binning().await.map_err(own)? {
            Some(binning) => Ok(binning),
            None => Err(self.missing("CCD_BINNING", "current binning")),
        }
    }

    async fn set_subframe(&mut self, subframe: Option<SubFrame>) -> Result<(), DriverError> {
        match subframe {
            Some(roi) => self
                .set_frame(
                    roi.start_x as i32,
                    roi.start_y as i32,
                    roi.width as i32,
                    roi.height as i32,
                )
                .await
                .map_err(own),
            None => self.reset_frame().await.map_err(own),
        }
    }

    /// Not kept; see `describe` and `report`.
    fn get_sensor_info(&self) -> SensorInfo {
        SensorInfo::default()
    }

    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, DriverError> {
        Ok(IndiCamera::get_readout_modes(self)
            .await
            .into_iter()
            .enumerate()
            .map(|(index, mode)| ReadoutMode {
                name: mode_name(mode),
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

    /// The mode is the element at `mode.index` of the driver's readout
    /// switch, whichever of the three names it goes by. A camera without one
    /// has one mode, and setting it changes nothing.
    async fn set_readout_mode(&mut self, mode: &ReadoutMode) -> Result<(), DriverError> {
        let device = self.device_name().to_string();
        let mut client = self.client().write().await;
        let properties = client.get_properties(&device).await;
        let switch = [CCD_READ_MODE, CCD_READOUT_SPEED, READOUT_QUALITY]
            .into_iter()
            .find_map(|name| {
                properties
                    .iter()
                    .find(|p| p.name == name && p.property_type == IndiPropertyType::Switch)
            });
        let Some(switch) = switch else {
            tracing::debug!("No readout mode switch property found for INDI camera {device}");
            return Ok(());
        };
        let element = usize::try_from(mode.index)
            .ok()
            .and_then(|index| switch.elements.get(index))
            .ok_or_else(|| {
                DriverError::InvalidParameter(format!(
                    "Readout mode index {} out of range (camera has {} modes)",
                    mode.index,
                    switch.elements.len()
                ))
            })?
            .clone();
        client
            .set_switch(&device, &switch.name, &element, true)
            .await
            .map_err(|e| failed("Failed to set INDI readout mode", e))
    }

    async fn get_vendor_features(&self) -> Result<VendorFeatures, DriverError> {
        Ok(VendorFeatures::default())
    }

    async fn get_gain_range(&self) -> Result<(i32, i32), DriverError> {
        IndiCamera::get_gain_range(self)
            .await
            .ok_or(DriverError::NotSupported)
    }

    async fn get_offset_range(&self) -> Result<(i32, i32), DriverError> {
        Err(DriverError::NotSupported)
    }
}

#[cfg(test)]
mod description_tests {
    use super::*;

    #[test]
    fn a_sensor_type_names_colour_only_in_colour_words() {
        assert!(names_a_colour_sensor("COLOR"));
        assert!(names_a_colour_sensor("Bayer RGGB"));
        assert!(names_a_colour_sensor("OSC"));
        assert!(!names_a_colour_sensor("MONOCHROME"));
        assert!(!names_a_colour_sensor("CCD_SENSOR_MONO"));
    }

    #[test]
    fn a_read_mode_without_a_label_is_named_by_its_element() {
        let mode = |element: &str, label: &str| crate::IndiReadoutMode {
            element: element.to_string(),
            label: label.to_string(),
        };
        assert_eq!(mode_name(mode("MODE_0", "High Gain")), "High Gain");
        assert_eq!(mode_name(mode("MODE_1", "")), "MODE_1");
    }
}
