//! ASCOM Switch wrapper.

use crate::com::ComDispatch;

com_device!(Switch);

impl<D: ComDispatch> Switch<D> {
    skotiq_device::ascom_switch_members!(com_member);
}

/// All ten `ISwitch` members must pass an `EXCEPINFO` to `IDispatch::Invoke`.
/// A switch powers the mount and the dew heaters, so "why did the port refuse"
/// is exactly the sentence an operator needs.
#[cfg(all(test, windows))]
mod excepinfo_tests {
    use super::*;
    use crate::windows::connection::excepinfo_recovery_tests::{connection, Excuse};

    fn refusing_switch() -> Switch<crate::windows::AscomDeviceConnection> {
        let (device, _) = connection(
            Excuse::Spoken {
                source: "ASCOM.PegasusAstro.UPBv2.Switch",
                description: "Switch 3 is read-only",
                scode: 0x8004_0403_u32 as i32,
            },
            false,
        );
        Switch { device }
    }

    #[test]
    fn a_refused_switch_write_says_why() {
        let sw = refusing_switch();

        for (label, err) in [
            ("SetSwitch", sw.set_switch(3, true).unwrap_err().to_string()),
            (
                "SetSwitchValue",
                sw.set_switch_value(3, 1.0).unwrap_err().to_string(),
            ),
        ] {
            assert!(
                err.contains("Switch 3 is read-only"),
                "{label} dropped the driver's description: {err}"
            );
            assert!(
                !err.contains("Exception occurred"),
                "{label} fell back to the bare HRESULT: {err}"
            );
        }
    }

    #[test]
    fn a_refused_switch_read_says_why() {
        let sw = refusing_switch();

        for (label, err) in [
            ("GetSwitch", sw.get_switch(3).unwrap_err().to_string()),
            (
                "GetSwitchName",
                sw.get_switch_name(3).unwrap_err().to_string(),
            ),
            (
                "GetSwitchValue",
                sw.get_switch_value(3).unwrap_err().to_string(),
            ),
            ("CanWrite", sw.can_write(3).unwrap_err().to_string()),
        ] {
            assert!(
                err.contains("Switch 3 is read-only"),
                "{label} dropped the driver's description: {err}"
            );
        }
    }
}
