//! An INDI camera on its server's shared connection.

use super::{no_preview, Camera, ExposureAborts};
use crate::device::DriverType;
use crate::device_capabilities::DeviceCapabilities;
use crate::device_manager::ops::camera::{parse_fits_card_u32, UNKNOWN_CAMERA_SETTING};
use crate::device_manager::rig::RigDriver;
use crate::dispatch::DeviceOpError;
use crate::error::SkotiqError;
use async_trait::async_trait;
use skotiq_device::{DriverError, ImageData, SubFrame};
use skotiq_indi::names as indi;
use std::sync::Arc;
use tokio::sync::RwLock;
use tracing::warn;

pub(crate) struct IndiCameraHandle {
    device_id: String,
    client: Arc<RwLock<skotiq_indi::IndiClient>>,
    device_name: String,
    aborts: ExposureAborts,
}

impl IndiCameraHandle {
    pub(crate) fn new(
        device_id: &str,
        client: Arc<RwLock<skotiq_indi::IndiClient>>,
        device_name: &str,
    ) -> Self {
        Self {
            device_id: device_id.to_string(),
            client,
            device_name: device_name.to_string(),
            aborts: ExposureAborts::new(),
        }
    }
}

#[async_trait]
impl RigDriver for IndiCameraHandle {
    /// Waits for the driver to confirm the disconnect.
    async fn disconnect(&self) -> Result<(), DriverError> {
        Ok(self
            .client
            .write()
            .await
            .disconnect_and_confirm(&self.device_name)
            .await?)
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        self.client
            .write()
            .await
            .check_device(&self.device_name)
            .await
            .map_err(|e| e.to_string())
    }
}

