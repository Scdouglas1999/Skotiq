//! `frame_context.rs` — moved verbatim out of the former single-file `instructions.rs`
//! (release-pass C3 mechanical split). No logic changed; private items were
//! widened to `pub(crate)` so the sibling modules and the tests module still
//! see them, and `super::*` supplies the imports the original file had.

use super::*;

// Frame context builder (Image Grading)

/// The seconds a frame is RECORDED as: the camera's own report of how long it
/// exposed, bounded by what the sequencer actually waited for.
///
/// This is the number that lands in the FITS `EXPTIME` card and in the NOT NULL
/// `captured_images.exposure_duration` every Session Report integration total
/// sums, so it is also the only honest source for the run's own integration
/// total. Crediting `frames x the node's PLANNED duration` instead makes the
/// surfaces that sum rows disagree with the surfaces that multiply — four
/// frames of 5 + 15 + 15 + 15 s reported as `50s` in one place and `1m 0s` in
/// another.
///
/// The bound is one-sided: over-reporting is a driver fault and keeps the
/// commanded value, while under-reporting is physically real (an aborted or
/// truncated exposure) and is kept.
pub(crate) fn recorded_exposure_secs(commanded_secs: f64, reported_secs: f64) -> f64 {
    let longest_believable = commanded_secs * 1.05 + 1.0;
    if reported_secs > 0.0 && reported_secs <= longest_believable {
        reported_secs
    } else {
        commanded_secs
    }
}

