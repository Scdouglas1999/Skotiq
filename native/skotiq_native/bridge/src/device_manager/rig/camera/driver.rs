//! A camera behind a [`CameraDriver`]: a vendor SDK camera, an Alpaca camera
//! or an INDI camera.
//!
//! Which requests an operation makes of the camera is the driver's; this
//! file adds what is the same for every driver: the sentences an operator
//! reads and the status and capability shapes the application uses.

use super::{no_preview, Camera, ExposureAborts};
use crate::device::DriverType;
use crate::device_capabilities::driver::camera_capabilities;
use crate::device_capabilities::types::DeviceCapabilities;
use crate::device_manager::identity::DeviceIdentity;
use crate::device_manager::rig::{RigDriver, Slot};
use crate::device_manager::DeviceManager;
use crate::dispatch::error::DeviceOpError;
use crate::error::SkotiqError;
use async_trait::async_trait;
use skotiq_device::{
    CameraDriver, DriverError, ExposureAbort, ExposureParams, ImageData, SubFrame,
};
use std::sync::Arc;
use tokio::sync::RwLock;

type Driver = dyn CameraDriver + Send + Sync;

/// What differs by protocol around a [`CameraDriver`].
struct Protocol {
    /// "Native", "Alpaca", "INDI": in "Native camera not connected".
    name: &'static str,
    /// The protocol inside a sentence: "native SDK", "Alpaca", "INDI".
    in_sentence: &'static str,
    /// What a camera without live view is said to be driven by.
    driver_type: DriverType,
}

const VENDOR: Protocol = Protocol {
    name: "Native",
    in_sentence: "native SDK",
    driver_type: DriverType::Native,
};

const ALPACA: Protocol = Protocol {
    name: "Alpaca",
    in_sentence: "Alpaca",
    driver_type: DriverType::Alpaca,
};

const INDI: Protocol = Protocol {
    name: "INDI",
    in_sentence: "INDI",
    driver_type: DriverType::Indi,
};

pub(crate) struct DriverCamera {
    device_id: String,
    driver: Arc<Slot<Driver>>,
    aborts: ExposureAborts,
    /// The driver's way to give up a frame read in flight, when it has one.
    give_up: Option<Arc<dyn ExposureAbort>>,
    protocol: &'static Protocol,
}

impl DriverCamera {
    /// A vendor SDK camera: the driver keeps state between calls, so it is
    /// reached one call at a time.
    pub(crate) fn vendor(device_id: &str, driver: Box<Driver>) -> Self {
        Self {
            device_id: device_id.to_string(),
            give_up: driver.exposure_abort(),
            driver: Arc::new(Slot::held(driver)),
            aborts: ExposureAborts::new(),
            protocol: &VENDOR,
        }
    }

    pub(crate) fn alpaca(device_id: &str, camera: skotiq_alpaca::AlpacaCameraDriver) -> Self {
        Self {
            device_id: device_id.to_string(),
            give_up: None,
            driver: Arc::new(Slot::per_call(move || {
                Box::new(camera.clone()) as Box<Driver>
            })),
            aborts: ExposureAborts::new(),
            protocol: &ALPACA,
        }
    }

    pub(crate) fn indi(
        device_id: &str,
        client: Arc<RwLock<skotiq_indi::IndiClient>>,
        device_name: &str,
    ) -> Self {
        let device_name = device_name.to_string();
        Self {
            device_id: device_id.to_string(),
            give_up: None,
            driver: Arc::new(Slot::per_call(move || {
                Box::new(skotiq_indi::IndiCamera::new(client.clone(), &device_name)) as Box<Driver>
            })),
            aborts: ExposureAborts::new(),
            protocol: &INDI,
        }
    }

    fn gone(&self) -> DeviceOpError {
        DeviceOpError::not_connected(
            Some(self.device_id.clone()),
            format!("{} camera not connected", self.protocol.name),
        )
    }

    fn failed(&self, what: String, error: DriverError) -> DeviceOpError {
        DeviceOpError::caused_by(
            Some(self.device_id.clone()),
            format!("{what}: {error}"),
            error,
        )
    }
}

#[async_trait]
impl RigDriver for DriverCamera {
    async fn disconnect(&self) -> Result<(), DriverError> {
        match self.driver.take().await {
            Some(mut camera) => camera.disconnect().await,
            None => Ok(()),
        }
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        let Some(camera) = self.driver.read().await else {
            return Ok(false);
        };
        camera
            .heartbeat()
            .await
            .map_err(|e| format!("{} camera liveness probe failed: {}", self.protocol.name, e))
    }

    async fn identity(&self) -> Option<DeviceIdentity> {
        if self.protocol.driver_type != DriverType::Native {
            return None;
        }
        let camera = self.driver.read().await?;
        Some(DeviceManager::identity_from_camera(
            &self.device_id,
            &*camera,
        ))
    }
}

