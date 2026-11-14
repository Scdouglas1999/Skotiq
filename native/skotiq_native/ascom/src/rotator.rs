//! ASCOM Rotator wrapper. What the members mean is decided in the bridge, once
//! for COM and Alpaca.

use crate::com::ComDispatch;

com_device!(Rotator);

impl<D: ComDispatch> Rotator<D> {
    skotiq_device::ascom_rotator_members!(com_member);
}