/// Build the per-frame FITS-header bundle for the current capture.
///
/// Reads everything the FITS writer needs:
/// - session-static fields from `InstructionContext` (session_id, observer,
///   equipment ID, site coords)
/// - per-target fields from `InstructionContext` (target_name/id, mosaic_panel)
/// - exposure settings from the active `ExposureConfig`
/// - live device telemetry by querying the connected focuser / rotator /
///   guider via `DeviceOps`. Each query is best-effort: a device that fails
///   to report its state simply omits the corresponding FITS keyword. We
///   never substitute sentinel values.
/// - the most recent plate-solve result, if CenterTarget ran for this target
///
/// The live-telemetry reads are bounded: the focuser/rotator/guide queries
/// are simple status reads (no motion commands) and the existing DeviceOps
/// implementations cache the values, so this adds <10 ms of overhead per
/// frame — negligible compared to the multi-second exposure.
pub(crate) async fn build_frame_context_for_save(
    ctx: &InstructionContext,
    config: &ExposureConfig,
    image_data: &ImageData,
    frame_index: u32,
    defect_map_outcome: DefectMapOutcome,
    exposure_started_at: chrono::DateTime<chrono::Utc>,
    // The burst's (name, slot) pair from `resolve_frame_filter`, passed in
    // rather than re-derived so the FITS card can never name a different filter
    // than the file it is written into.
    frame_filter: (Option<String>, Option<i32>),
) -> crate::scheduling::FrameContext {
    let (bin_x, bin_y) = match config.binning {
        Binning::One => (1u32, 1u32),
        Binning::Two => (2, 2),
        Binning::Three => (3, 3),
        Binning::Four => (4, 4),
    };

    let mut frame_ctx = crate::scheduling::FrameContext::new_light(
        ctx.session_id.clone(),
        bin_x,
        bin_y,
        config.duration_secs,
        frame_index,
    );
    frame_ctx.exposure_started_at = Some(exposure_started_at);

    // DECISION: the camera's own report of how long it exposed wins over the
    // commanded duration, but only within the bound below.
    //
    // Why the driver and not the plan. `EXPTIME` means the exposure that
    // happened, not the one that was asked for, and the FITS writer has always
    // read it straight off `ImageData` — so preferring the plan here would
    // CHANGE what lands in every FITS file, which is the larger unannounced
    // change. On a camera with a mechanical shutter the two genuinely differ,
    // and the measured value is the one a later calibration match wants.
    //
    // Why it is bounded. The same field is now also the NOT NULL
    // `captured_images.exposure_duration` that every integration total sums, so
    // one lying driver could corrupt a season of totals with nothing
    // downstream able to tell. The shutter cannot have been open materially
    // longer than the sequencer waited for it, so an over-report is not a
    // measurement — it is a fault, and the commanded value is kept instead.
    // (The grace is shutter/readout latency plus drivers that quantise their
    // exposure clock coarsely on long subs.)
    //
    // The bound is deliberately one-sided. A report SHORTER than commanded is
    // physically possible — an aborted or truncated exposure really did end
    // early — and it can only under-count integration, which is the safe
    // direction and shows up as an obviously short sub rather than as a night
    // that claims hours it never collected.
    let commanded_secs = frame_ctx.duration_secs;
    let reported_secs = image_data.exposure_secs;
    let longest_believable = commanded_secs * 1.05 + 1.0;
    frame_ctx.duration_secs = recorded_exposure_secs(commanded_secs, reported_secs);
    if reported_secs > longest_believable {
        tracing::warn!(
            "[CAPTURE] Camera reported a {:.3}s exposure for a commanded {:.3}s frame — \
             impossible, so the commanded value is recorded instead. This driver's \
             exposure report cannot be trusted; integration totals would be inflated \
             by roughly {:.1}x if it were.",
            reported_secs,
            commanded_secs,
            if commanded_secs > 0.0 {
                reported_secs / commanded_secs
            } else {
                f64::INFINITY
            },
        );
    }

    // Honour the node's configured frame type (FITS IMAGETYP). Before this,
    // every sequencer capture was stamped "Light" — sequenced darks/flats/
    // bias frames were mislabeled on disk and invisible to calibration
    // ingest that filters on IMAGETYP.
    frame_ctx.frame_type = config.frame_type.clone();

    frame_ctx.total_planned_frames = Some(config.count);

    // Target identification — use the running target from the executor (not
    // the synthesized "untargeted" label used for the filename, which is a
    // legitimate operator-visible signal but should not pollute the FITS
    // OBJECT keyword).
    frame_ctx.target_id = ctx.target_id.clone();
    frame_ctx.target_name = ctx.target_name.clone();
    frame_ctx.target_ra_hours = ctx.target_ra;
    frame_ctx.target_dec_degrees = ctx.target_dec;

    // Filter. Name and slot arrive already paired: reading `config` and the
    // context independently let a burst that named "Ha" but carried no slot be
    // stamped with whatever slot the previous burst had left behind.
    (frame_ctx.filter_name, frame_ctx.filter_index) = frame_filter;

    // Camera settings (already on ImageData from the capture).
    frame_ctx.gain = image_data.gain.or(config.gain);
    frame_ctx.offset = image_data.offset.or(config.offset);
    frame_ctx.sensor_temp_c = image_data.temperature;
    frame_ctx.set_temp_c = ctx.set_temp_c;

    // Cooler duty cycle. Only meaningful on a cooled camera; an uncooled one
    // (or a driver that will not answer) leaves the column NULL rather than
    // recording 0 %, which would read as "cooler idle" — the opposite of "no
    // cooler".
    if let Some(camera_id) = &ctx.camera_id {
        match ctx.device_ops.camera_get_cooler_power(camera_id).await {
            Ok(power) => frame_ctx.cooler_power_percent = Some(power),
            Err(e) => tracing::debug!(
                "[CAPTURE] camera_get_cooler_power failed; cooler power omitted: {}",
                e
            ),
        }
    }

    // Bayer pattern — prefer the camera-reported sensor type over a stale
    // ExecutionContext value. A camera reporting "Monochrome" overrides any
    // stale "RGGB" left from a previous (different-camera) session.
    frame_ctx.bayer_pattern = match image_data.sensor_type.as_deref() {
        Some(s) if s.eq_ignore_ascii_case("Monochrome") || s.eq_ignore_ascii_case("Mono") => None,
        _ => ctx.bayer_pattern.clone(),
    };

    // Mosaic panel.
    frame_ctx.mosaic_panel = ctx.mosaic_panel.clone();

    // Observer / site.
    frame_ctx.observer_name = ctx.observer_name.clone();
    frame_ctx.site_latitude_deg = ctx.latitude;
    frame_ctx.site_longitude_deg = ctx.longitude;
    frame_ctx.site_elevation_m = ctx.site_elevation_m;

    // Equipment identification.
    frame_ctx.camera_make = ctx.camera_make.clone();
    frame_ctx.camera_model = ctx.camera_model.clone();
    // Ask the DRIVER which camera this is when the observer profile does not
    // say. The profile is a cross-product of app settings and the active
    // equipment profile, so a rig running without one — which is every
    // headless run that has not had a profile created, and was exactly the
    // state of the live rig — wrote frames with no INSTRUME at all. The camera
    // is connected and has a name; there is no reason for the file not to
    // carry it. Only fills the gap: a profile that names a camera still wins,
    // because that is the operator stating what they want in their archive.
    if frame_ctx.camera_make.is_none() && frame_ctx.camera_model.is_none() {
        if let Some(camera_id) = &ctx.camera_id {
            match ctx.device_ops.camera_get_model(camera_id).await {
                Ok(Some(model)) => frame_ctx.camera_model = Some(model),
                Ok(None) => tracing::debug!(
                    "[CAPTURE] camera {} reports no model name; INSTRUME omitted",
                    camera_id
                ),
                Err(e) => {
                    tracing::debug!("[CAPTURE] camera_get_model failed; INSTRUME omitted: {}", e)
                }
            }
        }
    }
    // Sensor pixel pitch (FITS XPIXSZ/YPIXSZ). Asked of the driver here rather
    // than taken from the observer profile, which has no pixel-size field: this
    // is the only place in a sequenced capture where the number is reachable,
    // and without it the sub lands on disk with FOCALLEN but no pitch, so no
    // stacker can derive the plate scale from the file alone. A driver that
    // will not answer leaves the keywords off rather than inventing a pitch.
    if let Some(camera_id) = &ctx.camera_id {
        match ctx.device_ops.camera_get_pixel_size_um(camera_id).await {
            Ok(Some((x_um, y_um))) => {
                frame_ctx.camera_pixel_size_x_um = Some(x_um);
                frame_ctx.camera_pixel_size_y_um = Some(y_um);
            }
            Ok(None) => tracing::debug!(
                "[CAPTURE] camera {} reports no pixel size; XPIXSZ/YPIXSZ omitted",
                camera_id
            ),
            Err(e) => tracing::debug!(
                "[CAPTURE] camera_get_pixel_size_um failed; XPIXSZ/YPIXSZ omitted: {}",
                e
            ),
        }
    }
    frame_ctx.telescope_name = ctx.telescope_name.clone();
    frame_ctx.telescope_focal_length_mm = ctx.telescope_focal_length_mm;
    frame_ctx.telescope_aperture_mm = ctx.telescope_aperture_mm;

    // Live focuser telemetry. We use match arms so a driver error just
    // omits the keyword — never overrides with a fake value. The focuser
    // temperature is `Option<f64>` even on success because not every
    // focuser model has a thermistor.
    if let Some(focuser_id) = &ctx.focuser_id {
        match ctx.device_ops.focuser_get_position(focuser_id).await {
            Ok(pos) => frame_ctx.focuser_position = Some(pos),
            Err(e) => tracing::debug!(
                "[CAPTURE] focuser_get_position failed; FOCUSPOS omitted: {}",
                e
            ),
        }
        match ctx.device_ops.focuser_get_temperature(focuser_id).await {
            Ok(temp) => frame_ctx.focuser_temperature_c = temp,
            Err(e) => tracing::debug!(
                "[CAPTURE] focuser_get_temperature failed; FOCTEMP omitted: {}",
                e
            ),
        }
    }

    // Live rotator telemetry.
    if let Some(rotator_id) = &ctx.rotator_id {
        match ctx.device_ops.rotator_get_angle(rotator_id).await {
            Ok(angle) => frame_ctx.rotator_angle_deg = Some(angle),
            Err(e) => tracing::debug!(
                "[CAPTURE] rotator_get_angle failed; ROTATPOS omitted: {}",
                e
            ),
        }
    }

    // Live mount pointing + pier side.
    //
    // Where the telescope actually WAS, which is what the FITS `RA`/`DEC`
    // cards and the `captured_images.mount_*` columns both mean — as opposed
    // to `target_ra_hours`/`target_dec_degrees`, which are where the sequence
    // meant to be (an unedited "New Target" sits at 0h/0°). Read HERE, into
    // the FrameContext both surfaces are stamped from, so the header and the
    // row cannot disagree.
    if let Some(mount_id) = &ctx.mount_id {
        match ctx.device_ops.mount_get_coordinates(mount_id).await {
            Ok((ra_hours, dec_degrees)) => {
                // Stored in J2000, the frame every reader of the FITS `RA`/`DEC`
                // cards and the `captured_images` row assumes. A JNow mount
                // reads back of-date coordinates ~20' away (2026), and writing
                // those as-is put every frame's recorded pointing off target by
                // the precession offset. Alt/az below still use the of-date
                // read-back, which is what the hour angle needs.
                match ctx
                    .device_ops
                    .mount_readback_to_j2000(mount_id, ra_hours, dec_degrees)
                    .await
                {
                    Ok((ra_j2000, dec_j2000)) => {
                        frame_ctx.mount_ra_hours = Some(ra_j2000);
                        frame_ctx.mount_dec_degrees = Some(dec_j2000);
                    }
                    Err(e) => tracing::debug!(
                        "[CAPTURE] mount frame unresolved; RA/DEC omitted rather than \
                         recorded in the wrong frame: {}",
                        e
                    ),
                }
                // Alt/az are derived, not read back: `mount_get_status` would
                // report them but costs a full capability sweep per saved
                // frame on ASCOM, and the geometry is exact once the site is
                // known. Both stay None when the observer location is unset
                // rather than being computed from a guessed site.
                //
                // Derived at the EXPOSURE MIDPOINT, not now. This runs after
                // readout, so `Utc::now()` dated the geometry by the whole
                // exposure plus download — see `FrameContext::exposure_midpoint`
                // for what that costs a photometry run. RA/Dec do not need the
                // same treatment: a tracking mount holds them, and it is only
                // the horizon frame that turns with the clock.
                if let (Some(lat), Some(lon)) = (ctx.latitude, ctx.longitude) {
                    let when = frame_ctx
                        .exposure_midpoint()
                        .unwrap_or_else(chrono::Utc::now);
                    let (alt, az) =
                        crate::meridian::calculate_alt_az(ra_hours, dec_degrees, lat, lon, when);
                    frame_ctx.mount_altitude_deg = Some(alt);
                    frame_ctx.mount_azimuth_deg = Some(az);
                }
            }
            Err(e) => tracing::debug!(
                "[CAPTURE] mount_get_coordinates failed; pointing omitted: {}",
                e
            ),
        }
        match ctx.device_ops.mount_side_of_pier(mount_id).await {
            // `Unknown` is dropped rather than recorded: it is indistinguishable
            // downstream from "no reading was taken", and the column is
            // nullable precisely so absence can say that.
            Ok(crate::meridian::PierSide::East) => frame_ctx.pier_side = Some("East".to_string()),
            Ok(crate::meridian::PierSide::West) => frame_ctx.pier_side = Some("West".to_string()),
            Ok(crate::meridian::PierSide::Unknown) => {}
            Err(e) => tracing::debug!(
                "[CAPTURE] mount_side_of_pier failed; PIERSIDE omitted: {}",
                e
            ),
        }
    }

    // Live guide RMS (PHD2 / built-in guider). The guider may be off (no
    // guiding for short subs), in which case the keyword is omitted.
    match ctx.device_ops.guider_get_status().await {
        Ok(status) if status.is_guiding => {
            frame_ctx.guide_rms_arcsec = Some(status.rms_total);
        }
        Ok(_) => {
            // Guider connected but not currently guiding — omit the keyword.
        }
        Err(e) => tracing::debug!(
            "[CAPTURE] guider_get_status failed; GUIDERMS omitted: {}",
            e
        ),
    }

    // Plate-solve result (only available once CenterTarget has run for
    // this target). Stored as Arc<RwLock<_>> so the executor and exposure
    // share state without cloning.
    {
        let solve_guard = ctx.last_plate_solve.read().await;
        if let Some(solve) = solve_guard.as_ref() {
            // PlateSolveResult stores RA in DEGREES; convert to hours for
            // the SOLVED-RA keyword (which is FITS-standard in degrees).
            // Wait — read the spec: api_save_fits writes RA in HOURS for
            // the RA keyword. Stay consistent: SOLVED-RA in HOURS too.
            frame_ctx.plate_solve_ra_hours = Some(solve.ra_degrees / 15.0);
            frame_ctx.plate_solve_dec_degrees = Some(solve.dec_degrees);
            frame_ctx.plate_solve_pixel_scale_arcsec = Some(solve.pixel_scale);
            frame_ctx.plate_solve_rotation_deg = Some(solve.rotation);
        }
    }

    // defect-map correction provenance. Only set when
    // the correction actually ran; skipped / disabled outcomes leave
    // the field None and no HISTORY card is emitted by the FITS writer.
    frame_ctx.defect_map_correction = defect_map_outcome.into_record();

    frame_ctx
}
