//! The camera behind its handle, once per protocol.
//!
//! An exposure is three calls from whoever runs it: `start_exposure`, a poll
//! of `is_exposure_complete`, then [`download`]. A vendor SDK camera, an
//! Alpaca camera and an INDI camera are a `skotiq_device::CameraDriver`
//! behind [`DriverCamera`]; an ASCOM COM camera and the simulator answer here
//! themselves. A vendor camera and a COM camera are reached under their
//! device lock.
//!
//! # Abort
//!
//! [`abort`] first releases a [`download`] in flight, which answers its
//! caller that the exposure was aborted without waiting for the frame, and
//! then sends the camera its stop command. A vendor or COM frame read is
//! never cut short from outside: it runs to the end of the driver call it is
//! in, on its own task and under the device lock, so the stop command and
//! the next exposure follow it in order, and what it read is dropped. A
//! vendor driver that can give the read up early says so with
//! [`skotiq_device::CameraDriver::exposure_abort`]. The other protocols'
//! reads only wait for the camera and are simply dropped.
//!
//! # Two cameras at once
//!
//! Nothing here serializes one camera against another. Whether two cameras
//! of one vendor may be inside that vendor's SDK at the same moment is the
//! SDK's own rule, kept with its lock
//! (`skotiq_native::vendor::sdk_loader::lock_scope`).

#[cfg(windows)]
mod com;
pub(crate) mod driver;

#[cfg(windows)]
pub(crate) use com::ComCamera;

use super::RigDriver;
use crate::device::DriverType;
use crate::dispatch::error::DeviceOpError;
use crate::error::SkotiqError;
use async_trait::async_trait;
use skotiq_device::{ImageData, SubFrame};

#[async_trait]
pub(crate) trait Camera: RigDriver {
    /// What the driver has to tell the user since it was last asked.
    async fn take_notices(&self) -> Vec<skotiq_device::DriverNotice> {
        Vec::new()
    }

    /// The captures the driver kept because their file did not become a
    /// frame.
    async fn retained_captures(&self) -> Vec<skotiq_device::RetainedCapture> {
        Vec::new()
    }

    /// The file of a retained capture, read from the camera or handed over
    /// by the driver that holds it.
    async fn retrieve_capture(
        &self,
        location: &str,
    ) -> Result<skotiq_device::CameraFile, DeviceOpError> {
        let _ = location;
        Err(DeviceOpError::unsupported(
            "This camera keeps no captures to retrieve",
        ))
    }

    /// Where an abort of this camera's exposure is announced.
    fn aborts(&self) -> &ExposureAborts;

    /// `gain` and `offset` of `None` leave the camera's current value alone.
    #[allow(clippy::too_many_arguments)]
    async fn start_exposure(
        &self,
        duration: f64,
        gain: Option<i32>,
        offset: Option<i32>,
        bin_x: i32,
        bin_y: i32,
        subframe: Option<SubFrame>,
        frame_type: skotiq_device::FrameType,
    ) -> Result<(), DeviceOpError>;

    async fn is_exposure_complete(&self) -> Result<bool, DeviceOpError>;

    /// The camera's stop command. Callers use [`abort`].
    async fn stop_exposure(&self) -> Result<(), DeviceOpError>;

    /// Reads the finished frame off the camera. Callers use [`download`],
    /// which drops this call part way when the exposure is aborted: nothing
    /// is then left waiting for a frame that the next exposure would hand
    /// it. An implementation whose driver call has to run to its end (a
    /// vendor SDK read, a COM call) runs it on a task of its own.
    async fn read_frame(&self) -> Result<ImageData, DeviceOpError>;

    /// A live-view frame as JPEG bytes.
    async fn capture_preview(&self) -> Result<Vec<u8>, DeviceOpError>;

    async fn status(&self) -> Result<crate::device::CameraStatus, DeviceOpError>;

    /// The gain and offset the manufacturer recommends, where its SDK says.
    async fn recommended_settings(
        &self,
    ) -> Result<skotiq_device::CameraRecommendedSettings, DeviceOpError>;

    async fn set_gain(&self, gain: i32) -> Result<(), DeviceOpError>;

    async fn set_offset(&self, offset: i32) -> Result<(), DeviceOpError>;

    /// Put the camera in the read mode it lists as `name` for the frames
    /// that follow. The mode is written only when the camera is in another.
    async fn use_readout_mode(&self, name: &str) -> Result<ReadModeUse, DeviceOpError>;

    /// `target_temp` of `None` leaves the camera's setpoint alone.
    async fn set_cooler(
        &self,
        enabled: bool,
        target_temp: Option<f64>,
    ) -> Result<(), DeviceOpError>;

    /// What the camera can do and how its sensor is built, as its driver
    /// reads it now.
    async fn describe(
        &self,
        device_id: &str,
    ) -> Result<skotiq_device::CameraDescription, SkotiqError>;
}

/// What asking a camera for a read mode came to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ReadModeUse {
    /// The camera was in the mode; nothing was written.
    AlreadyIn,
    /// The camera was in another mode (or would not say) and was switched.
    Switched,
    /// The camera lists these modes and the one asked for is not among
    /// them; nothing was written.
    NotListed(Vec<String>),
    /// The camera has one read mode; there is nothing to choose.
    NoModes,
}

