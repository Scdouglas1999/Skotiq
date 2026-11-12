//! ASCOM Dome wrapper.

use crate::com::ComDispatch;
use crate::error::{AscomError, AscomResult};

com_device!(Dome);

impl<D: ComDispatch> Dome<D> {
    skotiq_device::ascom_dome_members!(com_member);

    /// Enable or disable slaving to the mount
    pub fn set_slaved(&self, slaved: bool) -> AscomResult<()> {
        self.write_slaved(slaved).map_err(|e| AscomError::Context {
            context: "Failed to set ASCOM dome Slaved",
            source: Box::new(e),
        })
    }
}
