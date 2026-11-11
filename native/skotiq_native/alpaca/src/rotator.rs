//! Alpaca Rotator API implementation

use crate::AlpacaError;

/// Rotator status aggregate for parallel status query
#[derive(Debug, Clone)]
pub struct RotatorStatus {
    pub connected: bool,
    pub position: f64,
    pub mechanical_position: f64,
    pub is_moving: bool,
}

#[derive(Debug, Clone)]
pub struct RotatorCapabilities {
    pub can_reverse: bool,
    pub step_size: f64,
}

alpaca_device!(
    AlpacaRotator,
    Rotator
);

impl AlpacaRotator {
    skotiq_device::ascom_rotator_members!(alpaca_member);

    /// Get comprehensive rotator status in a single parallel query
    pub async fn get_status(&self) -> Result<RotatorStatus, AlpacaError> {
        let (connected, position, mechanical_position, is_moving) = tokio::join!(
            self.is_connected(),
            self.position(),
            self.mechanical_position(),
            self.is_moving(),
        );

        Ok(RotatorStatus {
            connected: connected?,
            position: position?,
            mechanical_position: mechanical_position?,
            is_moving: is_moving?,
        })
    }

    /// Get rotator capabilities in a single parallel query
    pub async fn get_capabilities(&self) -> Result<RotatorCapabilities, AlpacaError> {
        let (can_reverse, step_size) = tokio::join!(self.can_reverse(), self.step_size(),);

        Ok(RotatorCapabilities {
            can_reverse: can_reverse?,
            step_size: step_size?,
        })
    }
}
