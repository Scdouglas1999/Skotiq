//! ASCOM Dome wrapper and batch status types.

use crate::com::ComDispatch;
use crate::error::{AscomError, AscomResult};

com_device!(
    Dome
);

impl<D: ComDispatch> Dome<D> {
    skotiq_device::ascom_dome_members!(com_member);

    /// Enable or disable slaving to the mount
    pub fn set_slaved(&self, slaved: bool) -> AscomResult<()> {
        self.write_slaved(slaved).map_err(|e| AscomError::Context {
            context: "Failed to set ASCOM dome Slaved",
            source: Box::new(e),
        })
    }

    /// Get complete dome status in a single batch operation
    pub fn get_full_status(&self) -> DomeFullStatus {
        DomeFullStatus {
            shutter_status: self.shutter_status().ok(),
            azimuth: self.azimuth().ok(),
            slewing: self.slewing().ok(),
            at_park: self.at_park().ok(),
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct DomeFullStatus {
    /// Shutter status (0=Open, 1=Closed, 2=Opening, 3=Closing, 4=Error)
    pub shutter_status: Option<i32>,
    pub azimuth: Option<f64>,
    pub slewing: Option<bool>,
    pub at_park: Option<bool>,
}
