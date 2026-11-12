//! ASCOM Focuser wrapper. What the members mean is decided in the bridge, once
//! for COM and Alpaca.

use crate::com::ComDispatch;

com_device!(Focuser);

impl<D: ComDispatch> Focuser<D> {
    skotiq_device::ascom_focuser_members!(com_member);
}
