use super::*;

/// Start three-point polar alignment
///
/// This initiates the polar alignment process which will:
/// 1. Capture 3 images at different mount rotations
/// 2. Plate solve each image
/// 3. Calculate the center of rotation
/// 4. Enter adjustment mode with real-time error updates
///
/// Note: Requires connected camera and mount devices.
pub async fn api_start_polar_alignment(
    exposure_time: f64,
    step_size: f64,
    binning: i32,
    is_north: bool,
    manual_rotation: bool,
    rotate_east: bool,
    gain: Option<i32>,
    offset: Option<i32>,
    solve_timeout: Option<f64>,
    start_from_current: Option<bool>,
    auto_complete_threshold: Option<f64>,
) -> Result<(), SkotiqError> {
    // Hold through task-handle publication so Stop cannot clear ownership in
    // the admission→spawn gap and leave an untracked task running.
    let _control = polar_control_lock().lock().await;

    let generation = try_admit_polar_run().ok_or_else(|| {
        SkotiqError::OperationFailed("Polar alignment already running".to_string())
    })?;

    tracing::info!(
        "Starting polar alignment (gen {generation}): exposure={}s, step={}°, binning={}, north={}, manual={}, east={}",
        exposure_time, step_size, binning, is_north, manual_rotation, rotate_east
    );

    // Get connected devices using existing API
    let connected = api_get_connected_devices().await;

    // Find connected camera
    let camera_id = connected
        .iter()
        .find(|d| d.device_type == DeviceType::Camera)
        .map(|d| d.id.clone());

    // Find connected mount
    let mount_id = connected
        .iter()
        .find(|d| d.device_type == DeviceType::Mount)
        .map(|d| d.id.clone());

    let camera_id = camera_id.ok_or_else(|| {
        release_polar_run_if_current(generation);
        SkotiqError::DeviceNotFound("No camera connected".to_string())
    })?;

    let mount_id = mount_id.ok_or_else(|| {
        release_polar_run_if_current(generation);
        SkotiqError::DeviceNotFound("No mount connected".to_string())
    })?;

    // Only the non-hardware options carry a fixed default. gain/offset stay
    // `Option` and are threaded through so `None` means "use the camera's
    // current value" — never forced to 0.
    let solve_timeout_val = solve_timeout.unwrap_or(DEFAULT_POLAR_SOLVE_TIMEOUT_SECS);
    let start_from_current_val = start_from_current.unwrap_or(true);
    let auto_complete_threshold_val = auto_complete_threshold.unwrap_or(1.0); // Default 1 arcminute

    // Accurate physical altitude/azimuth correction directions require the
    // observer's horizontal frame, even when measuring from the current
    // pointing. Resolve the site up front instead of labelling equatorial
    // tangent components as mount-bolt directions.
    let location_for_run = get_state()
        .get_observer_location()
        .map_err(|e| {
            release_polar_run_if_current(generation);
            SkotiqError::OperationFailed(format!("Failed to read observer location: {}", e))
        })?
        .ok_or_else(|| {
            release_polar_run_if_current(generation);
            SkotiqError::OperationFailed(
                "Observer latitude/longitude is required for polar alignment correction directions. \
                 Set your site location before starting."
                    .to_string(),
            )
        })?;

    let handle = crate::util::supervisor::spawn_supervised_oneshot(
        "polar_align_monitor",
        async move {
            let result = run_polar_alignment(
                camera_id,
                mount_id,
                exposure_time,
                step_size,
                binning,
                is_north,
                manual_rotation,
                rotate_east,
                start_from_current_val,
                gain,
                offset,
                solve_timeout_val,
                auto_complete_threshold_val,
                location_for_run.latitude,
                location_for_run.longitude,
                generation,
            )
            .await;

            if let Err(e) = result {
                // Only surface an error over the status channel if we still own
                // the run; a superseded/aborted task must stay silent.
                if polar_generation().load(PolarOrdering::Relaxed) == generation {
                    tracing::error!("Polar alignment failed: {}", e);
                    emit_polar_status(&format!("Error: {}", e), "error", 0);
                }
            }

            release_polar_run_if_current(generation);
        },
        // If the polar-align task panics, the busy flag would otherwise remain
        // stuck `true` forever and the user could never restart it. Clear the
        // flag (only if still ours) and surface the panic via the status
        // channel.
        Some(move |panic_msg: &str| {
            if polar_generation().load(PolarOrdering::Relaxed) == generation {
                emit_polar_status(&format!("Polar alignment crashed: {panic_msg}"), "error", 0);
            }
            release_polar_run_if_current(generation);
        }),
    );

    // Hand the owned task handle to the stop path so a subsequent stop can
    // await real termination.
    store_polar_task(handle).await;

    Ok(())
}