#[async_trait]
impl Camera for DriverCamera {
    async fn check_automatic_reconnect(&self) -> Result<(), DeviceOpError> {
        let Some(camera) = self.driver.read().await else {
            return Ok(());
        };
        camera
            .check_automatic_reconnect()
            .map_err(DeviceOpError::from)
    }

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
        let mut camera = self.driver.write().await.ok_or_else(|| self.gone())?;
        tracing::info!(
            "DeviceManager: Starting {} exposure",
            self.protocol.in_sentence
        );
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
            self.failed(
                format!(
                    "Failed to start {} camera exposure on {}",
                    self.protocol.in_sentence, self.device_id
                ),
                e,
            )
        })
    }

    async fn is_exposure_complete(&self) -> Result<bool, DeviceOpError> {
        let camera = self.driver.read().await.ok_or_else(|| self.gone())?;
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
        let mut camera = self.driver.write().await.ok_or_else(|| self.gone())?;
        camera.abort_exposure().await.map_err(DeviceOpError::from)
    }

    /// A held driver's read runs to its end on its own task, under the
    /// device lock, so the stop command and the next exposure follow it in
    /// order. A per-call client's read only waits for the camera and is
    /// dropped with this call.
    async fn read_frame(&self) -> Result<ImageData, DeviceOpError> {
        if let Slot::PerCall(_) = *self.driver {
            let mut camera = self.driver.write().await.ok_or_else(|| self.gone())?;
            return camera.download_image().await.map_err(|e| {
                self.failed(
                    format!(
                        "Failed to download image from {} camera {}",
                        self.protocol.in_sentence, self.device_id
                    ),
                    e,
                )
            });
        }
        let driver = Arc::clone(&self.driver);
        let gone = self.gone();
        let read = tokio::spawn(async move {
            let mut camera = driver.write().await.ok_or(gone)?;
            camera.download_image().await.map_err(DeviceOpError::from)
        });
        read.await.unwrap_or_else(|stopped| {
            Err(DeviceOpError::hardware(
                Some(self.device_id.clone()),
                format!("The frame read stopped: {stopped}"),
            ))
        })
    }

    async fn capture_preview(&self) -> Result<Vec<u8>, DeviceOpError> {
        let camera = self.driver.read().await.ok_or_else(|| self.gone())?;
        camera.capture_preview().await.map_err(|e| match e {
            DriverError::NotSupported if self.protocol.driver_type != DriverType::Native => {
                no_preview(self.protocol.driver_type, &self.device_id)
            }
            e => DeviceOpError::from(e),
        })
    }

    async fn status(&self) -> Result<crate::device::CameraStatus, DeviceOpError> {
        let camera = self.driver.read().await.ok_or_else(|| self.gone())?;
        let report = camera.report().await.map_err(DeviceOpError::from)?;
        let (status, sensor) = (report.status, report.sensor);
        Ok(crate::device::CameraStatus {
            connected: camera.is_connected(),
            state: match status.state {
                skotiq_device::CameraState::Idle => crate::device::CameraState::Idle,
                skotiq_device::CameraState::Waiting => crate::device::CameraState::Waiting,
                skotiq_device::CameraState::Exposing => crate::device::CameraState::Exposing,
                skotiq_device::CameraState::Reading => crate::device::CameraState::Reading,
                skotiq_device::CameraState::Downloading => crate::device::CameraState::Download,
                skotiq_device::CameraState::Error => crate::device::CameraState::Error,
            },
            sensor_temp: status.sensor_temp,
            cooler_power: status.cooler_power,
            target_temp: status.target_temp,
            cooler_on: status.cooler_on,
            gain: status.gain,
            offset: status.offset,
            bin_x: status.bin_x,
            bin_y: status.bin_y,
            sensor_width: sensor.width,
            sensor_height: sensor.height,
            pixel_size_x: sensor.pixel_size_x,
            pixel_size_y: sensor.pixel_size_y,
            // The driver owns this value: it is the largest value in the
            // delivered pixels, not `2^bit_depth - 1` (see
            // `skotiq_device::SensorInfo`). 0 is a driver that never filled
            // it in; 65535 is the container's ceiling.
            max_adu: if sensor.max_adu == 0 {
                65535
            } else {
                sensor.max_adu
            },
            saturation_adu: sensor.saturation_adu,
            can_cool: report.can_cool,
            can_set_gain: report.can_set_gain,
            can_set_offset: report.can_set_offset,
        })
    }

    async fn recommended_settings(
        &self,
    ) -> Result<skotiq_device::CameraRecommendedSettings, DeviceOpError> {
        let camera = self.driver.read().await.ok_or_else(|| self.gone())?;
        camera.get_recommended_settings().await.map_err(|e| {
            self.failed(
                format!(
                    "Failed to query recommended settings for {} camera {}",
                    self.protocol.in_sentence, self.device_id
                ),
                e,
            )
        })
    }

    async fn set_gain(&self, gain: i32) -> Result<(), DeviceOpError> {
        let mut camera = self.driver.write().await.ok_or_else(|| self.gone())?;
        camera.set_gain(gain).await.map_err(|e| {
            self.failed(
                format!(
                    "Failed to set {} camera {} gain to {}",
                    self.protocol.in_sentence, self.device_id, gain
                ),
                e,
            )
        })
    }

    async fn set_offset(&self, offset: i32) -> Result<(), DeviceOpError> {
        let mut camera = self.driver.write().await.ok_or_else(|| self.gone())?;
        camera.set_offset(offset).await.map_err(DeviceOpError::from)
    }

    async fn set_readout_mode(&self, mode_index: i32) -> Result<(), DeviceOpError> {
        let mut camera = self.driver.write().await.ok_or_else(|| self.gone())?;
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
        let mut camera = self.driver.write().await.ok_or_else(|| self.gone())?;
        camera
            .set_cooler(enabled, target_temp)
            .await
            .map_err(DeviceOpError::from)
    }

    /// A snapshot: a read the driver refuses mid-transition leaves its field
    /// absent, and the equipment view re-reads on its timer.
    async fn capabilities(&self, device_id: &str) -> Result<DeviceCapabilities, SkotiqError> {
        let camera = self.driver.read().await.ok_or_else(|| {
            SkotiqError::hardware_error(
                device_id,
                format!("{} camera not connected", self.protocol.name),
            )
        })?;
        let status = camera.get_status().await.ok();
        Ok(DeviceCapabilities::Camera(camera_capabilities(
            camera.describe().await,
            status.as_ref(),
        )))
    }
}
