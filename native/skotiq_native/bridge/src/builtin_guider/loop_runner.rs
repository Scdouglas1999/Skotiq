use super::*;

pub(crate) async fn ensure_connected() -> Result<(), SkotiqError> {
    let connected = state().read().await.connected;
    if connected {
        Ok(())
    } else {
        Err(SkotiqError::NotConnected(
            "Built-in multi-star guider".to_string(),
        ))
    }
}

pub(crate) async fn resolve_devices() -> Result<(String, String), SkotiqError> {
    let app_state = get_state();
    let camera_id =
        if let Some(device_id) = app_state.get_profile_device_id(DeviceType::Camera).await {
            device_id
        } else if let Some(device_id) = first_connected_device(DeviceType::Camera).await {
            device_id
        } else {
            return Err(SkotiqError::OperationFailed(
                "Built-in guider requires a connected camera in the active profile".to_string(),
            ));
        };

    let mount_id = if let Some(device_id) = app_state.get_profile_device_id(DeviceType::Mount).await
    {
        device_id
    } else if let Some(device_id) = first_connected_device(DeviceType::Mount).await {
        device_id
    } else {
        return Err(SkotiqError::OperationFailed(
            "Built-in guider requires a connected mount in the active profile".to_string(),
        ));
    };

    let device_manager = get_device_manager();
    if !device_manager
        .is_device_connected(DeviceType::Camera, &camera_id)
        .await
    {
        return Err(SkotiqError::NotConnected(camera_id));
    }
    if !device_manager
        .is_device_connected(DeviceType::Mount, &mount_id)
        .await
    {
        return Err(SkotiqError::NotConnected(mount_id));
    }

    Ok((camera_id, mount_id))
}

pub(crate) async fn first_connected_device(device_type: DeviceType) -> Option<String> {
    get_device_manager()
        .first_connected_device_id(device_type)
        .await
}

pub(crate) async fn resolve_unbinned_guide_pixel_scale(
    camera_id: &str,
) -> Result<f64, SkotiqError> {
    let profile = get_state().get_profile().await.ok_or_else(|| {
        SkotiqError::OperationFailed(
            "Built-in guider requires an active profile with a guide focal length".to_string(),
        )
    })?;
    let focal_length_mm = profile.telescope_focal_length;
    let camera_status = get_device_manager()
        .camera_get_status(camera_id)
        .await
        .map_err(SkotiqError::from)?;
    if !camera_status.pixel_size_x.is_finite()
        || camera_status.pixel_size_x <= 0.0
        || !camera_status.pixel_size_y.is_finite()
        || camera_status.pixel_size_y <= 0.0
    {
        return Err(SkotiqError::OperationFailed(format!(
            "Built-in guider requires positive camera pixel dimensions \
             (pixel_size_x_um={}, pixel_size_y_um={})",
            camera_status.pixel_size_x, camera_status.pixel_size_y
        )));
    }
    let pixel_size_um = (camera_status.pixel_size_x + camera_status.pixel_size_y) / 2.0;

    guide_pixel_scale_arcsec(pixel_size_um, focal_length_mm, 1).ok_or_else(|| {
        SkotiqError::OperationFailed(format!(
            "Built-in guider requires positive guide focal length and camera pixel size \
             (focal_length_mm={}, pixel_size_x_um={}, pixel_size_y_um={})",
            focal_length_mm, camera_status.pixel_size_x, camera_status.pixel_size_y
        ))
    })
}

