//! ASCOM Focuser wrapper and batch status types.

use crate::com::ComDispatch;

com_device!(Focuser);

impl<D: ComDispatch> Focuser<D> {
    skotiq_device::ascom_focuser_members!(com_member);

    /// Get focuser capabilities in a single batch operation
    pub fn get_capabilities(&self) -> FocuserCapabilities {
        FocuserCapabilities {
            absolute: self.absolute().ok(),
            max_step: self.max_step().ok(),
            max_increment: self.max_increment().ok(),
            step_size: self.step_size().ok(),
            temp_comp_available: self.temp_comp_available().ok(),
        }
    }

    /// Get complete focuser status in a single batch operation
    pub fn get_full_status(&self) -> FocuserFullStatus {
        FocuserFullStatus {
            position: self.position().ok(),
            is_moving: self.is_moving().ok(),
            temperature: self.temperature().ok(),
            temp_comp: self.temp_comp().ok(),
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct FocuserCapabilities {
    pub absolute: Option<bool>,
    pub max_step: Option<i32>,
    pub max_increment: Option<i32>,
    pub step_size: Option<f64>,
    pub temp_comp_available: Option<bool>,
}

#[derive(Debug, Clone, Default)]
pub struct FocuserFullStatus {
    pub position: Option<i32>,
    pub is_moving: Option<bool>,
    pub temperature: Option<f64>,
    pub temp_comp: Option<bool>,
}
