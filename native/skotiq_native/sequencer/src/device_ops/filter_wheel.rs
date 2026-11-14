//! What a run asks of the filter wheel.

use super::DeviceResult;
use async_trait::async_trait;

#[async_trait]
pub trait FilterWheelOps: Send + Sync {
    /// Set filter wheel position by index (1-based)
    async fn filterwheel_set_position(&self, fw_id: &str, position: i32) -> DeviceResult<()>;

    /// Get current filter wheel position
    async fn filterwheel_get_position(&self, fw_id: &str) -> DeviceResult<i32>;

    /// Get filter names
    async fn filterwheel_get_names(&self, fw_id: &str) -> DeviceResult<Vec<String>>;

    /// Set filter by name (returns position used)
    async fn filterwheel_set_filter_by_name(&self, fw_id: &str, name: &str) -> DeviceResult<i32>;
}
