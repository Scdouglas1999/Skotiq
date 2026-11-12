//! The camera behind its handle, once per protocol.
//!
//! An exposure is three calls from whoever runs it: `start_exposure`, a poll
//! of `is_exposure_complete`, then [`download`]. Each implementation body is
//! the protocol's own sequence of driver calls; a vendor camera and an ASCOM
//! COM camera take their device lock ([`super::Exclusive`]) for it.
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

mod alpaca;
#[cfg(windows)]
mod com;
mod indi;
mod vendor;

pub(crate) use alpaca::AlpacaCameraHandle;
#[cfg(windows)]
pub(crate) use com::ComCamera;
pub(crate) use indi::IndiCameraHandle;
pub(crate) use vendor::VendorCamera;

use super::RigDriver;
use crate::device::DriverType;
use crate::device_capabilities::DeviceCapabilities;
use crate::device_manager::identity::DeviceIdentity;
use crate::dispatch::DeviceOpError;
use crate::error::SkotiqError;
use async_trait::async_trait;
use skotiq_device::{ImageData, SubFrame};

#[async_trait]
pub(crate) trait Camera: RigDriver {
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

    async fn set_binning(&self, bin_x: i32, bin_y: i32) -> Result<(), DeviceOpError>;

    async fn set_readout_mode(&self, mode_index: i32) -> Result<(), DeviceOpError>;

    /// `target_temp` of `None` leaves the camera's setpoint alone.
    async fn set_cooler(
        &self,
        enabled: bool,
        target_temp: Option<f64>,
    ) -> Result<(), DeviceOpError>;

    async fn capabilities(&self, device_id: &str) -> Result<DeviceCapabilities, SkotiqError>;

    /// What the connected camera says it is; `None` where the protocol gives
    /// the driver nothing to say.
    async fn identity(&self) -> Option<DeviceIdentity> {
        None
    }
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
