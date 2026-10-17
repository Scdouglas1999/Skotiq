//! Flat-panel device dance (cover open/close, calibrator on/off,
//! brightness adjustment, slewing for sky-flat positioning).
//!
//! Kept out of the `mod.rs` wizard implementation so that reads as a
//! clean state machine.
//! Teardown is fail-closed: a run cannot report success unless the
//! calibrator is confirmed off and the cover is confirmed closed.

use super::PanelLocation;
use crate::instructions::InstructionContext;
use crate::wizard::{wait_for_slew_complete, WizardProgressReporter};
use crate::FlatWizardConfig;
use std::sync::atomic::{AtomicBool, Ordering};

/// Poll the cover state until `target_state` is observed, the
/// cancellation token is set (when `cancellable`), or `timeout`
/// elapses. State 5 (Error) short-circuits to an error.
async fn wait_for_cover_state(
    ctx: &InstructionContext,
    device_id: &str,
    target_state: i32,
    timeout: std::time::Duration,
    poll_ms: u64,
    cancellable: bool,
) -> Result<(), String> {
    let start = std::time::Instant::now();
    loop {
        if cancellable && ctx.cancellation_token.load(Ordering::Relaxed) {
            return Err("Operation cancelled".to_string());
        }
        let state = ctx
            .device_ops
            .cover_calibrator_get_cover_state(device_id)
            .await
            .map_err(|e| format!("Failed to read cover state: {}", e))?;
        if state == target_state {
            return Ok(());
        }
        if state == 5 {
            return Err("Cover reported error state".to_string());
        }
        if start.elapsed() > timeout {
            return Err(format!(
                "Timeout waiting for cover to reach state {}",
                target_state
            ));
        }
        tokio::time::sleep(std::time::Duration::from_millis(poll_ms)).await;
    }
}

/// Poll the calibrator state until `target_state` is observed or timeout.
async fn wait_for_calibrator_state(
    ctx: &InstructionContext,
    device_id: &str,
    target_state: i32,
    timeout: std::time::Duration,
    poll_ms: u64,
    cancellable: bool,
) -> Result<(), String> {
    let start = std::time::Instant::now();
    loop {
        if cancellable && ctx.cancellation_token.load(Ordering::Relaxed) {
            return Err("Operation cancelled".to_string());
        }
        let state = ctx
            .device_ops
            .cover_calibrator_get_calibrator_state(device_id)
            .await
            .map_err(|e| format!("Failed to read calibrator state: {}", e))?;
        if state == target_state {
            return Ok(());
        }
        if state == 5 {
            return Err("Calibrator reported error state".to_string());
        }
        if start.elapsed() > timeout {
            return Err(format!(
                "Timeout waiting for calibrator to reach state {}",
                target_state
            ));
        }
        tokio::time::sleep(std::time::Duration::from_millis(poll_ms)).await;
    }
}

/// Set up flat panel for taking flats (open cover, turn on light).
pub(super) async fn setup_flat_panel(
    ctx: &InstructionContext,
    brightness: i32,
    progress: &dyn WizardProgressReporter,
    cleanup_required: &AtomicBool,
) -> Result<(), String> {
    let device_id = match ctx.cover_calibrator_id.as_deref() {
        Some(id) => id,
        None => {
            tracing::warn!("No cover calibrator connected - proceeding without panel control");
            return Ok(());
        }
    };

    tracing::info!(
        "Setting up flat panel: opening cover and turning on light at brightness {}",
        brightness
    );

    progress.report(0.22, "Opening cover".to_string());
    tracing::info!("Opening cover...");
    if let Err(e) = ctx.device_ops.cover_calibrator_open_cover(device_id).await {
        return Err(format!("Failed to open cover: {}", e));
    }
    // The open command was accepted, so teardown must run even if
    // readiness polling or any later setup operation fails.
    cleanup_required.store(true, Ordering::Relaxed);
    wait_for_cover_state(
        ctx,
        device_id,
        3,
        std::time::Duration::from_secs(60),
        500,
        true,
    )
    .await?;
    tracing::info!("Cover opened");

    progress.report(0.25, "Turning on calibrator".to_string());
    tracing::info!("Turning on calibrator at brightness {}...", brightness);
    if let Err(e) = ctx
        .device_ops
        .cover_calibrator_calibrator_on(device_id, brightness)
        .await
    {
        return Err(format!("Failed to turn on calibrator: {}", e));
    }
    wait_for_calibrator_state(
        ctx,
        device_id,
        3,
        std::time::Duration::from_secs(30),
        200,
        true,
    )
    .await?;
    tracing::info!("Calibrator ready");

    Ok(())
}

/// Clean up flat panel after taking flats (turn off light, close cover).
pub(super) async fn cleanup_flat_panel(ctx: &InstructionContext) -> Result<(), String> {
    let cc_id = match ctx.cover_calibrator_id.as_deref() {
        Some(id) => id,
        None => return Ok(()),
    };

    tracing::info!("Cleaning up flat panel: turning off light and closing cover");

    let mut errors = Vec::new();

    if let Err(e) = ctx.device_ops.cover_calibrator_calibrator_off(cc_id).await {
        errors.push(format!("failed to turn off calibrator: {}", e));
    }

    if let Err(e) = ctx.device_ops.cover_calibrator_close_cover(cc_id).await {
        errors.push(format!("failed to close cover: {}", e));
    }

    let (calibrator_result, cover_result) = tokio::join!(
        wait_for_calibrator_state(
            ctx,
            cc_id,
            1,
            std::time::Duration::from_secs(30),
            200,
            false,
        ),
        wait_for_cover_state(
            ctx,
            cc_id,
            1,
            std::time::Duration::from_secs(30),
            500,
            false,
        )
    );

    if let Err(e) = calibrator_result {
        errors.push(format!("calibrator did not reach off state: {}", e));
    } else {
        tracing::info!("Calibrator off");
    }

    if let Err(e) = cover_result {
        errors.push(format!("cover did not reach closed state: {}", e));
    } else {
        tracing::info!("Cover closed");
    }

    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors.join("; "))
    }
}

