//! Alpaca Cover Calibrator API implementation

use crate::AlpacaError;
use skotiq_device::ascom::{CalibratorStatus, CoverStatus};

alpaca_device!(
    /// Alpaca Cover Calibrator client
    AlpacaCoverCalibrator,
    CoverCalibrator
);

impl AlpacaCoverCalibrator {
    skotiq_device::ascom_cover_calibrator_members!(alpaca_member);

    /// Get comprehensive cover calibrator status
    pub async fn get_status(&self) -> Result<CoverCalibratorStatus, AlpacaError> {
        let (cover_state, calibrator_state, brightness) = tokio::join!(
            self.cover_state(),
            self.calibrator_state(),
            self.brightness(),
        );

        Ok(CoverCalibratorStatus {
            cover_state: cover_state?,
            calibrator_state: calibrator_state?,
            brightness: brightness.ok(),
        })
    }
}

#[derive(Debug, Clone)]
pub struct CoverCalibratorStatus {
    pub cover_state: CoverStatus,
    pub calibrator_state: CalibratorStatus,
    pub brightness: Option<i32>,
}
