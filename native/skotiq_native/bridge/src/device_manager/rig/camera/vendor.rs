//! A vendor SDK camera.

use super::{Camera, ExposureAborts};
use crate::device_capabilities::{CameraCapabilities, DeviceCapabilities};
use crate::device_manager::identity::DeviceIdentity;
use crate::device_manager::rig::{Exclusive, RigDriver};
use crate::device_manager::DeviceManager;
use crate::dispatch::DeviceOpError;
use crate::error::SkotiqError;
use async_trait::async_trait;
use skotiq_device::{
    CameraDriver, DriverError, ExposureAbort, ExposureParams, ImageData, SubFrame,
};
use std::sync::Arc;

pub(crate) struct VendorCamera {
    device_id: String,
    driver: Exclusive<Box<dyn CameraDriver + Send + Sync>>,
    aborts: ExposureAborts,
    /// The driver's way to give up a frame read in flight, when it has one.
    give_up: Option<Arc<dyn ExposureAbort>>,
}

impl VendorCamera {
    pub(crate) fn new(device_id: &str, driver: Box<dyn CameraDriver + Send + Sync>) -> Self {
        Self {
            device_id: device_id.to_string(),
            give_up: driver.exposure_abort(),
            driver: Exclusive::new(driver),
            aborts: ExposureAborts::new(),
        }
    }
}

#[async_trait]
impl RigDriver for VendorCamera {
    async fn disconnect(&self) -> Result<(), DriverError> {
        self.driver.write().await.disconnect().await
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        let camera = self.driver.read().await;
        if !camera.is_connected() {
            return Ok(false);
        }
        // The status read, because every camera answers it; a body
        // without a thermometer (every DSLR and mirrorless camera)
        // answers a temperature read "not supported".
        camera
            .get_status()
            .await
            .map(|_| true)
            .map_err(|e| format!("Native camera liveness probe failed: {}", e))
    }
}

