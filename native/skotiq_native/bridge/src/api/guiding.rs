//! The guider the rig guides with, PHD2 or the built-in multi-star guider,
//! as Dart sees it. The work is done by [`crate::guider`]; these entry points
//! only cross the bridge. Which guider answers is the guider service's choice
//! (the profile's guider, see [`crate::guider::Guider::active`]).

use crate::error::SkotiqError;
use crate::guider::{GuideStarImage, Guider, GuiderCalibration, GuiderStatus};

/// The built-in guider's settings.
#[derive(Clone, Debug)]
pub struct BuiltinGuiderConfig {
    pub exposure_secs: f64,
    pub gain: i32,
    pub offset: i32,
    pub binning: i32,
    pub calibration_ms: u32,
    pub settle_sleep_ms: u64,
    pub min_pulse_ms: f64,
    pub max_pulse_ms: f64,
}

async fn active() -> Result<Guider, SkotiqError> {
    Guider::active()
        .await?
        .ok_or_else(|| SkotiqError::NotConnected("Guider".to_string()))
}

/// Start guiding and wait for it to settle.
pub async fn api_guider_start_guiding(
    settle_pixels: f64,
    settle_time: f64,
    settle_timeout: f64,
) -> Result<(), SkotiqError> {
    active()
        .await?
        .start(settle_pixels, settle_time, settle_timeout)
        .await
}

/// Stop guiding from the guider controls.
pub async fn api_guider_stop() -> Result<(), SkotiqError> {
    active().await?.stop_by_operator().await
}

/// Dither and wait for the guider to settle.
pub async fn api_guider_dither(
    amount: f64,
    ra_only: bool,
    settle_pixels: f64,
    settle_time: f64,
    settle_timeout: f64,
) -> Result<(), SkotiqError> {
    active()
        .await?
        .dither(amount, ra_only, settle_pixels, settle_time, settle_timeout)
        .await
}

/// Take guide frames without guiding.
pub async fn api_guider_loop() -> Result<(), SkotiqError> {
    active().await?.loop_exposures().await
}

/// Pause guide corrections, or resume them.
pub async fn api_guider_set_paused(paused: bool) -> Result<(), SkotiqError> {
    active().await?.set_paused(paused).await
}

/// Pick a guide star in the current frame; its position in frame pixels.
pub async fn api_guider_find_star() -> Result<(f64, f64), SkotiqError> {
    active().await?.find_star().await
}

pub async fn api_guider_set_lock_position(x: f64, y: f64, exact: bool) -> Result<(), SkotiqError> {
    active().await?.set_lock_position(x, y, exact).await
}

pub async fn api_guider_get_lock_position() -> Result<(f64, f64), SkotiqError> {
    active().await?.lock_position().await
}

pub async fn api_guider_deselect_star() -> Result<(), SkotiqError> {
    active().await?.deselect_star().await
}

pub async fn api_guider_get_star_image(size: u32) -> Result<GuideStarImage, SkotiqError> {
    active().await?.star_image(size).await
}

pub async fn api_guider_get_status() -> Result<GuiderStatus, SkotiqError> {
    active().await?.status().await
}

pub async fn api_guider_get_calibration() -> Result<GuiderCalibration, SkotiqError> {
    active().await?.calibration().await
}

pub async fn api_builtin_guider_get_config() -> Result<BuiltinGuiderConfig, SkotiqError> {
    let config = crate::builtin_guider::get_config().await;
    Ok(BuiltinGuiderConfig {
        exposure_secs: config.exposure_secs,
        gain: config.gain,
        offset: config.offset,
        binning: config.binning,
        calibration_ms: config.calibration_ms,
        settle_sleep_ms: config.settle_sleep_ms,
        min_pulse_ms: config.min_pulse_ms,
        max_pulse_ms: config.max_pulse_ms,
    })
}

/// Set the built-in guider's settings; a running guider uses them from its
/// next frame.
pub async fn api_builtin_guider_set_config(
    exposure_secs: f64,
    gain: i32,
    offset: i32,
    binning: i32,
    calibration_ms: u32,
    settle_sleep_ms: u64,
    min_pulse_ms: f64,
    max_pulse_ms: f64,
) -> Result<(), SkotiqError> {
    crate::builtin_guider::set_config(crate::builtin_guider::GuiderConfig {
        exposure_secs,
        gain,
        offset,
        binning,
        calibration_ms,
        settle_sleep_ms,
        min_pulse_ms,
        max_pulse_ms,
        // Aggressiveness, minimum move and Dec backlash keep their tuned
        // defaults; no settings page offers them.
        ..crate::builtin_guider::GuiderConfig::default()
    })
    .await;
    Ok(())
}
