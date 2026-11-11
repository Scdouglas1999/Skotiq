//! ASCOM Cover Calibrator wrapper and batch status types.

use crate::com::ComDispatch;

com_device!(
    /// ASCOM Cover Calibrator
    CoverCalibrator
);

impl<D: ComDispatch> CoverCalibrator<D> {
    skotiq_device::ascom_cover_calibrator_members!(com_member);

    // Batch property queries

    /// Get complete cover calibrator status in a single batch operation
    pub fn get_full_status(&self) -> CoverCalibratorFullStatus {
        CoverCalibratorFullStatus {
            cover_state: self.cover_state().ok(),
            calibrator_state: self.calibrator_state().ok(),
            brightness: self.brightness().ok(),
            max_brightness: self.max_brightness().ok(),
        }
    }
}

/// Full cover calibrator status
#[derive(Debug, Clone, Default)]
pub struct CoverCalibratorFullStatus {
    /// Cover state (0=NotPresent, 1=Closed, 2=Moving, 3=Open, 4=Unknown, 5=Error)
    pub cover_state: Option<i32>,
    /// Calibrator state (0=NotPresent, 1=Off, 2=NotReady, 3=Ready, 4=Unknown, 5=Error)
    pub calibrator_state: Option<i32>,
    pub brightness: Option<i32>,
    pub max_brightness: Option<i32>,
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
        let mut panel = CoverCalibrator { device };

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
