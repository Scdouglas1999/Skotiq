//! Alpaca Focuser API implementation

use crate::AlpacaError;

/// Focuser status aggregate for parallel status query
#[derive(Debug, Clone)]
pub struct FocuserStatus {
    pub connected: bool,
    pub position: i32,
    pub is_moving: bool,
    pub temperature: Option<f64>,
    pub temp_comp: Option<bool>,
}

#[derive(Debug, Clone)]
pub struct FocuserCapabilities {
    pub absolute: bool,
    pub max_step: i32,
    pub max_increment: i32,
    pub step_size: Option<f64>,
    pub temp_comp_available: bool,
}

alpaca_device!(
    AlpacaFocuser,
    Focuser
);

impl AlpacaFocuser {
    skotiq_device::ascom_focuser_members!(alpaca_member);

    /// Get comprehensive focuser status in a single parallel query
    pub async fn get_status(&self) -> Result<FocuserStatus, AlpacaError> {
        let (connected, position, is_moving, temperature, temp_comp) = tokio::join!(
            self.is_connected(),
            self.position(),
            self.is_moving(),
            self.temperature(),
            self.temp_comp(),
        );

        Ok(FocuserStatus {
            connected: connected?,
            position: position?,
            is_moving: is_moving?,
            temperature: temperature.ok(),
            temp_comp: temp_comp.ok(),
        })
    }

    /// Get focuser capabilities in a single parallel query
    pub async fn get_capabilities(&self) -> Result<FocuserCapabilities, AlpacaError> {
        let (absolute, max_step, max_increment, step_size, temp_comp_available) = tokio::join!(
            self.absolute(),
            self.max_step(),
            self.max_increment(),
            self.step_size(),
            self.temp_comp_available(),
        );

        Ok(FocuserCapabilities {
            absolute: absolute?,
            max_step: max_step?,
            max_increment: max_increment?,
            step_size: step_size.ok(),
            temp_comp_available: temp_comp_available?,
        })
    }
}
