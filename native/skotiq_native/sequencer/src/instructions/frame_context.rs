//! What a saved frame records about the rig and the exposure. One sampler,
//! [`sample_frame_context`], reads the devices for every frame Skotiq saves;
//! a sequence run adds what ties the frame to the run.

use super::*;

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

/// What the caller of a capture knows about a frame without asking the rig.
/// A sequence run and the Imaging screen both fill one of these; everything
/// else in the frame's header is read from the devices by
/// [`sample_frame_context`].
#[derive(Debug, Clone, Copy)]
pub struct CaptureFacts<'a> {
    /// The devices to read. An id that is `None` leaves that device's cards
    /// out. `latitude`/`longitude` are the site.
    pub rig: &'a RunRig,
    /// Observer, site elevation and equipment names. `session_id` is not
    /// read here: belonging to a run is the run's to add.
    pub identity: &'a FrameIdentity,
    pub commanded_secs: f64,
    pub binning: (u32, u32),
    /// FITS `IMAGETYP`.
    pub frame_type: &'a str,
    /// When the shutter opened.
    pub exposure_started_at: chrono::DateTime<chrono::Utc>,
    /// Filter name and slot, as one pair.
    pub filter: (Option<&'a str>, Option<i32>),
    pub target_name: Option<&'a str>,
    /// What the cooler was last set to hold, for a camera that does not
    /// report its own setpoint.
    pub set_temp_c: Option<f64>,
    /// The sensor's color filter pattern when the frame itself does not say.
    pub bayer_pattern: Option<&'a str>,
}

/// The longest one device read may hold up a frame's save. A read that takes
/// longer leaves its cards out, as a failed read does.
const RIG_READ_LIMIT: std::time::Duration = std::time::Duration::from_secs(5);

/// One best-effort device read: an error or an overrun is logged and the
/// value is left out.
async fn rig_read<T>(
    what: &str,
    read: impl std::future::Future<Output = DeviceResult<T>>,
) -> Option<T> {
    match tokio::time::timeout(RIG_READ_LIMIT, read).await {
        Ok(Ok(value)) => Some(value),
        Ok(Err(e)) => {
            tracing::debug!("[CAPTURE] {what} failed; its header cards are omitted: {e}");
            None
        }
        Err(_) => {
            tracing::warn!(
                "[CAPTURE] {what} did not answer within {}s; its header cards are omitted",
                RIG_READ_LIMIT.as_secs()
            );
            None
        }
    }
}