/// Above this the fitted axis says more about the measurement than the mount.
///
/// The unit is degrees of axis movement per arcminute of error in one of the
/// three points. The default 15° step measures at about 0.50, a 10° step at
/// 1.13 and a 30° step at 0.13 (pinned by
/// `a_short_arc_multiplies_one_points_error_into_the_axis`), so this sits just
/// above the default: a run with a SHORTER arc than the default gets told what
/// its arc is costing it. Plate-solve error alone is a fraction of an
/// arcminute and survives this; a mount that wanders arcminutes between points
/// does not.
const MAX_TRUSTWORTHY_AXIS_SENSITIVITY: f64 = 0.6;

/// Internal function to run the polar alignment process
pub(crate) async fn run_polar_alignment(
    camera_id: String,
    mount_id: String,
    exposure_time: f64,
    step_size: f64,
    binning: i32,
    is_north: bool,
    manual_rotation: bool,
    rotate_east: bool,
    start_from_current: bool,
    gain: Option<i32>,
    offset: Option<i32>,
    solve_timeout_secs: f64,
    auto_complete_threshold: f64,
    observer_latitude: f64,
    observer_longitude: f64,
    generation: u64,
) -> Result<(), String> {
    // Slew-to-pole start mode: point the mount at the pole region before
    // measuring, instead of measuring from wherever it currently points.
    if !start_from_current {
        match slew_to_pole_region(&mount_id, is_north, observer_longitude, generation).await? {
            SlewOutcome::Settled => {}
            SlewOutcome::Cancelled => {
                emit_polar_status("Cancelled by user", "idle", 0);
                return Ok(());
            }
            SlewOutcome::Superseded => return Ok(()),
        }
    }

    let mut solved_points: Vec<(f64, f64)> = Vec::new();

    // The declination every rotation step holds, read ONCE.
    //
    // Three-point alignment measures a rotation about one axis, so the three
    // points must lie on one small circle. Re-reading the mount's declination
    // before each step and commanding *that* feeds every step's pointing error
    // back into the trajectory: on the owner's rig the mount reported
    // Dec 58.2744° at point 1 and 58.4058° at point 2, so point 3 was
    // commanded 8 arcmin off point 1's circle. Over the short arc these runs
    // use, 8 arcmin of declination is several degrees of fitted axis. Holding
    // the first reading instead makes each step correct that drift rather than
    // inherit it. A mount that cannot report its position falls back to the
    // per-step read.
    let hold_dec_degrees = match get_device_manager().mount_get_status(&mount_id).await {
        Ok(status) => Some(status.declination),
        Err(e) => {
            tracing::warn!(
                "Polar alignment: could not read the mount declination to hold across the \
                 rotation steps ({}); each step will hold whatever it reads",
                e
            );
            None
        }
    };

    // The field scale, read once for the run: the optics and the sensor do not
    // change between the three measurement frames. The pitch is asked of the
    // camera this run is imaging through — not the profile's imaging camera,
    // which polar alignment is often not using — and scaled by the binning
    // these frames are actually being taken at, which the camera has not been
    // set to yet at this point.
    let mut solve_scale = gather_solve_hints_for_camera(Some(&camera_id)).await;
    if binning > 0 {
        solve_scale.hints.binning = (binning, binning);
    }
    solve_scale.log_scale("Polar alignment solve");
    // ...and the number that log line prints is the number the solver is
    // handed. It was computed, logged, and then dropped on the floor for three
    // release waves while every polar solve ran blind against a 0.4° field.
    let solve_scale_arcsec_per_px = solve_scale.arcsec_per_px();

    // Phase 1: Capture and solve 3 points
    for point in 1..=3 {
        // Check for cancellation / supersession before starting hardware work.
        match polar_loop_control(generation) {
            PolarLoopControl::Continue => {}
            PolarLoopControl::Superseded => return Ok(()),
            PolarLoopControl::Cancelled => {
                emit_polar_status("Cancelled by user", "idle", 0);
                return Ok(());
            }
        }

        emit_polar_status(
            &format!("Capturing point {}/3...", point),
            "measuring",
            point as i32,
        );

        // Capture image. gain/offset are Option — None leaves the camera's
        // current value untouched (never forced to 0).
        crate::api::imaging::camera_start_exposure_opt(
            camera_id.clone(),
            exposure_time,
            gain,
            offset,
            binning,
            binning,
        )
        .await
        .map_err(|e| format!("Failed to capture: {:?}", e))?;

        match polar_loop_control(generation) {
            PolarLoopControl::Continue => {}
            PolarLoopControl::Superseded => return Ok(()),
            PolarLoopControl::Cancelled => {
                emit_polar_status("Cancelled by user", "idle", 0);
                return Ok(());
            }
        }

        emit_polar_status(
            &format!("Plate solving point {}/3...", point),
            "measuring",
            point as i32,
        );

        // Get the captured image
        let image = api_get_last_image(camera_id.clone())
            .await
            .map_err(|e| format!("Failed to get image: {:?}", e))?;

        // Emit polar alignment image (before plate solve, no coordinates yet)
        emit_polar_image(&image, point as i32, "measuring", None, None);

        // Read off the frame that was actually taken, not the requested
        // binning: a camera that refused the binning request would otherwise
        // have its full-resolution frame downsampled by a rule that thinks it
        // is already binned.
        let solve_downsample = polar_solve_downsample(image.width, image.height, binning);

        // Save temp file for plate solving
        let temp_path = create_unique_temp_fits_path(&format!("polar_align_point_{}", point));
        let temp_path_str = temp_path.to_string_lossy().to_string();

        // Write FITS file for plate solving
        if let Err(e) = write_temp_fits_for_solve(&image, &temp_path_str, &solve_scale.hints) {
            return Err(format!("Failed to write temp FITS: {}", e));
        }

        // Hinted first, blind as the fallback. The mount is re-read for every
        // point because every point is a different pointing.
        let solve_result = solve_polar_frame(
            &format!("point {}", point),
            &temp_path_str,
            read_polar_solve_hint(&mount_id).await,
            solve_scale_arcsec_per_px,
            solve_downsample,
            solve_timeout_secs,
        )
        .await;

        // Clean up temp file
        let _ = std::fs::remove_file(&temp_path);
        let solve_result = solve_result?;

        // PlateSolveResult follows the native solver contract: RA is already
        // degrees. Multiplying by 15 here corrupted both the rotation-center
        // fit and the next mount slew target.
        let ra_degrees = plate_solve_ra_degrees(solve_result.ra);
        solved_points.push((ra_degrees, solve_result.dec));
        tracing::info!(
            "Point {} solved: RA={:.4}°, Dec={:.4}°",
            point,
            ra_degrees,
            solve_result.dec
        );

        // Emit image again with plate solve coordinates
        emit_polar_image(
            &image,
            point as i32,
            "measuring",
            Some(ra_degrees),
            Some(solve_result.dec),
        );

        // Rotate mount for next point (if not last point)
        if point < 3 {
            if manual_rotation {
                emit_polar_status(
                    &format!("Rotate mount {}° and wait...", step_size as i32),
                    "measuring",
                    point as i32,
                );
                // Wait for user to rotate manually
                tokio::time::sleep(tokio::time::Duration::from_secs(15)).await;
            } else {
                emit_polar_status(
                    &format!("Slewing to point {}...", point + 1),
                    "measuring",
                    point as i32,
                );

                // Rotate about the polar axis in the MOUNT's frame: same mount
                // Dec, mount RA stepped. The solved coordinates just pushed
                // above are the measurement, not the slew target — a target
                // built from them makes the mount absorb the very
                // misalignment being measured as a two-axis move
                // (`rotation_step_target` explains). The wait polls the
                // driver's `slewing` flag instead of hoping five seconds is
                // enough; a still-moving mount would smear point 2.
                match rotate_for_next_point(
                    &mount_id,
                    point + 1,
                    step_size,
                    rotate_east,
                    observer_longitude,
                    generation,
                    hold_dec_degrees,
                )
                .await?
                {
                    SlewOutcome::Settled => {}
                    SlewOutcome::Cancelled => {
                        emit_polar_status("Cancelled by user", "idle", 0);
                        return Ok(());
                    }
                    SlewOutcome::Superseded => return Ok(()),
                }
            }
        }
    }

    // Phase 2: Calculate center of rotation
    emit_polar_status("Calculating polar alignment error...", "adjusting", 3);

    let fit = skotiq_sequencer::fit_rotation_axis(&solved_points, is_north).ok_or_else(|| {
        let msg = "The three measurement points do not describe a rotation. The mount did not \
             turn between them, or the same frame was solved three times."
            .to_string();
        emit_polar_status(&format!("Error: {}", msg), "error", 0);
        msg
    })?;
    let (mut center_ra, mut center_dec) = (fit.ra_degrees, fit.dec_degrees);
    let pole_dec = if is_north { 90.0 } else { -90.0 };

    // The axis is the ANSWER, but a three-point circle is exactly determined:
    // there is no residual to report and the arc is the only thing standing
    // between a point's error and the axis. Logging the lever arm alongside the
    // answer is what turns "the axis came out 9° off" into a number the next
    // run can act on.
    tracing::info!(
        "Rotation center: RA={:.4}°, Dec={:.4}° (circle radius {:.2}°, arc {:.1}°, \
         one arcmin of error in one point moves this axis {:.2}°)",
        center_ra,
        center_dec,
        fit.radius_degrees,
        fit.arc_degrees,
        fit.axis_degrees_per_arcmin
    );
    if fit.axis_degrees_per_arcmin > MAX_TRUSTWORTHY_AXIS_SENSITIVITY {
        tracing::warn!(
            "Polar alignment measured over only {:.1}° of arc ({:.0}° steps). At that lever arm \
             one arcminute of error in one point moves the fitted axis {:.2}°, so the reported \
             error is dominated by measurement noise. Use a larger step size.",
            fit.arc_degrees,
            step_size,
            fit.axis_degrees_per_arcmin
        );
    }

    // Geometric validation: check if calculated center is within 15° of expected pole
    let dec_diff = (center_dec - pole_dec).abs();
    if dec_diff > 15.0 {
        let error_msg = format!(
            "The measured rotation axis (Dec={:.2}°) is {:.1}° from the celestial pole \
            (Dec={:.0}°) — far more than any mount can be misaligned by. The three points \
            spanned {:.1}° of arc, where one arcminute of error in a single point moves the \
            fitted axis {:.2}°, so this is a measurement problem rather than an alignment \
            one. Increase the step size (currently {:.0}°), check focus, and make sure the \
            mount is only turning in RA between points.",
            center_dec, dec_diff, pole_dec, fit.arc_degrees, fit.axis_degrees_per_arcmin, step_size
        );
        tracing::error!("{}", error_msg);
        emit_polar_status(&format!("Error: {}", error_msg), "error", 0);
        return Err(error_msg);
    }

    // Phase 3: Adjustment loop - continuously update error as the user adjusts.
    emit_polar_status("Adjustment mode - make corrections", "adjusting", 0);

    // Track the measured mount RA axis as the user physically adjusts the alt/az
    // bolts. The axis is measured in the three-point phase from ROTATED points.
    // During
    // adjustment the mount is stationary (the user turns the bolts, not the RA
    // motor), so re-fitting the axis from the now-stationary frames is invalid —
    // three near-identical points give a degenerate plane, which collapses the
    // axis toward the pole and reports ~0 error from a badly misaligned mount.
    //
    // Instead we hold the measured axis and apply the displacement of the
    // boresight (how far the current solved position has moved from the first
    // adjustment frame) to the axis. Any physical mount adjustment shifts the
    // whole sky-to-mount mapping by the same small rotation, so the boresight
    // displacement equals the axis displacement to first order. `reference_solve`
    // is captured on the first successful adjustment solve below.
    let initial_axis = (center_ra, center_dec);
    let mut reference_solve: Option<(f64, f64)> = None;

    // Auto-complete timer: tracks when error first dropped below threshold
    let mut auto_complete_start: Option<std::time::Instant> = None;
    const AUTO_COMPLETE_DURATION_SECS: u64 = 3;

    let mut consecutive_failures = 0;
    const MAX_FAILURES: i32 = 5;

    loop {
        match polar_loop_control(generation) {
            PolarLoopControl::Continue => {}
            PolarLoopControl::Superseded => return Ok(()),
            PolarLoopControl::Cancelled => {
                emit_polar_status("Stopped", "idle", 0);
                return Ok(());
            }
        }

        // Capture and solve to get current position
        emit_polar_status("Capturing...", "adjusting", 0);
        if let Err(e) = crate::api::imaging::camera_start_exposure_opt(
            camera_id.clone(),
            exposure_time,
            gain,
            offset,
            binning,
            binning,
        )
        .await
        {
            consecutive_failures += 1;
            tracing::warn!("Capture failed in adjustment loop: {:?}", e);
            emit_polar_status(
                &format!(
                    "Capture failed: {:?} (retry {}/{})",
                    e, consecutive_failures, MAX_FAILURES
                ),
                "adjusting",
                0,
            );
            if consecutive_failures >= MAX_FAILURES {
                return Err(format!(
                    "Too many consecutive failures ({}) in adjustment loop",
                    MAX_FAILURES
                ));
            }
            tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
            continue;
        }

        match polar_loop_control(generation) {
            PolarLoopControl::Continue => {}
            PolarLoopControl::Superseded => return Ok(()),
            PolarLoopControl::Cancelled => {
                emit_polar_status("Stopped", "idle", 0);
                return Ok(());
            }
        }

        // Get the captured image
        let image = match api_get_last_image(camera_id.clone()).await {
            Ok(img) => img,
            Err(e) => {
                consecutive_failures += 1;
                tracing::warn!("Failed to get image in adjustment loop: {:?}", e);
                emit_polar_status(
                    &format!(
                        "Image retrieval failed (retry {}/{})",
                        consecutive_failures, MAX_FAILURES
                    ),
                    "adjusting",
                    0,
                );
                if consecutive_failures >= MAX_FAILURES {
                    return Err(format!(
                        "Too many consecutive failures ({}) in adjustment loop",
                        MAX_FAILURES
                    ));
                }
                tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
                continue;
            }
        };

        // Emit polar alignment image (adjustment phase, no coordinates yet)
        emit_polar_image(&image, 0, "adjusting", None, None);

        let temp_path = create_unique_temp_fits_path("polar_align_adjust");
        let temp_path_str = temp_path.to_string_lossy().to_string();

        if let Err(e) = write_temp_fits_for_solve(&image, &temp_path_str, &solve_scale.hints) {
            consecutive_failures += 1;
            tracing::warn!("Failed to write temp FITS: {}", e);
            emit_polar_status(
                &format!(
                    "FITS write failed (retry {}/{})",
                    consecutive_failures, MAX_FAILURES
                ),
                "adjusting",
                0,
            );
            if consecutive_failures >= MAX_FAILURES {
                return Err(format!(
                    "Too many consecutive failures ({}) in adjustment loop",
                    MAX_FAILURES
                ));
            }
            tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
            continue;
        }

        emit_polar_status("Solving...", "adjusting", 0);

        // The adjustment frames solve the same way the measurement points do,
        // on the same operator-configured budget. A hard-coded 30s here is
        // what killed the measurement points on the owner's laptop, and the
        // adjustment loop re-solves the same field over and over — the frame
        // ASTAP is least entitled to search the whole sky for.
        let solve_result = solve_polar_frame(
            "the adjustment frame",
            &temp_path_str,
            read_polar_solve_hint(&mount_id).await,
            solve_scale_arcsec_per_px,
            polar_solve_downsample(image.width, image.height, binning),
            solve_timeout_secs,
        )
        .await;
        let _ = std::fs::remove_file(&temp_path);

        let solve_result = match solve_result {
            Ok(result) => result,
            Err(e) => {
                consecutive_failures += 1;
                // A frame that did not solve measured nothing, so the
                // auto-complete dwell starts again from the next solved one.
                auto_complete_start = None;
                tracing::warn!("Plate solve failed in adjustment loop: {}", e);
                emit_polar_status(
                    &format!(
                        "Solve failed: {} (retry {}/{})",
                        e, consecutive_failures, MAX_FAILURES
                    ),
                    "adjusting",
                    0,
                );
                if consecutive_failures >= MAX_FAILURES {
                    return Err(format!(
                        "Too many consecutive failures ({}) in adjustment loop",
                        MAX_FAILURES
                    ));
                }
                tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
                continue;
            }
        };

        // A solved frame clears the failure streak.
        consecutive_failures = 0;

        // Native plate-solve results report RA in degrees.
        let ra_degrees = plate_solve_ra_degrees(solve_result.ra);

        // Emit image again with plate solve coordinates
        emit_polar_image(
            &image,
            0,
            "adjusting",
            Some(ra_degrees),
            Some(solve_result.dec),
        );

        // Track the current mount axis by applying the boresight
        // displacement (vs the first adjustment frame) to the measured axis.
        // This reflects the user's physical alt/az adjustments WITHOUT the
        // degenerate re-fit-from-stationary-points collapse.
        let (ref_ra, ref_dec) = *reference_solve.get_or_insert((ra_degrees, solve_result.dec));

        // Apply the exact geodesic rotation that moved the solved
        // boresight to the measured mechanical axis. This remains stable
        // near the pole where dividing a first-order RA delta by cos(dec)
        // becomes singular and can explode a tiny adjustment.
        let (cur_axis_ra, cur_axis_dec) = skotiq_sequencer::rotate_axis_by_star_motion(
            initial_axis,
            (ref_ra, ref_dec),
            (ra_degrees, solve_result.dec),
        );

        tracing::debug!(
            "Adjustment: boresight Δ=({:.4}°,{:.4}°) → current axis RA={:.4}°, Dec={:.4}°",
            ra_degrees - ref_ra,
            solve_result.dec - ref_dec,
            cur_axis_ra,
            cur_axis_dec
        );

        // Error in ARCSECONDS: the Dart UI labels these values with `"` and
        // uses 30"/60" colour bands, and the auto-complete threshold is in
        // the same unit. Emitting arcminutes here shows a 5' error as 5" and
        // fires the auto-complete ~60x too early.
        let (az_arcmin, alt_arcmin, total_arcmin) =
            skotiq_sequencer::calculate_alignment_error_arcmin(
                cur_axis_ra,
                cur_axis_dec,
                is_north,
                observer_latitude,
                observer_longitude,
                chrono::Utc::now(),
            );
        let (az_error, alt_error, total_error) =
            (az_arcmin * 60.0, alt_arcmin * 60.0, total_arcmin * 60.0);
        center_ra = cur_axis_ra;
        center_dec = cur_axis_dec;

        // Auto-complete logic: check if error is below threshold
        if total_error <= auto_complete_threshold {
            match auto_complete_start {
                Some(start_time) => {
                    let elapsed = start_time.elapsed();
                    if elapsed.as_secs() >= AUTO_COMPLETE_DURATION_SECS {
                        // Error has been below threshold for required duration
                        tracing::info!(
                            "Polar alignment complete! Total error {:.1} arcsec below threshold {:.1} for {} seconds",
                            total_error, auto_complete_threshold, AUTO_COMPLETE_DURATION_SECS
                        );
                        emit_polar_status(
                            &format!(
                                "Complete! Error {:.1}\" below threshold for {}s",
                                total_error, AUTO_COMPLETE_DURATION_SECS
                            ),
                            "complete",
                            0,
                        );
                        emit_polar_error(
                            az_error,
                            alt_error,
                            total_error,
                            ra_degrees,
                            solve_result.dec,
                            center_ra,
                            center_dec,
                        );
                        return Ok(());
                    } else {
                        // Still within threshold, update status with countdown
                        let remaining = AUTO_COMPLETE_DURATION_SECS - elapsed.as_secs();
                        emit_polar_status(
                            &format!("Below threshold - completing in {}s...", remaining),
                            "adjusting",
                            0,
                        );
                    }
                }
                None => {
                    // First time below threshold, start timer
                    auto_complete_start = Some(std::time::Instant::now());
                    tracing::info!(
                        "Error {:.1} arcsec dropped below threshold {:.1}, starting auto-complete timer",
                        total_error, auto_complete_threshold
                    );
                    emit_polar_status(
                        &format!(
                            "Below threshold - completing in {}s...",
                            AUTO_COMPLETE_DURATION_SECS
                        ),
                        "adjusting",
                        0,
                    );
                }
            }
        } else {
            // Error above threshold, reset timer if it was running
            if auto_complete_start.is_some() {
                tracing::debug!(
                    "Error {:.1} arcsec went back above threshold {:.1}, resetting auto-complete timer",
                    total_error, auto_complete_threshold
                );
                auto_complete_start = None;
            }
            emit_polar_status("Adjusting - make corrections", "adjusting", 0);
        }

        emit_polar_error(
            az_error,
            alt_error,
            total_error,
            ra_degrees,
            solve_result.dec,
            center_ra,
            center_dec,
        );

        // Brief pause before next update
        tokio::time::sleep(tokio::time::Duration::from_secs(1)).await;
    }
}