pub(crate) async fn capture_guide_frame() -> Result<GuideFrame, SkotiqError> {
    let (camera_id, _) = resolve_devices().await?;
    let (config, pixel_scale_arcsec) = {
        let guard = state().read().await;
        let pixel_scale = guard
            .unbinned_pixel_scale
            .and_then(|scale| binned_guide_pixel_scale(scale, guard.config.binning))
            .ok_or_else(|| {
                SkotiqError::OperationFailed(
                    "Built-in guider has no valid guide-camera pixel scale".to_string(),
                )
            })?;
        (guard.config.clone(), pixel_scale)
    };
    let device_manager = get_device_manager();

    device_manager
        .camera_start_exposure(
            &camera_id,
            config.exposure_secs,
            Some(config.gain),
            Some(config.offset),
            config.binning,
            config.binning,
            // Guide frames are always light frames (shutter open).
            skotiq_native::camera::FrameType::Light,
        )
        .await
        .map_err(SkotiqError::from)?;

    // Bound the completion wait. Without a deadline a wedged guide camera
    // (status never returns "complete" — USB stall, driver hang) spins this
    // loop forever, and because stop/disconnect join this task they would then
    // block indefinitely too. On timeout, abort the exposure so the sensor is
    // left idle and surface a clean error the caller can recover from.
    let capture_deadline =
        Instant::now() + Duration::from_secs_f64(config.exposure_secs.max(0.0) + 30.0);
    loop {
        if device_manager
            .camera_is_exposure_complete(&camera_id)
            .await
            .map_err(SkotiqError::from)?
        {
            break;
        }
        if Instant::now() >= capture_deadline {
            let _ = device_manager.camera_abort_exposure(&camera_id).await;
            return Err(SkotiqError::OperationFailed(format!(
                "Guide exposure on {} did not complete within {:.0}s",
                camera_id,
                config.exposure_secs + 30.0
            )));
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }

    let native_image = device_manager
        .camera_download_image(&camera_id)
        .await
        .map_err(SkotiqError::from)?;
    let image = ImageData::from_u16(
        native_image.width,
        native_image.height,
        1,
        &native_image.data,
    );
    let summary = detect_stars_with_stats(&image, &StarDetectionConfig::default());
    let mut stars = summary.stars.clone();
    stars.sort_by(|a, b| {
        b.flux
            .partial_cmp(&a.flux)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    let frame_counter = {
        let guard = state().read().await;
        guard
            .last_frame
            .as_ref()
            .map(|frame| frame.frame + 1)
            .unwrap_or(1)
    };

    Ok(GuideFrame {
        frame: frame_counter,
        image,
        stars,
        pixel_scale_arcsec,
    })
}

pub(crate) async fn ensure_frame_available() -> Result<GuideFrame, SkotiqError> {
    if let Some(frame) = state().read().await.last_frame.clone() {
        return Ok(frame);
    }
    capture_guide_frame().await
}

pub(crate) async fn capture_and_store_loop_frame(
    controller: Arc<RwLock<BuiltinGuiderState>>,
) -> Result<(), SkotiqError> {
    let frame = capture_guide_frame().await?;
    let selected = choose_lock_star(&frame.stars, controller.read().await.manual_lock, None)
        .or_else(|| frame.stars.first())
        .cloned();

    let mut guard = controller.write().await;
    if let Some(star) = selected.as_ref() {
        guard.manual_lock = Some(Vec2 {
            x: star.x,
            y: star.y,
        });
    }
    update_snapshot_from_frame(&mut guard, &frame, 50);
    guard.last_status.connected = true;
    guard.last_status.state = if guard.looping {
        "Looping".to_string()
    } else {
        "Connected".to_string()
    };
    publish_star_measurement(&mut guard, selected.as_ref());
    guard.last_frame = Some(frame);
    Ok(())
}

/// Record the frame's star measurement AND announce it.
///
/// Looping exists so the operator can judge star quality and exposure length
/// before picking a star, and every one of those readouts is fed by the
/// `GuideStats` event. Storing the measurement in `last_status` without
/// publishing it left the loop's SNR reading `0.0`, Star Mass blank and Frame
/// Count `0` for the whole loop, while the detector logged a fresh measurement
/// for every frame — the one mode where those numbers are the point.
pub(crate) fn publish_star_measurement(
    guard: &mut BuiltinGuiderState,
    star: Option<&DetectedStar>,
) {
    let snr = star.map(|s| s.snr).unwrap_or(0.0);
    let star_mass = star.map(|s| s.flux).unwrap_or(0.0);
    guard.last_status.snr = snr;
    guard.last_status.star_mass = star_mass;
    get_state().publish_guiding_event(
        GuidingEvent::GuideStats { snr, star_mass },
        EventSeverity::Info,
    );
}

pub(crate) async fn run_guiding_loop(
    controller: Arc<RwLock<BuiltinGuiderState>>,
    stop_flag: Arc<std::sync::atomic::AtomicBool>,
    settle_pixels: f64,
    settle_time: f64,
    settle_timeout: f64,
) -> Result<(), SkotiqError> {
    let calibration = calibrate_mount_response(controller.clone()).await?;
    {
        let mut guard = controller.write().await;
        guard.calibration = Some(calibration);
        guard.calibrating = false;
        guard.last_status.state = "Guiding".to_string();
        // Arm the settle timeout for the initial settle after calibration, and
        // publish the spec this episode is judged by so `apply_settle_state`
        // reads one source of truth (a dither later replaces it with its own).
        let timeout_secs = settle_timeout.max(settle_time + 1.0);
        guard.settling = true;
        guard.settle_spec = SettleSpec {
            pixels: settle_pixels,
            time: settle_time,
            timeout: timeout_secs,
        };
        guard.settle_timeout_deadline =
            Some(Instant::now() + Duration::from_secs_f64(timeout_secs));
    }
    get_state().publish_guiding_event(GuidingEvent::CalibrationComplete, EventSeverity::Info);
    get_state().publish_guiding_event(GuidingEvent::GuidingStarted, EventSeverity::Info);

    loop {
        if stop_flag.load(std::sync::atomic::Ordering::Relaxed) {
            break;
        }

        let frame = capture_guide_frame().await?;
        let current_lock = {
            let guard = controller.read().await;
            guard.manual_lock
        };
        let selected = choose_lock_star(&frame.stars, current_lock, None)
            .or_else(|| frame.stars.first())
            .cloned()
            .ok_or_else(|| SkotiqError::OperationFailed("No guide stars detected".to_string()))?;

        let offset = {
            let mut guard = controller.write().await;
            if guard.reference_stars.is_empty() {
                guard.reference_stars =
                    select_reference_stars(&frame.stars, frame.image.width, frame.image.height);
            }
            guard.manual_lock = Some(Vec2 {
                x: selected.x,
                y: selected.y,
            });
            let desired = guard.desired_offset;
            let matched = measure_offset(&guard.reference_stars, &frame.stars, desired);
            // A dither in flight has already moved every expected position; if the
            // stars cannot be found there, the dither is the thing that failed, so
            // roll it back and keep guiding instead of failing the loop task (which
            // stops guiding AND reports the guider disconnected).
            let Some(offset) = matched else {
                if guard.dither_pending {
                    guard.dither_misses += 1;
                    if guard.dither_misses < DITHER_MATCH_GRACE_FRAMES {
                        continue;
                    }
                    abandon_dither(&mut guard);
                    drop(guard);
                    tracing::warn!(
                        "Built-in guider abandoned a dither: guide stars did not match at the \
                         dithered position; rolled back and continuing to guide"
                    );
                    get_state()
                        .publish_guiding_event(GuidingEvent::LostStar, EventSeverity::Warning);
                    continue;
                }
                return Err(SkotiqError::OperationFailed(
                    "Unable to match guide stars".to_string(),
                ));
            };
            guard.dither_misses = 0;
            // Record per-star residuals so the per-star UI can show how far each
            // tracked star drifted this frame, not just the aggregate centroid.
            record_per_star_residuals(&mut guard.reference_stars, &frame.stars, desired);
            update_snapshot_from_frame(&mut guard, &frame, 50);
            let offset_arcsec =
                guide_offset_arcsec(offset, frame.pixel_scale_arcsec).ok_or_else(|| {
                    SkotiqError::OperationFailed(
                        "Built-in guider has no valid guide-camera pixel scale".to_string(),
                    )
                })?;
            guard.last_status.connected = true;
            guard.last_status.state = "Guiding".to_string();
            // Public guider RMS is consumed by the sequencer's arcsecond
            // GuidingFailed threshold. Internal correction, settle, and dither
            // calculations below deliberately remain in guide-camera pixels.
            //
            // A dither is a commanded move, not a guiding error, so its samples
            // are excluded while the settle is pending — otherwise every dither
            // spikes the reported RMS (observed jumping 0.64" -> 1.52" and
            // colouring the UI red mid-dither) and drags the rolling window for
            // the next 20 frames. This is what PHD2 does, and it also stops
            // transient dither excursions feeding the GuidingFailed trigger.
            if !guard.dither_pending {
                push_arcsec_sample(&mut guard.rms_samples_arcsec, offset_arcsec);
            }
            let (rms_ra, rms_dec, rms_total) = axis_rms(&guard.rms_samples_arcsec);
            guard.last_status.rms_ra = rms_ra;
            guard.last_status.rms_dec = rms_dec;
            guard.last_status.rms_total = rms_total;
            guard.last_status.pixel_scale = frame.pixel_scale_arcsec;
            guard.last_status.snr = selected.snr;
            guard.last_status.star_mass = selected.flux;
            guard.last_frame = Some(frame.clone());
            offset
        };

        get_state().publish_guiding_event(
            GuidingEvent::Correction {
                ra: offset.x,
                dec: offset.y,
                ra_raw: offset.x,
                dec_raw: offset.y,
            },
            EventSeverity::Info,
        );
        get_state().publish_guiding_event(
            GuidingEvent::GuideStats {
                snr: selected.snr,
                star_mass: selected.flux,
            },
            EventSeverity::Info,
        );

        // Record this frame's RMS so adaptive dither can loosen settle tolerance
        // when recent seeing is poor.
        push_rms_sample(&controller, offset.magnitude()).await;

        apply_settle_state(controller.clone(), offset.magnitude()).await?;
        apply_guide_correction(calibration, offset, &controller).await?;
    }

    Ok(())
}