/// Everything a saved frame records about the rig and the exposure, read at
/// one moment: after readout, immediately before the file is written.
///
/// Every frame Skotiq saves goes through here, whoever took it, so two frames
/// of the same rig carry the same cards. Each device read is best-effort: a
/// device that is not connected, fails or does not answer in
/// [`RIG_READ_LIMIT`] leaves its cards out and never fails the save. Nothing
/// is filled with a placeholder.
///
/// The result belongs to no run: `session_id` is empty and `frame_index` is 0.
pub async fn sample_frame_context(
    device_ops: &dyn DeviceOps,
    facts: &CaptureFacts<'_>,
    image_data: &ImageData,
) -> crate::scheduling::FrameContext {
    let rig = facts.rig;
    let identity = facts.identity;
    let mut frame_ctx = crate::scheduling::FrameContext::new_light(
        "",
        facts.binning.0,
        facts.binning.1,
        facts.commanded_secs,
        0,
    );
    frame_ctx.exposure_started_at = Some(facts.exposure_started_at);

    // `EXPTIME` is the exposure that happened, so the camera's own report
    // wins over the commanded duration. The same number is the
    // `captured_images.exposure_duration` every integration total sums, so it
    // is bounded: the shutter cannot have been open materially longer than
    // the wait for it, and an over-report is a driver fault that keeps the
    // commanded value. A shorter report (an aborted exposure) is kept.
    let commanded_secs = facts.commanded_secs;
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

    frame_ctx.frame_type = facts.frame_type.to_string();
    frame_ctx.target_name = facts.target_name.map(str::to_string);
    frame_ctx.filter_name = facts.filter.0.map(str::to_string);
    frame_ctx.filter_index = facts.filter.1;

    // The camera layer has already decided these (the camera's report, the
    // commanded value standing in for one it could not read, nothing for a
    // camera without the control); a frame records them as they are.
    frame_ctx.gain = image_data.gain;
    frame_ctx.offset = image_data.offset;
    frame_ctx.sensor_temp_c = image_data.temperature;
    frame_ctx.set_temp_c = facts.set_temp_c;

    // The camera says whether the frame is a color mosaic and where its
    // pattern starts; the caller's pattern only fills in for a driver that
    // reports color without an offset. A monochrome frame has none, whatever
    // an earlier camera left configured.
    frame_ctx.bayer_pattern = match image_data.sensor_type.as_deref() {
        Some(s) if s.eq_ignore_ascii_case("Monochrome") || s.eq_ignore_ascii_case("Mono") => None,
        _ => image_data
            .color_filter
            .map(|pattern| pattern.letters())
            .or(facts.bayer_pattern.map(str::to_string)),
    };

    frame_ctx.observer_name = identity.observer_name.clone();
    frame_ctx.site_latitude_deg = rig.latitude;
    frame_ctx.site_longitude_deg = rig.longitude;
    frame_ctx.site_elevation_m = identity.site_elevation_m;
    frame_ctx.camera_make = identity.camera_make.clone();
    frame_ctx.camera_model = identity.camera_model.clone();
    frame_ctx.telescope_name = identity.telescope_name.clone();
    frame_ctx.telescope_focal_length_mm = identity.telescope_focal_length_mm;
    frame_ctx.telescope_aperture_mm = identity.telescope_aperture_mm;

    if let Some(camera_id) = &rig.camera_id {
        // Left empty, not 0 %, when the camera has no cooler or will not say:
        // 0 % would read as an idle cooler.
        frame_ctx.cooler_power_percent = rig_read(
            "camera cooler power",
            device_ops.camera_get_cooler_power(camera_id),
        )
        .await;

        // What the cooler is holding now; the caller's record of the last
        // setpoint stands in for a camera that does not report one.
        if let Some(setpoint) = rig_read(
            "camera cooler setpoint",
            device_ops.camera_get_cooler_setpoint(camera_id),
        )
        .await
        .flatten()
        {
            frame_ctx.set_temp_c = Some(setpoint);
        }

        // The equipment profile names the camera the operator wants in the
        // archive; a rig without one still has a connected camera with a
        // name, so the driver fills the gap and `INSTRUME` is not lost.
        frame_ctx.gain_is_iso = frame_ctx.gain.is_some()
            && rig_read(
                "camera ISO speeds",
                device_ops.camera_get_iso_speeds(camera_id),
            )
            .await
            .is_some_and(|speeds| !speeds.is_empty());

        if frame_ctx.camera_make.is_none() && frame_ctx.camera_model.is_none() {
            frame_ctx.camera_model =
                rig_read("camera model", device_ops.camera_get_model(camera_id))
                    .await
                    .flatten();
        }

        // The unbinned pixel pitch exists only in the driver. Without it a
        // frame carries FOCALLEN but no pitch, and no stacker can derive the
        // plate scale from the file alone.
        if let Some((x_um, y_um)) = rig_read(
            "camera pixel size",
            device_ops.camera_get_pixel_size_um(camera_id),
        )
        .await
        .flatten()
        {
            frame_ctx.camera_pixel_size_x_um = Some(x_um);
            frame_ctx.camera_pixel_size_y_um = Some(y_um);
        }
    }

    if let Some(focuser_id) = &rig.focuser_id {
        frame_ctx.focuser_position = rig_read(
            "focuser position",
            device_ops.focuser_get_position(focuser_id),
        )
        .await;
        // Not every focuser has a thermistor.
        frame_ctx.focuser_temperature_c = rig_read(
            "focuser temperature",
            device_ops.focuser_get_temperature(focuser_id),
        )
        .await
        .flatten();
    }

    if let Some(rotator_id) = &rig.rotator_id {
        frame_ctx.rotator_angle_deg =
            rig_read("rotator angle", device_ops.rotator_get_angle(rotator_id)).await;
    }

    // Where the telescope was, as distinct from where a sequence meant to be.
    if let Some(mount_id) = &rig.mount_id {
        if let Some((ra_hours, dec_degrees)) = rig_read(
            "mount coordinates",
            device_ops.mount_get_coordinates(mount_id),
        )
        .await
        {
            // Recorded in J2000, the frame every reader of the `RA`/`DEC`
            // cards and of the `captured_images` row assumes. A JNow mount
            // reads back of-date coordinates about 20' away (2026). When the
            // mount's frame cannot be resolved the pointing is left out
            // rather than recorded in the wrong one.
            if let Some((ra_j2000, dec_j2000)) = rig_read(
                "mount coordinate frame",
                device_ops.mount_readback_to_j2000(mount_id, ra_hours, dec_degrees),
            )
            .await
            {
                frame_ctx.mount_ra_hours = Some(ra_j2000);
                frame_ctx.mount_dec_degrees = Some(dec_j2000);
            }
            // Alt/az are derived from the of-date read-back, which is what
            // the hour angle needs, at the exposure midpoint: this runs after
            // readout, and only the horizon frame turns with the clock. Not
            // derived at all without a site.
            if let (Some(lat), Some(lon)) = (rig.latitude, rig.longitude) {
                let when = frame_ctx
                    .exposure_midpoint()
                    .unwrap_or_else(chrono::Utc::now);
                let (alt, az) =
                    crate::meridian::calculate_alt_az(ra_hours, dec_degrees, lat, lon, when);
                frame_ctx.mount_altitude_deg = Some(alt);
                frame_ctx.mount_azimuth_deg = Some(az);
            }
        }
        // `Unknown` is left out: downstream it cannot be told from no reading.
        frame_ctx.pier_side =
            match rig_read("mount pier side", device_ops.mount_side_of_pier(mount_id)).await {
                Some(crate::meridian::PierSide::East) => Some("East".to_string()),
                Some(crate::meridian::PierSide::West) => Some("West".to_string()),
                Some(crate::meridian::PierSide::Unknown) | None => None,
            };
    }

    // Only while guiding: a connected guider that is idle has no RMS.
    if let Some(status) = rig_read("guider status", device_ops.guider_get_status()).await {
        if status.is_guiding {
            frame_ctx.guide_rms_arcsec = Some(status.rms_total);
        }
    }

    frame_ctx
}