/// Write the temp FITS a polar-alignment frame is solved from.
///
/// `hints` carries the field scale (see [`SolveHints`]). No position is
/// stamped into the header: the position hint polar alignment does have is the
/// mount's own report, and it reaches ASTAP as `-ra`/`-spd` with the wide
/// search radius the unaligned pointing model needs (see [`solve_polar_frame`])
/// rather than as a header card a solver may read as gospel. The scale is
/// known from the operator's profile and the camera, and without it ASTAP has
/// to sweep for the field of view on all three measurement frames plus every
/// frame of the adjustment loop.
pub(crate) fn write_temp_fits_for_solve(
    image: &CapturedImageResult,
    path: &str,
    hints: &SolveHints,
) -> Result<(), String> {
    use skotiq_imaging::{write_fits, FitsHeader, ImageData, PixelType};
    use std::path::Path;

    // Convert RGBA display_data to grayscale 16-bit for FITS plate solving.
    // display_data is always RGBA (4 bytes per pixel).
    let raw_bytes: Vec<u8> = if image.is_color {
        // For color RGBA, convert to grayscale (luminance) and scale to 16-bit
        image
            .display_data
            .chunks(4)
            .flat_map(|rgba| {
                let lum = ((rgba[0] as u32 + rgba[1] as u32 + rgba[2] as u32) / 3) as u16 * 256;
                lum.to_le_bytes().to_vec()
            })
            .collect()
    } else {
        // For grayscale RGBA, take the R channel (all RGB channels are the same) and scale to 16-bit
        image
            .display_data
            .chunks(4)
            .flat_map(|rgba| {
                let scaled = (rgba[0] as u16) * 256;
                scaled.to_le_bytes().to_vec()
            })
            .collect()
    };

    let mut image_data = ImageData::new(
        image.width as u32,
        image.height as u32,
        1, // grayscale
        PixelType::U16,
    );
    image_data.data = raw_bytes;

    let mut header = FitsHeader::new();
    header.set_float("EXPTIME", image.exposure_time);
    hints.apply_to_fits_header(&mut header);

    write_fits(Path::new(path), &image_data, &header)
        .map_err(|e| format!("FITS write error: {:?}", e))
}
