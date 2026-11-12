//! ASCOM Observing Conditions wrapper.

use crate::com::ComDispatch;

com_device!(ObservingConditions);

impl<D: ComDispatch> ObservingConditions<D> {
    skotiq_device::ascom_observing_conditions_members!(com_member);
}