/// Change flat panel brightness (used by auto-adjust brightness logic).
pub(super) async fn set_panel_brightness(
    ctx: &InstructionContext,
    brightness: i32,
) -> Result<(), String> {
    let cc_id = match ctx.cover_calibrator_id.as_deref() {
        Some(id) => id,
        None => return Ok(()),
    };

    tracing::info!("Adjusting flat panel brightness to {}", brightness);

    ctx.device_ops
        .cover_calibrator_calibrator_on(cc_id, brightness)
        .await?;

    // Wait for calibrator to stabilize (10s timeout, non-cancellable to
    // match `set_panel_brightness`).
    let _ = wait_for_calibrator_state(
        ctx,
        cc_id,
        3,
        std::time::Duration::from_secs(10),
        200,
        false,
    )
    .await;

    Ok(())
}

/// Position mount for flat-field acquisition. Slews to zenith for flat-
/// panel mode, or to alt 65° / az 90° (dawn) | 270° (dusk) for sky flats.
pub(super) async fn position_for_flats(
    config: &FlatWizardConfig,
    ctx: &InstructionContext,
    progress: &dyn WizardProgressReporter,
) -> Result<(), String> {
    match config.panel_location {
        PanelLocation::FlatPanel => {
            tracing::info!("Positioning for flat panel");

            if let Some(mount_id) = &ctx.mount_id {
                progress.report(0.12, "Slewing to zenith".to_string());

                let (lat, lon) = ctx.device_ops.get_observer_location().ok_or_else(|| {
                    "Observer location is required for flat-panel positioning".to_string()
                })?;

                let now = chrono::Utc::now();
                let jd = crate::node::julian_day(&now);
                let lst = crate::node::local_sidereal_time(jd, lon);

                // Zenith: RA = LST, Dec = latitude
                let zenith_ra = lst;
                let zenith_dec = lat;

                tracing::info!(
                    "Slewing to zenith: RA={:.4}h, Dec={:.4}",
                    zenith_ra,
                    zenith_dec
                );

                ctx.device_ops
                    .mount_slew_to_coordinates(mount_id, zenith_ra, zenith_dec)
                    .await
                    .map_err(|e| format!("Failed to slew to zenith: {}", e))?;

                progress.report(0.15, "Waiting for slew to complete".to_string());
                wait_for_slew_complete(ctx, mount_id, 300, "Slew to zenith").await?;
            }

            Ok(())
        }
        PanelLocation::DawnSky | PanelLocation::DuskSky => {
            tracing::info!("Positioning for {:?} sky flats", config.panel_location);

            if let Some(mount_id) = &ctx.mount_id {
                let (lat, lon) = ctx.device_ops.get_observer_location().ok_or_else(|| {
                    "Observer location is required for sky-flat positioning".to_string()
                })?;

                progress.report(
                    0.12,
                    format!("Slewing for {:?} sky flats", config.panel_location),
                );

                // Sky flats are typically taken at ~60-70 altitude.
                // Dawn: point east (azimuth ~90); Dusk: point west (azimuth ~270).
                let target_altitude = 65.0;
                let target_azimuth = match config.panel_location {
                    PanelLocation::DawnSky => 90.0,
                    PanelLocation::DuskSky => 270.0,
                    PanelLocation::FlatPanel => {
                        return Err("Invalid panel location for sky-flat positioning".to_string());
                    }
                };

                let (ra, dec) = altaz_to_radec(target_altitude, target_azimuth, lat, lon);

                tracing::info!(
                    "Slewing to sky flat position: Alt={:.1}, Az={:.1} (RA={:.4}h, Dec={:.4})",
                    target_altitude,
                    target_azimuth,
                    ra,
                    dec
                );

                ctx.device_ops
                    .mount_slew_to_coordinates(mount_id, ra, dec)
                    .await
                    .map_err(|e| format!("Failed to slew for sky flats: {}", e))?;

                progress.report(0.15, "Waiting for slew to complete".to_string());
                wait_for_slew_complete(ctx, mount_id, 300, "Slew to sky flat position").await?;
            }

            Ok(())
        }
    }
}

/// Convert altitude/azimuth to RA/Dec for the current observer time.
pub(super) fn altaz_to_radec(
    altitude_deg: f64,
    azimuth_deg: f64,
    latitude_deg: f64,
    longitude_deg: f64,
) -> (f64, f64) {
    let now = chrono::Utc::now();
    let jd = crate::node::julian_day(&now);
    let lst = crate::node::local_sidereal_time(jd, longitude_deg);

    let alt_rad = altitude_deg.to_radians();
    let az_rad = azimuth_deg.to_radians();
    let lat_rad = latitude_deg.to_radians();

    let dec_rad =
        (alt_rad.sin() * lat_rad.sin() + alt_rad.cos() * lat_rad.cos() * az_rad.cos()).asin();
    let dec_deg = dec_rad.to_degrees();

    let ha_rad = (az_rad.sin() * alt_rad.cos() / (lat_rad.cos() * dec_rad.cos()))
        .atan2(alt_rad.sin() - lat_rad.sin() * dec_rad.sin());
    let ha_hours = ha_rad.to_degrees() / 15.0;

    let ra_hours = (lst - ha_hours + 24.0) % 24.0;

    (ra_hours, dec_deg)
}
