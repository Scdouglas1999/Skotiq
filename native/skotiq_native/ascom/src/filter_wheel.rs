//! ASCOM Filter Wheel wrapper. What the members mean is decided in the bridge,
//! once for COM and Alpaca.

use crate::com::ComDispatch;
use crate::error::AscomResult;

com_device!(FilterWheel);

impl<D: ComDispatch> FilterWheel<D> {
    skotiq_device::ascom_filter_wheel_members!(com_member);

    pub fn position(&self) -> AscomResult<i32> {
        let pos = self.read_position();
        tracing::debug!("ASCOM FilterWheel.Position returned: {:?}", pos);
        pos
    }

    pub fn set_position(&self, position: i32) -> AscomResult<()> {
        tracing::info!("ASCOM FilterWheel.SetPosition({})", position);
        self.write_position(position)
    }
}