/// What a status poll of a camera shows the application, for every driver.
pub(crate) fn camera_status(
    report: skotiq_device::CameraReport,
    connected: bool,
) -> crate::device::CameraStatus {
    use crate::device::CameraState;
    use crate::device_manager::ops::camera::camera_setting_or_unknown;
    let (status, sensor) = (report.status, report.sensor);
    crate::device::CameraStatus {
        connected,
        state: match status.state {
            skotiq_device::CameraState::Idle => CameraState::Idle,
            skotiq_device::CameraState::Waiting => CameraState::Waiting,
            skotiq_device::CameraState::Exposing => CameraState::Exposing,
            skotiq_device::CameraState::Reading => CameraState::Reading,
            skotiq_device::CameraState::Downloading => CameraState::Download,
            skotiq_device::CameraState::Error => CameraState::Error,
        },
        sensor_temp: status.sensor_temp,
        cooler_power: status.cooler_power,
        target_temp: status.target_temp,
        cooler_on: status.cooler_on,
        gain: camera_setting_or_unknown(status.gain),
        offset: camera_setting_or_unknown(status.offset),
        bin_x: status.bin_x,
        bin_y: status.bin_y,
        sensor_width: sensor.width,
        sensor_height: sensor.height,
        pixel_size_x: sensor.pixel_size_x,
        pixel_size_y: sensor.pixel_size_y,
        // The driver owns this value: it is the largest value in the
        // delivered pixels, not `2^bit_depth - 1` (see
        // `skotiq_device::SensorInfo`). 0 is a driver that never filled it
        // in; 65535 is the container's ceiling.
        max_adu: if sensor.max_adu == 0 {
            65535
        } else {
            sensor.max_adu
        },
        saturation_adu: sensor.saturation_adu,
        can_cool: report.can_cool,
        can_set_gain: report.can_set_gain,
        can_set_offset: report.can_set_offset,
    }
}

/// The one rule for a read mode, whatever the protocol: find the mode by the
/// name the camera lists, and write it only when the camera is in another.
/// Some cameras pay for a write (a QHY re-initializes), and a write that
/// changes nothing can still disturb a frame in a driver that resets on it.
pub(crate) async fn use_readout_mode<D: skotiq_device::CameraDriver + ?Sized>(
    camera: &mut D,
    name: &str,
) -> Result<ReadModeUse, skotiq_device::DriverError> {
    let modes = match camera.get_readout_modes().await {
        Ok(modes) => modes,
        Err(skotiq_device::DriverError::NotSupported) => Vec::new(),
        Err(e) => return Err(e),
    };
    if modes.is_empty() {
        return Ok(ReadModeUse::NoModes);
    }
    let wanted = name.trim();
    let Some(mode) = modes.iter().find(|m| m.name.eq_ignore_ascii_case(wanted)) else {
        return Ok(ReadModeUse::NotListed(
            modes.into_iter().map(|m| m.name).collect(),
        ));
    };
    let current = camera.get_readout_mode().await.ok().flatten();
    if current.is_some_and(|c| c.eq_ignore_ascii_case(&mode.name)) {
        return Ok(ReadModeUse::AlreadyIn);
    }
    camera.set_readout_mode(mode).await?;
    Ok(ReadModeUse::Switched)
}

/// Announces an abort to the downloads of one camera that are in flight.
pub(crate) struct ExposureAborts(tokio::sync::watch::Sender<u64>);

impl ExposureAborts {
    pub(crate) fn new() -> Self {
        Self(tokio::sync::watch::channel(0).0)
    }

    fn announce(&self) {
        self.0.send_modify(|count| *count = count.wrapping_add(1));
    }

    /// Resolves at the next abort announced after this call.
    fn next(&self) -> impl std::future::Future<Output = ()> {
        let mut seen = self.0.subscribe();
        async move {
            // The sender lives in the handle this future's caller holds.
            let _ = seen.changed().await;
        }
    }
}

/// The finished frame, or an error at once when the exposure is aborted
/// while the frame is being read.
pub(crate) async fn download(
    camera: &dyn Camera,
    device_id: &str,
) -> Result<ImageData, DeviceOpError> {
    let aborted = camera.aborts().next();
    tokio::select! {
        biased;
        () = aborted => Err(DeviceOpError::invalid_state(
            device_id,
            "The exposure was aborted before its frame was read",
        )),
        frame = camera.read_frame() => frame,
    }
}

/// Aborts the exposure: a download in flight is released first, then the
/// camera is sent its stop command.
pub(crate) async fn abort(camera: &dyn Camera) -> Result<(), DeviceOpError> {
    camera.aborts().announce();
    camera.stop_exposure().await
}

/// What a camera without live view answers a preview request.
fn no_preview(driver_type: DriverType, device_id: &str) -> DeviceOpError {
    DeviceOpError::unsupported(format!(
        "Live view preview is not supported for driver {:?} on camera {}",
        Some(driver_type),
        device_id
    ))
}

#[cfg(test)]
mod tests;