#[async_trait]
impl Camera for IndiCameraHandle {
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
        _frame_type: skotiq_device::FrameType,
    ) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let client = &self.client;
        let device_name = self.device_name.clone();
        tracing::info!("DeviceManager: Starting INDI exposure on {}", device_name);
        let mut locked_client = client.write().await;
        // Set gain/offset if the node specified them (None =
        // leave unchanged). Some INDI cameras don't support
        // these, so warn but continue.
        if let Some(g) = gain {
            if let Err(e) = locked_client
                .set_number(
                    &device_name,
                    indi::CCD_CONTROLS,
                    indi::CONTROLS_GAIN,
                    g as f64,
                )
                .await
            {
                tracing::warn!(
                    "Failed to set INDI camera gain (device may not support it): {}",
                    e
                );
            }
        }
        if let Some(o) = offset {
            if let Err(e) = locked_client
                .set_number(
                    &device_name,
                    indi::CCD_CONTROLS,
                    indi::CONTROLS_OFFSET,
                    o as f64,
                )
                .await
            {
                tracing::warn!(
                    "Failed to set INDI camera offset (device may not support it): {}",
                    e
                );
            }
        }
        // Set binning - propagate errors since binning is typically supported
        locked_client
            .set_number(&device_name, indi::CCD_BINNING, indi::HOR_BIN, bin_x as f64)
            .await
            .map_err(|e| {
                DeviceOpError::caused_by(
                    Some(device_id.to_string()),
                    format!("Failed to set INDI camera horizontal binning: {}", e),
                    e,
                )
            })?;
        locked_client
            .set_number(&device_name, indi::CCD_BINNING, indi::VER_BIN, bin_y as f64)
            .await
            .map_err(|e| {
                DeviceOpError::caused_by(
                    Some(device_id.to_string()),
                    format!("Failed to set INDI camera vertical binning: {}", e),
                    e,
                )
            })?;
        let (frame_x, frame_y, frame_width, frame_height) = if let Some(ref roi) = subframe {
            (
                f64::from(roi.start_x),
                f64::from(roi.start_y),
                f64::from(roi.width),
                f64::from(roi.height),
            )
        } else {
            let sensor_width = locked_client
                .get_number(&device_name, indi::CCD_INFO, indi::CCD_MAX_X)
                .await
                .filter(|value| value.is_finite() && *value > 0.0)
                .ok_or_else(|| {
                    DeviceOpError::hardware(
                        Some(device_id.to_string()),
                        "INDI camera did not report CCD_MAX_X for full-frame reset",
                    )
                })?;
            let sensor_height = locked_client
                .get_number(&device_name, indi::CCD_INFO, indi::CCD_MAX_Y)
                .await
                .filter(|value| value.is_finite() && *value > 0.0)
                .ok_or_else(|| {
                    DeviceOpError::hardware(
                        Some(device_id.to_string()),
                        "INDI camera did not report CCD_MAX_Y for full-frame reset",
                    )
                })?;
            (
                0.0,
                0.0,
                sensor_width / f64::from(bin_x),
                sensor_height / f64::from(bin_y),
            )
        };
        locked_client
            .set_numbers(
                &device_name,
                indi::CCD_FRAME,
                &[
                    ("X", frame_x),
                    ("Y", frame_y),
                    (indi::WIDTH, frame_width),
                    (indi::HEIGHT, frame_height),
                ],
            )
            .await
            .map_err(|e| {
                DeviceOpError::caused_by(
                    Some(device_id.to_string()),
                    format!("Failed to set INDI camera frame geometry: {}", e),
                    e,
                )
            })?;
        locked_client
            .set_number(
                &device_name,
                indi::CCD_EXPOSURE,
                indi::CCD_EXPOSURE_VALUE,
                duration,
            )
            .await
            .map_err(DeviceOpError::from)
    }

    async fn is_exposure_complete(&self) -> Result<bool, DeviceOpError> {
        let device_id = self.device_id.as_str();
        let client = &self.client;
        let device_name = self.device_name.clone();
        let locked_client = client.read().await;
        // Check if exposure value is 0 (complete) - get_number returns Option
        if let Some(value) = locked_client
            .get_number(&device_name, indi::CCD_EXPOSURE, indi::CCD_EXPOSURE_VALUE)
            .await
        {
            return Ok(value <= 0.0);
        }
        if locked_client
            .is_property_busy(&device_name, indi::CCD_EXPOSURE)
            .await
        {
            return Ok(false);
        }
        Err(DeviceOpError::hardware(
            Some(device_id.to_string()),
            format!(
                "INDI camera {} exposure status is unavailable (missing CCD_EXPOSURE_VALUE)",
                device_name
            ),
        ))
    }

    async fn stop_exposure(&self) -> Result<(), DeviceOpError> {
        let client = &self.client;
        let device_name = self.device_name.clone();
        let mut locked_client = client.write().await;
        locked_client
            .set_switch(&device_name, indi::CCD_ABORT_EXPOSURE, indi::ABORT, true)
            .await
            .map_err(DeviceOpError::from)
    }

    async fn read_frame(&self) -> Result<ImageData, DeviceOpError> {
        let device_id = self.device_id.as_str();
        let client = &self.client;
        let device_name = self.device_name.clone();
        // Create an IndiCamera wrapper to handle BLOB download
        let camera = skotiq_indi::IndiCamera::new(Arc::clone(client), &device_name);

        // Subscribe to BLOB events BEFORE enable_blob + the
        // metadata round-trips below: the exposure may already
        // be completing, and a BLOB emitted during those reads
        // would otherwise be missed by a later subscription.
        let mut rx = {
            let locked_client = client.read().await;
            locked_client.subscribe()
        };

        // Enable BLOB transfer if not already enabled. A refused
        // enableBLOB means the image can never arrive on this
        // connection, and the only symptom downstream is the
        // 30-second "Timeout waiting for INDI image BLOB" below —
        // which reads as a slow camera. Name the real cause.
        if let Err(e) = camera.enable_blob().await {
            warn!(
                "Failed to enable INDI BLOB transfer for {}: {}. No image can \
                 be delivered on this connection until it succeeds.",
                device_id, e
            );
        }

        let width = match camera.get_sensor_width().await {
            Some(w) => w as u32,
            None => {
                warn!(
                    "Failed to read INDI sensor width for {}. Using default 1920.",
                    device_id
                );
                1920
            }
        };
        let height = match camera.get_sensor_height().await {
            Some(h) => h as u32,
            None => {
                warn!(
                    "Failed to read INDI sensor height for {}. Using default 1080.",
                    device_id
                );
                1080
            }
        };
        let (bin_x, bin_y) = match camera
            .get_binning_or_default(std::time::Duration::from_millis(0))
            .await
        {
            Ok(b) => b,
            Err(e) => {
                warn!(
                    "Failed to read INDI binning for {}: {}. Using default (1, 1).",
                    device_id, e
                );
                (1, 1)
            }
        };
        let temp = camera.get_temperature().await.ok();
        // A FAILED read must not masquerade as "gain 0": that 0 was
        // wrapped in Some() downstream, which short-circuited
        // `image_data.gain.or(config.gain)` and let it BEAT the
        // operator's configured gain — stamping GAIN=0 into every
        // frame's FITS header for the run and permanently breaking
        // dark/flat library matching, which keys on gain.
        // UNKNOWN_CAMERA_SETTING is mapped back to None at the
        // ImageMetadata boundary so the configured value wins.
        let gain = match camera.get_gain().await {
            Ok(g) => g,
            Err(e) => {
                warn!(
                    "Failed to read INDI gain for {}: {}. Recording it as \
                     unknown so the configured gain is used instead.",
                    device_id, e
                );
                UNKNOWN_CAMERA_SETTING
            }
        };
        let offset = match camera.get_offset().await {
            Ok(o) => o,
            Err(e) => {
                warn!(
                    "Failed to read INDI offset for {}: {}. Recording it as \
                     unknown so the configured offset is used instead.",
                    device_id, e
                );
                UNKNOWN_CAMERA_SETTING
            }
        };

        // Build an ImageData from a raw INDI image BLOB (FITS or
        // raw u16). Shared by the event path and the cached-BLOB
        // fallback below so both decode identically.
        let build_image = |data: Vec<u8>| -> ImageData {
            // The FITS header carries the frame's TRUE geometry in
            // the mandatory NAXIS1/NAXIS2 keywords; prefer them
            // over the CCD_INFO-derived guess. CCD_MAX_X/Y is the
            // full UNBINNED sensor, so at bin 2 the two disagree —
            // measured against a live INDI CCD simulator: CCD_INFO
            // says 1280x1024 while the BLOB says NAXIS1=640,
            // NAXIS2=512. Trusting CCD_INFO there builds an
            // ImageData claiming 1280x1024 around a 640x512 frame,
            // which fails validation outright; and when CCD_INFO is
            // unreadable the 1920x1080 fallback below silently
            // CROPS and re-strides the frame instead, because the
            // truncate() makes the downstream size check pass
            // tautologically.
            let mut fits_dims: Option<(u32, u32)> = None;
            let image_data = if data.starts_with(b"SIMPLE") {
                let mut off = 0;
                let mut naxis1: Option<u32> = None;
                let mut naxis2: Option<u32> = None;
                for chunk in data.chunks(80) {
                    off += 80;
                    if chunk.starts_with(b"NAXIS1") {
                        naxis1 = parse_fits_card_u32(chunk);
                    } else if chunk.starts_with(b"NAXIS2") {
                        naxis2 = parse_fits_card_u32(chunk);
                    }
                    if chunk.starts_with(b"END") {
                        off = ((off + 2879) / 2880) * 2880;
                        break;
                    }
                }
                if let (Some(w), Some(h)) = (naxis1, naxis2) {
                    if w > 0 && h > 0 {
                        fits_dims = Some((w, h));
                    }
                }
                let binary_data = &data[off.min(data.len())..];
                let mut pixels: Vec<u16> = Vec::with_capacity(binary_data.len() / 2);
                for chunk in binary_data.as_chunks::<2>().0.iter() {
                    pixels.push(u16::from_be_bytes([chunk[0], chunk[1]]));
                }
                pixels
            } else {
                let mut pixels: Vec<u16> = Vec::with_capacity(data.len() / 2);
                for chunk in data.as_chunks::<2>().0.iter() {
                    pixels.push(u16::from_le_bytes([chunk[0], chunk[1]]));
                }
                pixels
            };
            let (eff_width, eff_height) = match fits_dims {
                Some((w, h)) => {
                    if (w, h) != (width, height) {
                        tracing::info!(
                            "INDI {}: using FITS NAXIS {}x{} instead of \
                             CCD_INFO-derived {}x{} (binning/subframe)",
                            device_id,
                            w,
                            h,
                            width,
                            height
                        );
                    }
                    (w, h)
                }
                None => (width, height),
            };
            // Trim FITS block padding beyond width*height. Only ever
            // discards the tail padding now that the dimensions are
            // the frame's own; a SHORT buffer is left short so
            // validation can still catch it rather than being
            // silently reshaped.
            let expected_pixels = (eff_width as usize) * (eff_height as usize);
            let mut image_data = image_data;
            if image_data.len() > expected_pixels {
                image_data.truncate(expected_pixels);
            }
            ImageData {
                width: eff_width,
                height: eff_height,
                data: image_data,
                bits_per_pixel: 16,
                bayer_pattern: None,
                metadata: skotiq_device::ImageMetadata {
                    exposure_time: 0.0,
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
            }
        };

        // Wait for BLOB data with timeout (30 seconds)
        let timeout = std::time::Duration::from_secs(30);
        let start_time = std::time::Instant::now();

        loop {
            if start_time.elapsed() > timeout {
                return Err(DeviceOpError::hardware(
                    Some(device_id.to_string()),
                    "Timeout waiting for INDI image BLOB",
                ));
            }

            match tokio::time::timeout(std::time::Duration::from_secs(1), rx.recv()).await {
                Ok(Ok(event)) => match event {
                    skotiq_indi::IndiEvent::BlobReceived {
                        device,
                        element,
                        data,
                        ..
                    } if device == device_name
                        && (element == indi::CCD1 || element == indi::CCD2) =>
                    {
                        return Ok(build_image(data));
                    }
                    _ => {}
                },
                Ok(Err(_)) => {
                    return Err(DeviceOpError::hardware(
                        Some(device_id.to_string()),
                        "INDI event channel closed",
                    ));
                }
                Err(_) => {
                    // recv timed out; the reader may have stored
                    // the BLOB before we subscribed. Poll the
                    // cache before looping so a race can't hang.
                    let cached = {
                        let lc = client.read().await;
                        match lc.take_blob(&device_name, indi::CCD1, indi::CCD1).await {
                            Some(d) => Some(d),
                            None => lc.take_blob(&device_name, indi::CCD2, indi::CCD2).await,
                        }
                    };
                    if let Some(data) = cached {
                        return Ok(build_image(data));
                    }
                    continue;
                }
            }
        }
    }

    async fn status(&self) -> Result<crate::device::CameraStatus, DeviceOpError> {
        let device_id = self.device_id.as_str();
        let client = &self.client;
        let device_name = self.device_name.clone();
        let locked_client = client.read().await;

        // Query INDI camera properties
        let sensor_temp = locked_client
            .get_number(
                &device_name,
                indi::CCD_TEMPERATURE,
                indi::CCD_TEMPERATURE_VALUE,
            )
            .await;
        let cooler_state = locked_client
            .get_switch(&device_name, indi::CCD_COOLER, indi::COOLER_ON)
            .await;
        let has_cooler = cooler_state.is_some();
        let bin_x = locked_client
            .get_number(&device_name, indi::CCD_BINNING, indi::HOR_BIN)
            .await
            .map(|v| v as i32)
            .ok_or_else(|| {
                DeviceOpError::hardware(Some(device_id.to_string()), format!(
                    "INDI camera {} missing required property CCD_BINNING.HOR_BIN; cannot determine current binning.",
                    device_id
                ))
            })?;
        let bin_y = locked_client
            .get_number(&device_name, indi::CCD_BINNING, indi::VER_BIN)
            .await
            .map(|v| v as i32)
            .ok_or_else(|| {
                DeviceOpError::hardware(Some(device_id.to_string()), format!(
                    "INDI camera {} missing required property CCD_BINNING.VER_BIN; cannot determine current binning.",
                    device_id
                ))
            })?;
        let exposure_value = locked_client
            .get_number(&device_name, indi::CCD_EXPOSURE, indi::CCD_EXPOSURE_VALUE)
            .await;

        // Determine camera state based on exposure value
        let state = match exposure_value {
            Some(v) if v > 0.0 => crate::device::CameraState::Exposing,
            Some(_) => crate::device::CameraState::Idle,
            None => {
                return Err(DeviceOpError::hardware(Some(device_id.to_string()), format!(
                    "INDI camera {} missing required property CCD_EXPOSURE.CCD_EXPOSURE_VALUE; cannot determine camera state.",
                    device_id
                )))
            }
        };

        // Read sensor info from INDI CCD_INFO property.
        let sensor_width = locked_client
            .get_number(&device_name, indi::CCD_INFO, indi::CCD_MAX_X)
            .await
            .map(|v| v as u32)
            .ok_or_else(|| {
                DeviceOpError::hardware(Some(device_id.to_string()), format!(
                    "INDI camera {} missing required property CCD_INFO.CCD_MAX_X; cannot determine sensor width.",
                    device_id
                ))
            })?;
        let sensor_height = locked_client
            .get_number(&device_name, indi::CCD_INFO, indi::CCD_MAX_Y)
            .await
            .map(|v| v as u32)
            .ok_or_else(|| {
                DeviceOpError::hardware(Some(device_id.to_string()), format!(
                    "INDI camera {} missing required property CCD_INFO.CCD_MAX_Y; cannot determine sensor height.",
                    device_id
                ))
            })?;
        let pixel_size_x = locked_client
            .get_number(&device_name, indi::CCD_INFO, indi::CCD_PIXEL_SIZE_X)
            .await
            .ok_or_else(|| {
                DeviceOpError::hardware(Some(device_id.to_string()), format!(
                    "INDI camera {} missing required property CCD_INFO.CCD_PIXEL_SIZE_X; cannot determine pixel size.",
                    device_id
                ))
            })?;
        let pixel_size_y = locked_client
            .get_number(&device_name, indi::CCD_INFO, indi::CCD_PIXEL_SIZE_Y)
            .await
            .ok_or_else(|| {
                DeviceOpError::hardware(Some(device_id.to_string()), format!(
                    "INDI camera {} missing required property CCD_INFO.CCD_PIXEL_SIZE_Y; cannot determine pixel size.",
                    device_id
                ))
            })?;
        let bit_depth = locked_client
            .get_number(&device_name, indi::CCD_INFO, indi::CCD_BITSPERPIXEL)
            .await
            .map(|v| v as u32)
            .ok_or_else(|| {
                DeviceOpError::hardware(Some(device_id.to_string()), format!(
                    "INDI camera {} missing required property CCD_INFO.CCD_BITSPERPIXEL; cannot determine ADU scaling.",
                    device_id
                ))
            })?;
        if bit_depth == 0 {
            return Err(DeviceOpError::hardware(
                Some(device_id.to_string()),
                format!(
                    "INDI camera {} reported invalid CCD_INFO.CCD_BITSPERPIXEL=0.",
                    device_id
                ),
            ));
        }
        let gain_value = match locked_client
            .get_number(&device_name, indi::CCD_GAIN, indi::GAIN)
            .await
        {
            Some(value) => Some(value),
            None => {
                locked_client
                    .get_number(&device_name, indi::CCD_CONTROLS, indi::CONTROLS_GAIN)
                    .await
            }
        };
        let offset_value = locked_client
            .get_number(&device_name, indi::CCD_OFFSET, indi::OFFSET)
            .await;
        let gain = gain_value.map(|v| v as i32).unwrap_or(0);
        let offset = offset_value.map(|v| v as i32).unwrap_or(0);
        let cooler_power = locked_client
            .get_number(&device_name, indi::CCD_COOLER_POWER, indi::CCD_COOLER_VALUE)
            .await;
        let has_gain = gain_value.is_some();
        let has_offset = offset_value.is_some();
        let max_adu_from_driver = match locked_client
            .get_number(
                &device_name,
                indi::CCD_MAX_PIXEL_VALUE,
                indi::CCD_MAX_PIXEL_VALUE,
            )
            .await
        {
            Some(value) => Some(value),
            None => {
                locked_client
                    .get_number(&device_name, indi::CCD_INFO, indi::CCD_MAX_PIXEL)
                    .await
            }
        };
        let max_adu = if let Some(value) = max_adu_from_driver {
            value.max(0.0) as u32
        } else if bit_depth >= 32 {
            u32::MAX
        } else {
            (1u32 << bit_depth) - 1
        };

        Ok(crate::device::CameraStatus {
            connected: true,
            state,
            sensor_temp,
            cooler_power,
            target_temp: None,
            cooler_on: cooler_state,
            gain,
            offset,
            bin_x,
            bin_y,
            sensor_width,
            sensor_height,
            pixel_size_x,
            pixel_size_y,
            max_adu,
            saturation_adu: None,
            can_cool: has_cooler,
            can_set_gain: has_gain,
            can_set_offset: has_offset,
        })
    }

    async fn recommended_settings(
        &self,
    ) -> Result<skotiq_device::CameraRecommendedSettings, DeviceOpError> {
        Ok(skotiq_device::CameraRecommendedSettings::default())
    }

    async fn set_gain(&self, gain: i32) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let client = &self.client;
        let device_name = self.device_name.clone();
        let mut locked = client.write().await;
        locked
            .set_number(
                &device_name,
                indi::CCD_CONTROLS,
                indi::CONTROLS_GAIN,
                gain as f64,
            )
            .await
            .map_err(|e| {
                DeviceOpError::caused_by(
                    Some(device_id.to_string()),
                    format!("Failed to set INDI camera gain: {}", e),
                    e,
                )
            })?;
        Ok(())
    }

    async fn set_offset(&self, offset: i32) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let client = &self.client;
        let device_name = self.device_name.clone();
        let mut locked = client.write().await;
        locked
            .set_number(
                &device_name,
                indi::CCD_CONTROLS,
                indi::CONTROLS_OFFSET,
                offset as f64,
            )
            .await
            .map_err(|e| {
                DeviceOpError::caused_by(
                    Some(device_id.to_string()),
                    format!("Failed to set INDI camera offset: {}", e),
                    e,
                )
            })?;
        Ok(())
    }

    async fn set_binning(&self, bin_x: i32, bin_y: i32) -> Result<(), DeviceOpError> {
        let client = &self.client;
        let device_name = self.device_name.clone();
        let mut locked_client = client.write().await;
        locked_client
            .set_number(&device_name, indi::CCD_BINNING, indi::HOR_BIN, bin_x as f64)
            .await?;
        locked_client
            .set_number(&device_name, indi::CCD_BINNING, indi::VER_BIN, bin_y as f64)
            .await?;
        Ok(())
    }

    async fn set_readout_mode(&self, mode_index: i32) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let client = &self.client;
        let device_name = self.device_name.clone();
        let mut locked = client.write().await;
        // INDI cameras expose readout speed as a switch property.
        // Common property names: CCD_READ_MODE, CCD_READOUT_SPEED, READOUT_QUALITY
        let switch_props = [
            indi::CCD_READ_MODE,
            indi::CCD_READOUT_SPEED,
            indi::READOUT_QUALITY,
        ];
        let all_props = locked.get_properties(&device_name).await;
        for prop_name in &switch_props {
            if let Some(prop) = all_props.iter().find(|p| {
                p.name == *prop_name && p.property_type == skotiq_indi::IndiPropertyType::Switch
            }) {
                if (mode_index as usize) < prop.elements.len() {
                    let element = prop.elements[mode_index as usize].clone();
                    locked
                        .set_switch(&device_name, prop_name, &element, true)
                        .await
                        .map_err(|e| {
                            DeviceOpError::caused_by(
                                Some(device_id.to_string()),
                                format!("Failed to set INDI readout mode: {}", e),
                                e,
                            )
                        })?;
                    return Ok(());
                } else {
                    return Err(DeviceOpError::invalid_parameter(format!(
                        "Readout mode index {} out of range (camera has {} modes)",
                        mode_index,
                        prop.elements.len()
                    )));
                }
            }
        }
        // No readout mode property found - not an error, many INDI cameras lack this
        tracing::debug!(
            "No readout mode switch property found for INDI camera {}",
            device_name
        );
        Ok(())
    }

    async fn set_cooler(
        &self,
        enabled: bool,
        target_temp: Option<f64>,
    ) -> Result<(), DeviceOpError> {
        let client = &self.client;
        let device_name = self.device_name.clone();
        let mut locked_client = client.write().await;
        let switch_element = if enabled {
            indi::COOLER_ON
        } else {
            indi::COOLER_OFF
        };
        locked_client
            .set_switch(&device_name, indi::CCD_COOLER, switch_element, true)
            .await?;
        if let Some(temp) = target_temp {
            locked_client
                .set_number(
                    &device_name,
                    indi::CCD_TEMPERATURE,
                    indi::CCD_TEMPERATURE_VALUE,
                    temp,
                )
                .await?;
        }
        Ok(())
    }

    async fn capture_preview(&self) -> Result<Vec<u8>, DeviceOpError> {
        Err(no_preview(DriverType::Indi, &self.device_id))
    }

    async fn capabilities(&self, device_id: &str) -> Result<DeviceCapabilities, SkotiqError> {
        crate::device_capabilities::indi_capabilities(&self.client, &self.device_name, device_id)
            .await
    }
}
