//! What a run asks of the focuser.

use super::DeviceResult;
use async_trait::async_trait;

#[async_trait]
pub trait FocuserOps: Send + Sync {
    /// Move focuser to absolute position
    async fn focuser_move_to(&self, focuser_id: &str, position: i32) -> DeviceResult<()>;

    async fn focuser_get_position(&self, focuser_id: &str) -> DeviceResult<i32>;

    async fn focuser_is_moving(&self, focuser_id: &str) -> DeviceResult<bool>;

    /// Get focuser temperature (if available)
    async fn focuser_get_temperature(&self, focuser_id: &str) -> DeviceResult<Option<f64>>;

    async fn focuser_halt(&self, focuser_id: &str) -> DeviceResult<()>;
}
