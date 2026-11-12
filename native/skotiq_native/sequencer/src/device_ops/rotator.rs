//! What a run asks of the rotator.

use super::DeviceResult;
use async_trait::async_trait;

#[async_trait]
pub trait RotatorOps: Send + Sync {
    /// Move rotator to angle (degrees)
    async fn rotator_move_to(&self, rotator_id: &str, angle: f64) -> DeviceResult<()>;

    /// Move rotator by relative amount
    async fn rotator_move_relative(&self, rotator_id: &str, delta: f64) -> DeviceResult<()>;

    async fn rotator_get_angle(&self, rotator_id: &str) -> DeviceResult<f64>;

    async fn rotator_halt(&self, rotator_id: &str) -> DeviceResult<()>;
}
