use super::*;

#[async_trait]
impl PlateSolveOps for UnifiedDeviceOps {
    async fn plate_solve(
        &self,
        image_data: &ImageData,
        hint_ra: Option<f64>,
        hint_dec: Option<f64>,
        hint_scale: Option<f64>,
    ) -> DeviceResult<PlateSolveResult> {
        tracing::info!("Plate solving image");

        let temp_file = create_unique_temp_fits_path("skotiq_platesolve_temp");
        let temp_path = temp_file.to_string_lossy().to_string();

        // The optics, so the solver is told the field scale instead of hunting
        // for it. With `focal_length` and the pixel pitch left as None, ASTAP
        // gets a header with no scale information and falls back to sweeping
        // the field of view downward from ~9.5°. Observed live on a 0.37°
        // field: one run reached the bottom rung and solved in 0.3 s (still
        // warning "scale was inaccurate"), and the next three never converged
        // and exited non-zero on all five centering attempts. Same code, same
        // catalogs, same sensor — the only variable was whether the blind
        // sweep happened to land.
        //
        // Gathered by the shared helper so this is the same header every other
        // production solve path writes.
        let scale = crate::api::plate_solve::gather_solve_hints().await;
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
        let result = if let (Some(ra), Some(dec)) = (hint_ra, hint_dec) {
            crate::api::plate_solve::plate_solve_near_scaled(
                temp_path.clone(),
                ra,
                dec,
                SEARCH_RADIUS_DEG,
                None,
                scale_hint,
                None,
            )
            .await
        } else {
            crate::api::plate_solve::plate_solve_blind_scaled(
                temp_path.clone(),
                None,
                scale_hint,
                None,
            )
            .await
        };

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
                "solver_path": crate::api::plate_solve::api_get_plate_solver_path(),
                "error": error,
                }),
            )
            .await;
        }
        let _ = std::fs::remove_file(&temp_path);

        // What this rig's own optics measure, remembered for the next solve.
        // A run whose profile carries no focal length gets exactly one blind
        // sweep and is hinted from then on — which is the difference between
        // the drift-recenter that timed out on 2026-09-15 and one that solves
        // in under a second. Recorded only from a solve that reported success
        // AND a usable scale; a failed solve measures nothing.
        if let Ok(solved) = result.as_ref() {
            if solved.success {
                scale.record_measured_scale(solved.pixel_scale);
            }
        }

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
                wcs: solved_wcs(&r, solved_width, solved_height),
            })
            .map_err(|e| format!("Plate solve failed: {}", e).into())
    }
}

/// The WCS of a successful solve of a `width` x `height` frame.
pub(crate) fn solved_wcs(
    solved: &crate::api::plate_solve::PlateSolveResult,
    width: u32,
    height: u32,
) -> Option<skotiq_imaging::SipWcs> {
    skotiq_imaging::SipWcs::from_plate_solve(&solved.into(), width, height)
}

#[cfg(test)]
mod solved_wcs_tests {
    use super::solved_wcs;

    fn solve(success: bool) -> crate::api::plate_solve::PlateSolveResult {
        crate::api::plate_solve::PlateSolveResult {
            success,
            ra: 40.1,
            dec: 42.3,
            pixel_scale: 1.46,
            rotation: 12.0,
            field_width: 0.78,
            field_height: 0.44,
            solve_time_secs: 0.1,
            error: None,
            cd1_1: -3.9e-4,
            cd1_2: 1.0e-5,
            cd2_1: 1.1e-5,
            cd2_2: 4.0e-4,
            sip_a_order: 0,
            sip_b_order: 0,
            sip_a_coeffs: vec![],
            sip_b_coeffs: vec![],
            sip_ap_order: 0,
            sip_bp_order: 0,
            sip_ap_coeffs: vec![],
            sip_bp_coeffs: vec![],
        }
    }

    /// The frame's WCS is the solver's CD matrix anchored at the frame's
    /// centre; a failed solve gives none.
    #[test]
    fn a_solve_gives_the_frame_its_wcs() {
        let wcs = solved_wcs(&solve(true), 1920, 1080).expect("a solve has a WCS");
        assert_eq!((wcs.crval1, wcs.crval2), (40.1, 42.3));
        assert_eq!((wcs.crpix1, wcs.crpix2), (960.5, 540.5));
        assert_eq!(
            (wcs.cd1_1, wcs.cd1_2, wcs.cd2_1, wcs.cd2_2),
            (-3.9e-4, 1.0e-5, 1.1e-5, 4.0e-4)
        );
        assert!(solved_wcs(&solve(false), 1920, 1080).is_none());
    }

    /// The solver's SIP distortion is part of the frame's WCS.
    #[test]
    fn the_frame_wcs_keeps_the_solvers_distortion() {
        let mut result = solve(true);
        result.sip_a_order = 2;
        result.sip_b_order = 2;
        result.sip_a_coeffs = vec![0.0, 0.0, 5e-7, 0.0, -8e-7, 0.0, 1.2e-6, 0.0, 0.0];
        result.sip_b_coeffs = vec![0.0, 0.0, -1.1e-6, 0.0, 9e-7, 0.0, -6e-7, 0.0, 0.0];
        let wcs = solved_wcs(&result, 1920, 1080).expect("a solve has a WCS");
        assert_eq!((wcs.a_order, wcs.b_order), (2, 2));
        assert_eq!(wcs.a_coeffs, result.sip_a_coeffs);
        assert_eq!(wcs.b_coeffs, result.sip_b_coeffs);
    }

    /// A solver that gave no CD matrix still gives a WCS, from its scale and
    /// rotation.
    #[test]
    fn without_a_cd_matrix_the_scale_and_rotation_are_used() {
        let mut result = solve(true);
        result.cd1_1 = 0.0;
        result.cd1_2 = 0.0;
        result.cd2_1 = 0.0;
        result.cd2_2 = 0.0;
        let wcs = solved_wcs(&result, 100, 100).expect("a solve has a WCS");
        let scale = (wcs.cd1_1 * wcs.cd2_2 - wcs.cd1_2 * wcs.cd2_1).abs().sqrt() * 3600.0;
        assert!((scale - 1.46).abs() < 1e-9, "scale {scale}");
    }
}
