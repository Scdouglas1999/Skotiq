//! Alpaca Cover Calibrator API implementation

alpaca_device!(
    /// Alpaca Cover Calibrator client
    AlpacaCoverCalibrator,
    CoverCalibrator
);

impl AlpacaCoverCalibrator {
    skotiq_device::ascom_cover_calibrator_members!(alpaca_member);
}