/// The frame context of one frame of a sequence run: the rig as
/// [`sample_frame_context`] reads it, plus what says the frame belongs to the
/// run (session, position in the burst, target, mosaic panel, the target's
/// last plate solve, the defect-map record).
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
    let binning = match config.binning {
        Binning::One => (1u32, 1u32),
        Binning::Two => (2, 2),
        Binning::Three => (3, 3),
        Binning::Four => (4, 4),
    };

    let mut frame_ctx = sample_frame_context(
        ctx.run.device_ops.as_ref(),
        &CaptureFacts {
            rig: &ctx.run.rig,
            identity: &ctx.run.identity,
            commanded_secs: config.duration_secs,
            binning,
            frame_type: config.frame_type.as_str(),
            exposure_started_at,
            filter: (frame_filter.0.as_deref(), frame_filter.1),
            // The running target, not the "untargeted" label file names use.
            target_name: ctx.target_name.as_deref(),
            set_temp_c: ctx.set_temp_c,
            bayer_pattern: ctx.bayer_pattern.as_deref(),
        },
        image_data,
    )
    .await;

    frame_ctx.session_id = ctx.run.identity.session_id.clone();
    frame_ctx.frame_index = frame_index;
    frame_ctx.total_planned_frames = Some(config.count);
    frame_ctx.target_id = ctx.target_id.clone();
    frame_ctx.target_ra_hours = ctx.target_ra;
    frame_ctx.target_dec_degrees = ctx.target_dec;
    frame_ctx.mosaic_panel = ctx.mosaic_panel.clone();

    // The target's last plate solve, once CenterTarget has run for it. The
    // solver reports RA in degrees; the context carries hours.
    {
        let solve_guard = ctx.run.last_plate_solve.read().await;
        if let Some(solve) = solve_guard.as_ref() {
            frame_ctx.plate_solve_ra_hours = Some(solve.ra_degrees / 15.0);
            frame_ctx.plate_solve_dec_degrees = Some(solve.dec_degrees);
            frame_ctx.plate_solve_pixel_scale_arcsec = Some(solve.pixel_scale);
            frame_ctx.plate_solve_rotation_deg = Some(solve.rotation);
        }
    }

    // Set only when the correction ran.
    frame_ctx.defect_map_correction = defect_map_outcome.into_record();

    frame_ctx
}
