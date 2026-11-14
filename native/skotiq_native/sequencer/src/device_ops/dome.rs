//! What a run asks of the dome.

use super::DeviceResult;
use async_trait::async_trait;

#[async_trait]
pub trait DomeOps: Send + Sync {
    /// Device id of the dome to command when the sequencer's execution context
    /// carries no dome role assignment.
    ///
    /// The executor's dome/cover-calibrator role slots are filled only by
    /// `SequenceExecutor::set_dome` / `set_cover_calibrator`, and the Dart
    /// runtime-config path never calls them — its `sequencerSetDevices` contract
    /// carries camera, mount, focuser, filter wheel and rotator only. The device
    /// layer is the only component that knows what is actually connected, so it
    /// answers the question, on the same "resolve the active device for me"
    /// contract `safety_is_safe(None)` uses.
    ///
    /// The default `None` means "this ops layer cannot enumerate devices"
    /// (`NullDeviceOps`, test doubles), which preserves the explicit
    /// "no dome connected" instruction failure.
    async fn active_dome_id(&self) -> Option<String> {
        None
    }

    /// Open dome shutter
    async fn dome_open(&self, dome_id: &str) -> DeviceResult<()>;

    /// Close dome shutter
    async fn dome_close(&self, dome_id: &str) -> DeviceResult<()>;

    /// Park dome
    async fn dome_park(&self, dome_id: &str) -> DeviceResult<()>;

    async fn dome_get_shutter_status(&self, dome_id: &str) -> DeviceResult<String>;
}
