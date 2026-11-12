//! ASCOM Cover Calibrator wrapper.

use crate::com::ComDispatch;

com_device!(CoverCalibrator);

impl<D: ComDispatch> CoverCalibrator<D> {
    skotiq_device::ascom_cover_calibrator_members!(com_member);
}

/// `CalibratorOn` must pass an `EXCEPINFO` to `IDispatch::Invoke`. Without it
/// a flat panel that refuses a brightness — the usual reason a flat sequence
/// stalls — can only say `0x80020009`.
#[cfg(all(test, windows))]
mod excepinfo_tests {
    use super::*;
    use crate::windows::connection::excepinfo_recovery_tests::{connection, Excuse};

    #[test]
    fn a_refused_calibrator_brightness_says_why() {
        let (device, _) = connection(
            Excuse::Spoken {
                source: "ASCOM.FlatPanel.CoverCalibrator",
                description: "Brightness 5000 exceeds MaxBrightness",
                scode: 0x8004_0402_u32 as i32,
            },
            false,
        );
        let panel = CoverCalibrator { device };

        let err = panel.calibrator_on(5000).unwrap_err().to_string();

        assert!(
            err.contains("Brightness 5000 exceeds MaxBrightness"),
            "CalibratorOn dropped the driver's description: {err}"
        );
        assert!(
            !err.contains("Exception occurred"),
            "fell back to the bare HRESULT: {err}"
        );
    }
}
