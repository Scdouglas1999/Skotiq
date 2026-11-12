//! ASCOM Safety Monitor wrapper.

use crate::com::ComDispatch;

com_device!(SafetyMonitor);

impl<D: ComDispatch> SafetyMonitor<D> {
    skotiq_device::ascom_safety_monitor_members!(com_member);
}