#[async_trait]
impl Camera for VendorCamera {
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
        let mut driver = self.driver.write().await;
        let camera = &mut *driver;
        tracing::info!("DeviceManager: Starting Native SDK exposure");
        let params = ExposureParams {
            duration_secs: duration,
            bin_x,
            bin_y,
            gain,
            offset,
            subframe,
            readout_mode: None,
            frame_type,
        };
        camera.start_exposure(params).await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!(
                    "Failed to start native SDK camera exposure on {}: {}",
                    device_id, e
                ),
                e,
            )
        })
    }

    async fn is_exposure_complete(&self) -> Result<bool, DeviceOpError> {
        let driver = self.driver.read().await;
        let camera = &*driver;
        camera
            .is_exposure_complete()
            .await
            .map_err(DeviceOpError::from)
    }

    async fn stop_exposure(&self) -> Result<(), DeviceOpError> {
        // Ahead of the device lock, which a frame read in flight holds.
        if let Some(give_up) = &self.give_up {
            give_up.request();
        }
        let mut driver = self.driver.write().await;
        let camera = &mut *driver;
        camera.abort_exposure().await.map_err(DeviceOpError::from)
    }

    async fn read_frame(&self) -> Result<ImageData, DeviceOpError> {
        let mut driver = self.driver.write().await;
        let camera = &mut *driver;
        camera.download_image().await.map_err(DeviceOpError::from)
    }

    async fn capture_preview(&self) -> Result<Vec<u8>, DeviceOpError> {
        let driver = self.driver.read().await;
        let camera = &*driver;
        camera.capture_preview().await.map_err(DeviceOpError::from)
    }

    async fn status(&self) -> Result<crate::device::CameraStatus, DeviceOpError> {
        let driver = self.driver.read().await;
        let camera = &*driver;
        let native_status = camera.get_status().await.map_err(DeviceOpError::from)?;
        let capabilities = camera.capabilities();
        let sensor_info = camera.get_sensor_info();

        Ok(crate::device::CameraStatus {
            connected: camera.is_connected(),
            state: match native_status.state {
                skotiq_device::CameraState::Idle => crate::device::CameraState::Idle,
                skotiq_device::CameraState::Waiting => crate::device::CameraState::Waiting,
                skotiq_device::CameraState::Exposing => crate::device::CameraState::Exposing,
                skotiq_device::CameraState::Reading => crate::device::CameraState::Reading,
                skotiq_device::CameraState::Downloading => crate::device::CameraState::Download,
                skotiq_device::CameraState::Error => crate::device::CameraState::Error,
            },
            sensor_temp: native_status.sensor_temp,
            cooler_power: native_status.cooler_power,
            target_temp: native_status.target_temp,
            cooler_on: native_status.cooler_on,
            gain: native_status.gain,
            offset: native_status.offset,
            bin_x: native_status.bin_x,
            bin_y: native_status.bin_y,
            sensor_width: sensor_info.width,
            sensor_height: sensor_info.height,
            pixel_size_x: sensor_info.pixel_size_x,
            pixel_size_y: sensor_info.pixel_size_y,
            // The DRIVER owns this value. Re-deriving it from
            // `bit_depth` here overwrote whatever the vendor SDK
            // reported with the ADC range, which is a different
            // quantity: an ASI1600MM (12-bit, Raw16 left-justified)
            // was published as `maxAdu: 4095` while its frames
            // measurably contained values up to 65504. See the
            // `skotiq_device::SensorInfo` contract.
            // 0 = the driver never populated it; 65535 is the
            // container ceiling and the documented fallback (see the
            // `unwrap_or` policy in this module's header).
            max_adu: if sensor_info.max_adu == 0 {
                65535
            } else {
                sensor_info.max_adu
            },
            saturation_adu: sensor_info.saturation_adu,
            can_cool: capabilities.can_cool,
            can_set_gain: capabilities.can_set_gain,
            can_set_offset: capabilities.can_set_offset,
        })
    }

    async fn recommended_settings(
        &self,
    ) -> Result<skotiq_device::CameraRecommendedSettings, DeviceOpError> {
        let device_id = self.device_id.as_str();
        let driver = self.driver.read().await;
        let camera = &*driver;
        camera.get_recommended_settings().await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!(
                    "Failed to query recommended settings for native camera {}: {}",
                    device_id, e
                ),
                e,
            )
        })
    }

    async fn set_gain(&self, gain: i32) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let mut driver = self.driver.write().await;
        let camera = &mut *driver;
        camera.set_gain(gain).await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!(
                    "Failed to set native SDK camera {} gain to {}: {}",
                    device_id, gain, e
                ),
                e,
            )
        })
    }

    async fn set_offset(&self, offset: i32) -> Result<(), DeviceOpError> {
        let mut driver = self.driver.write().await;
        let camera = &mut *driver;
        camera.set_offset(offset).await.map_err(DeviceOpError::from)
    }

    async fn set_binning(&self, bin_x: i32, bin_y: i32) -> Result<(), DeviceOpError> {
        let mut driver = self.driver.write().await;
        let camera = &mut *driver;
        camera
            .set_binning(bin_x, bin_y)
            .await
            .map_err(DeviceOpError::from)
    }

    async fn set_readout_mode(&self, mode_index: i32) -> Result<(), DeviceOpError> {
        let mut driver = self.driver.write().await;
        let camera = &mut *driver;
        let mode = skotiq_device::ReadoutMode {
            name: format!("Mode {}", mode_index),
            description: String::new(),
            index: mode_index,
            gain_min: None,
            gain_max: None,
            offset_min: None,
            offset_max: None,
        };
        camera
            .set_readout_mode(&mode)
            .await
            .map_err(DeviceOpError::from)
    }

    async fn set_cooler(
        &self,
        enabled: bool,
        target_temp: Option<f64>,
    ) -> Result<(), DeviceOpError> {
        let mut driver = self.driver.write().await;
        let camera = &mut *driver;
        camera
            .set_cooler(enabled, target_temp)
            .await
            .map_err(DeviceOpError::from)
    }

    /// A snapshot: a read the SDK refuses mid-transition leaves its field
    /// absent, and the equipment view re-reads on its timer.
    async fn capabilities(&self, _device_id: &str) -> Result<DeviceCapabilities, SkotiqError> {
        let camera = self.driver.read().await;
        let native_caps = camera.capabilities();
        let sensor_info = camera.get_sensor_info();
        let gain_range = camera.get_gain_range().await.ok();
        let offset_range = camera.get_offset_range().await.ok();
        // Why: vendor SDK readout-mode enumeration is optional (only ZWO
        // and QHY expose multi-mode sensors). Empty vec → UI hides the
        // readout-mode selector, matching cameras that have a single
        // hard-coded mode.
        let readout_modes = camera.get_readout_modes().await.unwrap_or_default();
        let status = camera.get_status().await.ok();
        let cooler_power = status.as_ref().and_then(|s| s.cooler_power);
        // Why: the CameraDriver trait's get_cooler_temp_range default
        // returns Ok(None); only drivers that publish the achievable
        // regulated-cooling range (currently ZWO, via C2) override it.
        // `.ok().flatten()` collapses a transient SDK error to None
        // ("range unknown") — the equipment view re-probes on a timer,
        // and an unknown range simply leaves the setpoint field unclamped
        // rather than fabricating limits.
        let (cooler_min_temp_c, cooler_max_temp_c) = camera
            .get_cooler_temp_range()
            .await
            .ok()
            .flatten()
            .map_or((None, None), |(min, max)| (Some(min), Some(max)));

        // Same contract as the cooler range: `None` means "this driver
        // does not publish the limits", never a guessed clamp. Without
        // these, `exposureMin`/`exposureMax` were always null, so no
        // client could validate an exposure before submitting it and an
        // out-of-range request failed deep in the SDK instead of being
        // refused up front. ZWO publishes them via ASIGetControlCaps.
        let (exposure_min, exposure_max) = camera
            .get_exposure_range()
            .await
            .ok()
            .flatten()
            .map_or((None, None), |(min, max)| (Some(min), Some(max)));

        Ok(DeviceCapabilities::Camera(CameraCapabilities {
            max_width: sensor_info.width,
            max_height: sensor_info.height,
            bit_depth: sensor_info.bit_depth,
            has_shutter: native_caps.has_shutter,
            can_set_ccd_temperature: native_caps.can_cool,
            can_set_cooler: native_caps.can_cool,
            can_get_cooler_power: cooler_power.is_some(),
            can_bin: native_caps.can_set_binning,
            max_bin_x: native_caps.max_bin_x,
            max_bin_y: native_caps.max_bin_y,
            can_set_gain: native_caps.can_set_gain,
            gain_min: gain_range.map(|(min, _)| min),
            gain_max: gain_range.map(|(_, max)| max),
            can_set_offset: native_caps.can_set_offset,
            offset_min: offset_range.map(|(min, _)| min),
            offset_max: offset_range.map(|(_, max)| max),
            can_abort_exposure: true,
            can_subframe: native_caps.can_subframe,
            pixel_size_x: Some(sensor_info.pixel_size_x),
            pixel_size_y: Some(sensor_info.pixel_size_y),
            is_color: sensor_info.color,
            bayer_pattern: sensor_info.bayer_pattern.map(|bp| format!("{:?}", bp)),
            readout_modes: readout_modes.into_iter().map(|m| m.name).collect(),
            ccd_temperature: status.as_ref().and_then(|s| s.sensor_temp),
            set_ccd_temperature: status.as_ref().and_then(|s| s.target_temp),
            cooler_power,
            cooler_on: status.as_ref().map(|s| s.cooler_on),
            cooler_min_temp_c,
            cooler_max_temp_c,
            exposure_min,
            exposure_max,
            ..Default::default()
        }))
    }

    async fn identity(&self) -> Option<DeviceIdentity> {
        let camera = self.driver.read().await;
        Some(DeviceManager::identity_from_camera(
            &self.device_id,
            camera.as_ref(),
        ))
    }
}
