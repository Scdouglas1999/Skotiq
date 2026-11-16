use super::UnifiedDeviceOps;
use crate::device::DeviceType;
use crate::device_manager::get_device_manager;
use async_trait::async_trait;
use skotiq_sequencer::{DeviceResult, ImageData, PlateSolveOps, PlateSolveResult};
use std::sync::atomic::{AtomicBool, Ordering};

#[async_trait]
impl PlateSolveOps for UnifiedDeviceOps {
    async fn plate_solve(
        &self,
        image_data: &ImageData,
        hint_ra: Option<f64>,
        hint_dec: Option<f64>,
        hint_scale: Option<f64>,
    ) -> DeviceResult<PlateSolveResult> {
        if !solver_installed() {
            return Err(skotiq_sequencer::DeviceError::NO_PLATE_SOLVER);
        }
        tracing::info!("Plate solving image");

        let temp_file =
            crate::util::temp_fits::create_unique_temp_fits_path("skotiq_platesolve_temp");
        let temp_path = temp_file.to_string_lossy().to_string();

        // The optics, so the solver is told the field scale instead of hunting
        // for it. With no focal length or pixel pitch ASTAP sweeps the field of
        // view down from ~9.5°, and on a small field whether that sweep lands
        // is chance.
        //
        // Gathered by the shared helper so this is the same header every other
        // production solve path writes.
        let scale = crate::solver::gather_solve_hints().await;
        scale.log_scale("Plate solve");
        let binning = scale.hints.binning;
        // The header is written for ASTAP to read; the same number also goes
        // out as an explicit `-fov` argument, because a header card is a hope
        // and an argument is an instruction. `hint_scale` from the caller wins
        // when it is a real measurement.
        let scale_hint = hint_scale
            .filter(|s| s.is_finite() && *s > 0.0)
            .or_else(|| scale.arcsec_per_px());

        let header = crate::frame_header::FrameHeader {
            ra: hint_ra.map(|r| r / 15.0),
            dec: hint_dec,
            ..scale.hints.solve_frame_header(image_data)
        };

        crate::frame_header::write_capture_frame(
            temp_path.clone(),
            image_data.width,
            image_data.height,
            image_data.data.clone(),
            header,
        )
        .await
        .map_err(|e| format!("Failed to save temp FITS for plate solve: {}", e))?;

        let mount_id = self
            .app_state
            .get_profile_device_id(DeviceType::Mount)
            .await;
        let mount_before_solve = if let Some(id) = mount_id.as_ref() {
            match tokio::time::timeout(
                std::time::Duration::from_secs(2),
                get_device_manager().mount_get_status(id),
            )
            .await
            {
                Ok(Ok(status)) => serde_json::json!(status),
                other => serde_json::json!({"unavailable": format!("{other:?}")}),
            }
        } else {
            serde_json::Value::Null
        };
        let solve_started_at = chrono::Utc::now();

        // Use the near solve if we have a position, otherwise blind — and
        // either way send the field scale.
        //
        // The 5.0° search radius is the Skotiq default for a near solve
        // and matches the plate-solve UI slider default. It is a literal, not
        // `hint_scale`: degrees of search radius and arcsec/pixel of sampling
        // are not interchangeable, and feeding either a field scale or a solve
        // timeout through this slot silently sets an absurd radius.
        const SEARCH_RADIUS_DEG: f64 = 5.0;
        let position =
            hint_ra
                .zip(hint_dec)
                .map(|(ra_degrees, dec_degrees)| crate::solver::SolvePosition {
                    ra_degrees,
                    dec_degrees,
                    search_radius_deg: SEARCH_RADIUS_DEG,
                });
        let result = crate::solver::solve(
            &temp_path,
            crate::solver::SolveRequest {
                position,
                frame_scale: hint_scale,
                scale: &scale,
                timeout_secs: None,
                downsample: None,
            },
        )
        .await;

        let failure = match &result {
            Ok(solved) if solved.success => None,
            Ok(solved) => Some(solved.error.clone().unwrap_or_else(|| "No solution".into())),
            Err(error) => Some(error.to_string()),
        };
        if let Some(error) = failure {
            super::solve_diagnostics::retain_failed_solve(
                temp_file.clone(),
                serde_json::json!({
                "solve_started_at": solve_started_at.to_rfc3339(),
                "capture_timestamp_unix_seconds": image_data.timestamp,
                "exposure_secs": image_data.exposure_secs,
                "width": image_data.width, "height": image_data.height,
                "gain": image_data.gain, "offset": image_data.offset,
                "temperature_c": image_data.temperature, "filter": image_data.filter,
                "binning": binning, "hint_ra_degrees": hint_ra,
                "hint_dec_degrees": hint_dec, "hint_scale_arcsec_per_px": scale_hint,
                "search_radius_degrees": SEARCH_RADIUS_DEG,
                "mount_id": mount_id, "mount_sample_before_solve": mount_before_solve,
                "solver_path": skotiq_platesolve::get_solver_path().map(|p| p.display().to_string()),
                "error": error,
                }),
            )
            .await;
        }
        let _ = std::fs::remove_file(&temp_path);

        let (solved_width, solved_height) = (image_data.width, image_data.height);
        result
            .map(|r| PlateSolveResult {
                ra_degrees: r.ra,
                dec_degrees: r.dec,
                pixel_scale: r.pixel_scale,
                rotation: r.rotation,
                up_position_angle_deg: skotiq_sequencer::up_position_angle_deg(
                    r.cd1_2, r.cd2_2, r.rotation,
                ),
                success: r.success,
                wcs: skotiq_imaging::SipWcs::from_plate_solve(&r, solved_width, solved_height),
            })
            .map_err(|e| format!("Plate solve failed: {}", e).into())
    }
}

/// Whether a plate solver program is installed. The first solve asked for
/// without one says so in the log; the next one after a solver is set up says
/// nothing until it is gone again.
fn solver_installed() -> bool {
    static TOLD_MISSING: AtomicBool = AtomicBool::new(false);
    let installed = skotiq_platesolve::is_solver_available();
    if first_report_of_missing_solver(installed, &TOLD_MISSING) {
        tracing::warn!("{}", skotiq_sequencer::DeviceError::NO_PLATE_SOLVER);
    }
    installed
}

/// True the first time `installed` is false since it was last true.
fn first_report_of_missing_solver(installed: bool, told_missing: &AtomicBool) -> bool {
    let told = told_missing.swap(!installed, Ordering::Relaxed);
    !installed && !told
}

#[cfg(test)]
mod missing_solver_tests {
    use super::first_report_of_missing_solver;
    use std::sync::atomic::AtomicBool;

    /// A missing solver is told once, not once per frame, and again only after
    /// a solver was set up and went missing once more.
    #[test]
    fn a_missing_solver_is_told_once_per_absence() {
        let told = AtomicBool::new(false);
        let reports: Vec<bool> = [false, false, false, true, false, false]
            .into_iter()
            .map(|installed| first_report_of_missing_solver(installed, &told))
            .collect();
        assert_eq!(reports, [true, false, false, false, true, false]);
    }
}
