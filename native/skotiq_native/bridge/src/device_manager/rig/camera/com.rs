//! An ASCOM camera over COM. The wrapper sits behind its device lock, taken
//! as each operation took the wrapper's lock before: `read` for a status
//! read, `write` for a command, the exposure start and the frame read.

use super::{no_preview, Camera, ExposureAborts};
use crate::ascom_wrapper::camera::{AscomCameraWrapper, CameraConnectionHealth};
use crate::device::DriverType;
use crate::device_capabilities::types::DeviceCapabilities;
use crate::device_manager::identity::DeviceIdentity;
use crate::device_manager::rig::{Exclusive, RigDriver};
use crate::dispatch::error::DeviceOpError;
use crate::error::SkotiqError;
use async_trait::async_trait;
use skotiq_device::{CameraDriver, DeviceDriver, DriverError, ExposureParams, ImageData, SubFrame};

pub(crate) struct ComCamera {
    device_id: String,
    camera: std::sync::Arc<Exclusive<AscomCameraWrapper>>,
    aborts: ExposureAborts,
}

impl ComCamera {
    pub(crate) fn new(device_id: &str, camera: AscomCameraWrapper) -> Self {
        Self {
            device_id: device_id.to_string(),
            camera: std::sync::Arc::new(Exclusive::new(camera)),
            aborts: ExposureAborts::new(),
        }
    }
}

#[async_trait]
impl RigDriver for ComCamera {
    async fn disconnect(&self) -> Result<(), DriverError> {
        self.camera.write().await.disconnect().await
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        let device_id = self.device_id.as_str();
        match self.camera.read().await.heartbeat().await {
            Ok(health) => {
                let is_healthy = matches!(
                    health,
                    CameraConnectionHealth::Healthy | CameraConnectionHealth::Unknown
                );
                tracing::trace!("ASCOM camera {} heartbeat: {:?}", device_id, health);
                Ok(is_healthy)
            }
            Err(e) => {
                tracing::debug!("ASCOM camera {} heartbeat failed: {:?}", device_id, e);
                Ok(false)
            }
        }
    }

    /// Geometry only: the wrapper's name is the ProgID it was built with,
    /// which two bodies behind one driver share. The sensor cache is read
    /// from the live driver at connect.
    async fn identity(&self) -> Option<DeviceIdentity> {
        let sensor = self.camera.read().await.get_sensor_info();
        Some(DeviceIdentity {
            model: None,
            serial_number: None,
            sensor: DeviceIdentity::sensor_fingerprint(
                sensor.width,
                sensor.height,
                sensor.pixel_size_x,
            ),
        })
    }
}

#[async_trait]
impl Camera for ComCamera {
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
        tracing::info!("DeviceManager: Calling AscomCameraWrapper.start_exposure()");
        let mut camera = camera.write().await;
        camera.start_exposure(params).await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!(
                    "Failed to start ASCOM camera exposure on {}: {}",
                    device_id, e
                ),
                e,
            )
        })
    }

    async fn is_exposure_complete(&self) -> Result<bool, DeviceOpError> {
        let camera = &self.camera;
        let camera = camera.read().await;
        camera
            .is_exposure_complete()
            .await
            .map_err(DeviceOpError::from)
    }

    async fn stop_exposure(&self) -> Result<(), DeviceOpError> {
        let camera = &self.camera;
        let mut camera = camera.write().await;
        camera.abort_exposure().await.map_err(DeviceOpError::from)
    }

    async fn read_frame(&self) -> Result<ImageData, DeviceOpError> {
        let device_id = self.device_id.clone();
        let camera = std::sync::Arc::clone(&self.camera);
        let read = tokio::spawn(async move {
            let mut camera = camera.write().await;
            camera.download_image().await.map_err(|e| {
                DeviceOpError::caused_by(
                    Some(device_id.clone()),
                    format!(
                        "Failed to download image from ASCOM camera {}: {}",
                        device_id, e
                    ),
                    e,
                )
            })
        });
        read.await.unwrap_or_else(|stopped| {
            Err(DeviceOpError::hardware(
                Some(self.device_id.clone()),
                format!("The frame read stopped: {stopped}"),
            ))
        })
    }

    async fn status(&self) -> Result<crate::device::CameraStatus, DeviceOpError> {
        let camera = &self.camera;
        let camera_guard = camera.read().await;
        let native_status = camera_guard
            .get_status()
            .await
            .map_err(DeviceOpError::from)?;
        let ascom_caps = camera_guard
            .get_capabilities()
            .await
            .map_err(DeviceOpError::from)?;

        Ok(crate::device::CameraStatus {
            connected: true,
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
            sensor_width: ascom_caps.max_width,
            sensor_height: ascom_caps.max_height,
            pixel_size_x: ascom_caps.pixel_size_x.unwrap_or(0.0),
            pixel_size_y: ascom_caps.pixel_size_y.unwrap_or(0.0),
            // MaxADU is the driver's range; bit depth is only its storage bucket.
            max_adu: if ascom_caps.max_adu == 0 {
                65535
            } else {
                ascom_caps.max_adu
            },
            saturation_adu: None,
            can_cool: ascom_caps.can_set_ccd_temperature,
            can_set_gain: ascom_caps.controls.gain.is_present(),
            can_set_offset: ascom_caps.controls.offset.is_present(),
        })
    }

    async fn recommended_settings(
        &self,
    ) -> Result<skotiq_device::CameraRecommendedSettings, DeviceOpError> {
        Ok(skotiq_device::CameraRecommendedSettings::default())
    }

    async fn set_gain(&self, gain: i32) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let camera = &self.camera;
        let mut camera = camera.write().await;
        camera.set_gain(gain).await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!(
                    "Failed to set ASCOM camera {} gain to {}: {}",
                    device_id, gain, e
                ),
                e,
            )
        })
    }

    async fn set_offset(&self, offset: i32) -> Result<(), DeviceOpError> {
        let camera = &self.camera;
        let mut camera = camera.write().await;
        camera.set_offset(offset).await.map_err(DeviceOpError::from)
    }

    async fn set_readout_mode(&self, mode_index: i32) -> Result<(), DeviceOpError> {
        let camera = &self.camera;
        let mut camera = camera.write().await;
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
        let device_id = self.device_id.as_str();
        let cam = &self.camera;
        let mut cam = cam.write().await;
        cam.set_cooler(enabled, target_temp).await.map_err(|e| {
            let target = match target_temp {
                Some(t) => format!("{}C", t),
                None => "unchanged".to_string(),
            };
            DeviceOpError::caused_by(
                Some(device_id.to_string()),
                format!(
                    "Failed to set ASCOM camera {} cooler (enabled={}, target={}): {}",
                    device_id, enabled, target, e
                ),
                e,
            )
        })?;
        Ok(())
    }

    async fn capture_preview(&self) -> Result<Vec<u8>, DeviceOpError> {
        Err(no_preview(DriverType::Ascom, &self.device_id))
    }

    async fn capabilities(&self, device_id: &str) -> Result<DeviceCapabilities, SkotiqError> {
        let ascom_caps = self
            .camera
            .read()
            .await
            .get_capabilities()
            .await
            .map_err(|e| SkotiqError::hardware_error(device_id, format!("{:?}", e)))?;
        Ok(DeviceCapabilities::Camera(
            crate::device_capabilities::ascom::camera_capabilities_from_ascom(ascom_caps),
        ))
    }
}
