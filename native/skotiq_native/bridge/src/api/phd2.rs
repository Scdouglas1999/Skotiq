//! PHD2's connection and the settings only PHD2 has (its guide algorithm,
//! calibration store, exposure and profile). Guiding itself goes through
//! [`super::guiding`], whichever guider the rig uses.

use crate::error::SkotiqError;
use crate::guider::phd2;

/// Connect to PHD2's event server (default 127.0.0.1:4400).
pub async fn api_phd2_connect(host: Option<String>, port: Option<u16>) -> Result<(), SkotiqError> {
    phd2::connect(host, port).await
}

pub async fn api_phd2_disconnect() -> Result<(), SkotiqError> {
    phd2::disconnect().await
}

/// Start the PHD2 program installed on this machine.
pub fn api_launch_phd2() -> Result<(), SkotiqError> {
    skotiq_imaging::launch_phd2()
        .map_err(|e| SkotiqError::OperationFailed(format!("Failed to launch PHD2: {}", e)))
}

/// The names of PHD2's guide algorithm parameters for `axis` ("ra" or "dec").
pub async fn api_phd2_get_algo_param_names(axis: String) -> Result<Vec<String>, SkotiqError> {
    phd2::algo_param_names(&axis).await
}

pub async fn api_phd2_get_algo_param(axis: String, name: String) -> Result<f64, SkotiqError> {
    phd2::algo_param(&axis, &name).await
}

pub async fn api_phd2_set_algo_param(
    axis: String,
    name: String,
    value: f64,
) -> Result<(), SkotiqError> {
    phd2::set_algo_param(&axis, &name, value).await
}

/// Clear PHD2's stored calibration (`which`: "mount", "ao" or "both").
pub async fn api_phd2_clear_calibration(which: String) -> Result<(), SkotiqError> {
    phd2::clear_calibration(&which).await
}

/// Flip PHD2's calibration after a meridian flip.
pub async fn api_phd2_flip_calibration() -> Result<(), SkotiqError> {
    phd2::flip_calibration().await
}

/// PHD2's guide exposure in milliseconds.
pub async fn api_phd2_get_exposure() -> Result<u32, SkotiqError> {
    phd2::exposure_ms().await
}

pub async fn api_phd2_set_exposure(exposure_ms: u32) -> Result<(), SkotiqError> {
    phd2::set_exposure_ms(exposure_ms).await
}

/// The name of the equipment profile PHD2 has selected.
pub async fn api_phd2_get_profile() -> Result<String, SkotiqError> {
    phd2::profile().await
}
