//! What a run asks of the flat panel and dust cover.

use super::DeviceResult;
use async_trait::async_trait;

#[async_trait]
pub trait CoverCalibratorOps: Send + Sync {
    /// Device id of the cover calibrator (flat panel) to command when the
    /// sequencer's execution context carries no cover-calibrator role
    /// assignment. See [`DomeOps::active_dome_id`](super::DomeOps::active_dome_id) for why the fallback is
    /// needed and why the default is `None`.
    async fn active_cover_calibrator_id(&self) -> Option<String> {
        None
    }

    /// Open the cover (unpark dust cap)
    async fn cover_calibrator_open_cover(&self, device_id: &str) -> DeviceResult<()>;

    /// Close the cover (park dust cap)
    async fn cover_calibrator_close_cover(&self, device_id: &str) -> DeviceResult<()>;

    /// Halt cover movement
    async fn cover_calibrator_halt_cover(&self, device_id: &str) -> DeviceResult<()>;

    /// Turn on the calibrator (flat panel light) at specified brightness
    async fn cover_calibrator_calibrator_on(
        &self,
        device_id: &str,
        brightness: i32,
    ) -> DeviceResult<()>;

    /// Turn off the calibrator (flat panel light)
    async fn cover_calibrator_calibrator_off(&self, device_id: &str) -> DeviceResult<()>;

    /// Get current cover state (0=NotPresent, 1=Closed, 2=Moving, 3=Open, 4=Unknown, 5=Error)
    async fn cover_calibrator_get_cover_state(&self, device_id: &str) -> DeviceResult<i32>;

    /// Get current calibrator state (0=NotPresent, 1=Off, 2=NotReady, 3=Ready, 4=Unknown, 5=Error)
    async fn cover_calibrator_get_calibrator_state(&self, device_id: &str) -> DeviceResult<i32>;

    /// Get current brightness level
    async fn cover_calibrator_get_brightness(&self, device_id: &str) -> DeviceResult<i32>;

    /// Get maximum brightness level
    async fn cover_calibrator_get_max_brightness(&self, device_id: &str) -> DeviceResult<i32>;
}
