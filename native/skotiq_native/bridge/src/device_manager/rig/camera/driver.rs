//! A camera behind a [`CameraDriver`]: a vendor SDK camera, an Alpaca camera
//! or an INDI camera.
//!
//! Which requests an operation makes of the camera is the driver's; this
//! file adds what is the same for every driver: the sentences an operator
//! reads and the status and capability shapes the application uses.

use super::{no_preview, Camera, ExposureAborts};
use crate::device::DriverType;
use crate::device_capabilities::alpaca::alpaca_camera_capabilities;
use crate::device_capabilities::indi::indi_capabilities;
use crate::device_capabilities::types::{CameraCapabilities, DeviceCapabilities};
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
    /// Where a description of the camera comes from, and what a camera
    /// without live view is said to be driven by.
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
    description: Description,
}

/// Where a description of the camera comes from: the driver's own answers,
/// or the protocol's capability read through the client the driver uses.
enum Description {
    Driver,
    Alpaca(skotiq_alpaca::AlpacaCameraDriver),
    Indi {
        client: Arc<RwLock<skotiq_indi::IndiClient>>,
        device_name: String,
    },
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
            description: Description::Driver,
        }
    }

    pub(crate) fn alpaca(device_id: &str, camera: skotiq_alpaca::AlpacaCameraDriver) -> Self {
        let description = Description::Alpaca(camera.clone());
        Self {
            device_id: device_id.to_string(),
            give_up: None,
            driver: Arc::new(Slot::per_call(move || {
                Box::new(camera.clone()) as Box<Driver>
            })),
            aborts: ExposureAborts::new(),
            protocol: &ALPACA,
            description,
        }
    }

    pub(crate) fn indi(
        device_id: &str,
        client: Arc<RwLock<skotiq_indi::IndiClient>>,
        device_name: &str,
    ) -> Self {
        let device_name = device_name.to_string();
        let description = Description::Indi {
            client: client.clone(),
            device_name: device_name.clone(),
        };
        Self {
            device_id: device_id.to_string(),
            give_up: None,
            driver: Arc::new(Slot::per_call(move || {
                Box::new(skotiq_indi::IndiCamera::new(client.clone(), &device_name)) as Box<Driver>
            })),
            aborts: ExposureAborts::new(),
            protocol: &INDI,
            description,
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

    async fn set_binning(&self, bin_x: i32, bin_y: i32) -> Result<(), DeviceOpError> {
        let mut camera = self.driver.write().await.ok_or_else(|| self.gone())?;
        camera
            .set_binning(bin_x, bin_y)
            .await
            .map_err(DeviceOpError::from)
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
        match &self.description {
            Description::Alpaca(driver) => {
                return Ok(DeviceCapabilities::Camera(
                    alpaca_camera_capabilities(driver.camera()).await,
                ))
            }
            Description::Indi {
                client,
                device_name,
            } => return indi_capabilities(client, device_name, device_id).await,
            Description::Driver => {}
        }
        let camera = self.driver.read().await.ok_or_else(|| {
            SkotiqError::hardware_error(
                device_id,
                format!("{} camera not connected", self.protocol.name),
            )
        })?;
        let native_caps = camera.capabilities();
        let sensor_info = camera.get_sensor_info();
        let gain_range = camera.get_gain_range().await.ok();
        let iso_speeds = camera.get_iso_speeds().await.unwrap_or_default();
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
            iso_speeds,
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
            cooler_on: status.as_ref().and_then(|s| s.cooler_on),
            cooler_min_temp_c,
            cooler_max_temp_c,
            exposure_min,
            exposure_max,
            ..Default::default()
        }))
    }
}
