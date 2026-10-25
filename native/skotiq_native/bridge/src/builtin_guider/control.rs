use super::*;

/// Set the guider configuration. Must be called before `connect()` or will apply
/// to subsequent operations. Calling while guiding is active will update the config
/// for future frames.
pub async fn set_config(config: GuiderConfig) {
    let mut guard = state().write().await;
    guard.last_status.pixel_scale = guard
        .unbinned_pixel_scale
        .and_then(|scale| binned_guide_pixel_scale(scale, config.binning))
        .unwrap_or(0.0);
    guard.config = config;
}

/// Get the current guider configuration.
pub async fn get_config() -> GuiderConfig {
    state().read().await.config.clone()
}

pub async fn connect() -> Result<(), SkotiqError> {
    let (camera_id, mount_id) = resolve_devices().await?;
    let config = state().read().await.config.clone();
    let unbinned_pixel_scale = resolve_unbinned_guide_pixel_scale(&camera_id).await?;
    let pixel_scale =
        binned_guide_pixel_scale(unbinned_pixel_scale, config.binning).ok_or_else(|| {
            SkotiqError::OperationFailed(format!(
                "Built-in guider requires positive camera binning, got {}",
                config.binning
            ))
        })?;
    let mut guard = state().write().await;
    guard.connected = true;
    guard.camera_id = Some(camera_id);
    guard.mount_id = Some(mount_id);
    guard.unbinned_pixel_scale = Some(unbinned_pixel_scale);
    guard.last_status = BuiltinGuideStatus {
        connected: true,
        state: "Connected".to_string(),
        pixel_scale,
        ..BuiltinGuideStatus::default()
    };
    Ok(())
}

pub async fn disconnect() -> Result<(), SkotiqError> {
    // Serialize against start/stop so disconnect cannot race a loop spawn.
    let _op = op_lock().lock().await;
    stop_locked().await?;
    let mut guard = state().write().await;
    *guard = BuiltinGuiderState::default();
    Ok(())
}

pub async fn start_guiding(
    settle_pixels: f64,
    settle_time: f64,
    settle_timeout: f64,
) -> Result<(), SkotiqError> {
    ensure_connected().await?;
    // Hold the op-lock across the ENTIRE start (stop-previous → set guiding=true
    // → spawn loop → record handle). This is what makes start atomic with respect
    // to a concurrent `stop()`: a stop cannot land in the window between the loop
    // being spawned and its handle being recorded, so it can never observe `None`
    // and orphan a live mount-pulsing loop.
    let _op = op_lock().lock().await;
    stop_locked().await?;

    begin_loop(
        |guard| {
            guard.guiding = true;
            guard.looping = false;
            guard.calibrating = true;
            guard.last_status.state = "Calibrating".to_string();
            guard.last_status.connected = true;
        },
        GuidingEvent::Calibrating,
        move |controller, stop_flag_for_task| async move {
            if let Err(error) = run_guiding_loop(
                controller.clone(),
                stop_flag_for_task,
                settle_pixels,
                settle_time,
                settle_timeout,
            )
            .await
            {
                tracing::error!("Built-in guider task failed: {}", error);
                let mut guard = controller.write().await;
                guard.guiding = false;
                guard.looping = false;
                guard.calibrating = false;
                guard.last_status.state = "Disconnected".to_string();
                // Carry the REASON to the UI, not just the state change.
                //
                // `GuidingEvent::Disconnected` has no message field, so a task
                // that died from e.g. "Calibration star match failed" reached
                // Dart as a bare disconnect: the imaging Guiding panel then said
                // "No guider connected" and the operator was sent to check
                // cables for a calibration problem the log had already
                // diagnosed. Reproduced end-to-end with the built-in guider on
                // the simulator camera.
                //
                // `report_error` is the channel that actually lands: it marks the
                // device errored, stores `last_error`, and publishes the
                // equipment `Error` event carrying device_type/device_id/message
                // which `DeviceService._handleDeviceError` routes into
                // `guiderStateProvider.setError(...)` — so the guiding panel can
                // name the failure instead of claiming no guider is connected.
                // The system event stays as the operator-visible log line.
                //
                // ORDER MATTERS. The guiding `Disconnected` event is handled by
                // `DeviceService._handleDeviceDisconnected`, which calls
                // `setDisconnected()` — and that RESETS the guider state object,
                // wiping any `lastError` already on it. Publishing the error
                // first therefore lost it (observed: panel still read "No guider
                // connected"). Emit the disconnect first so the error is the
                // final state the UI settles on, while the disconnect still
                // drives the existing "Guiding Lost" notification.
                drop(guard);
                let reason = guiding_failure_reason(&error);
                get_state()
                    .publish_guiding_event(GuidingEvent::Disconnected, EventSeverity::Warning);
                get_state().publish_system_event(SystemEvent::Error {
                    message: reason.clone(),
                });
                get_device_manager()
                    .report_error(BUILTIN_GUIDER_ID, reason)
                    .await;
            }
        },
    )
    .await;
    Ok(())
}

pub async fn loop_exposures() -> Result<(), SkotiqError> {
    ensure_connected().await?;
    // See `start_guiding` for why the op-lock is held across the whole operation.
    let _op = op_lock().lock().await;
    stop_locked().await?;

    begin_loop(
        |guard| {
            guard.guiding = false;
            guard.looping = true;
            guard.calibrating = false;
            guard.last_status.state = "Looping".to_string();
            guard.last_status.connected = true;
        },
        GuidingEvent::Looping,
        |controller, stop_flag_for_task| async move {
            loop {
                if stop_flag_for_task.load(std::sync::atomic::Ordering::Relaxed) {
                    break;
                }
                if let Err(error) = capture_and_store_loop_frame(controller.clone()).await {
                    tracing::warn!("Built-in guider looping frame failed: {}", error);
                    tokio::time::sleep(Duration::from_millis(500)).await;
                }
            }
        },
    )
    .await;
    Ok(())
}

/// Shared start path for `start_guiding`/`loop_exposures`. The caller MUST already
/// hold the [`op_lock`] and have torn down any previous loop via `stop_locked()`.
///
/// The atomicity guarantee for the start/stop race lives here: the stop flag is
/// created and stored into state inside the same write-lock
/// critical section that flips `guiding`/`looping`, BEFORE the loop is spawned, so
/// the invariant "an active loop always has a live `stop_flag` in state" holds for
/// the entire lifetime of the loop. Because the caller holds the op-lock for the
/// whole start, no `stop()` can interleave between spawning the loop and recording
/// its `JoinHandle`.
pub(crate) async fn begin_loop<S, F, Fut>(set_state: S, event: GuidingEvent, make_loop: F)
where
    S: FnOnce(&mut BuiltinGuiderState),
    F: FnOnce(Arc<RwLock<BuiltinGuiderState>>, Arc<std::sync::atomic::AtomicBool>) -> Fut,
    Fut: std::future::Future<Output = ()> + Send + 'static,
{
    let stop_flag = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let stop_flag_for_task = stop_flag.clone();
    {
        let mut guard = state().write().await;
        set_state(&mut guard);
        // Store the stop flag together with the run-state flip so `stop()` always
        // observes a live flag for an active loop. The previous handle was already
        // joined by the caller's `stop_locked()`.
        guard.stop_flag = Some(stop_flag);
        guard.task = None;
    }

    get_state().publish_guiding_event(event, EventSeverity::Info);

    let controller = state().clone();
    let task = tokio::spawn(make_loop(controller, stop_flag_for_task));

    // Safe under the op-lock: no concurrent stop can have run since we set
    // `stop_flag`, so recording the handle cannot resurrect a torn-down loop.
    state().write().await.task = Some(task);
}

/// Test-only: start a synthetic loop through the real lifecycle machinery
/// (`op_lock` + `stop_locked` + `begin_loop`). The loop holds no hardware. While
/// alive it keeps `live_loops` incremented (decremented on exit), so a test can
/// detect any orphaned loop — including one stranded when a later start overwrote
/// its handle, which loses the stop signal permanently. Returns once the loop is
/// registered, like the real `start_guiding`.
#[cfg(test)]
pub(crate) async fn start_synthetic_loop(live_loops: Arc<std::sync::atomic::AtomicUsize>) {
    let _op = op_lock().lock().await;
    let _ = stop_locked().await;
    begin_loop(
        |guard| {
            guard.guiding = true;
            guard.looping = false;
            guard.calibrating = true;
        },
        GuidingEvent::Calibrating,
        move |_controller, stop_flag_for_task| async move {
            live_loops.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            // Mirror the real loops: exit only when the stop flag is set. An
            // orphaned loop (stop signal lost / handle overwritten) keeps the
            // live-loop count above zero forever.
            while !stop_flag_for_task.load(std::sync::atomic::Ordering::Relaxed) {
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
            live_loops.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
        },
    )
    .await;
}

pub async fn stop() -> Result<(), SkotiqError> {
    // Serialize against start so a stop landing mid-start still observes (and
    // cancels) the live loop rather than racing the handle/flag bookkeeping.
    let _op = op_lock().lock().await;
    stop_locked().await
}

/// Stop the active loop. The caller MUST already hold the [`op_lock`]; this is the
/// shared body used by `stop`, `start_guiding`, `loop_exposures`, and `disconnect`
/// so the lifecycle entry points cannot interleave.
pub(crate) async fn stop_locked() -> Result<(), SkotiqError> {
    let (stop_flag, task) = {
        let mut guard = state().write().await;
        guard.guiding = false;
        guard.looping = false;
        guard.calibrating = false;
        guard.reference_stars.clear();
        guard.desired_offset = Vec2::default();
        guard.settle_deadline = None;
        guard.settle_timeout_deadline = None;
        guard.settling = false;
        guard.dither_pending = false;
        guard.dither_origin = Vec2::default();
        guard.dither_misses = 0;
        guard.dither_abandoned = false;
        // The pattern index is per guiding session: carrying it across a
        // start/stop left the next session resuming mid-pattern.
        guard.dither_step = 0;
        guard.last_dec_direction = None;
        // Carried sub-minimum pulse demand belongs to the session that measured
        // it; a new session starts from a fresh star field and lock position.
        guard.pulse_debt = PulseDebt::default();
        guard.rms_history.clear();
        // Carrying the previous session's samples into the next one would make
        // the first frames of a new session report the old target's guiding.
        guard.rms_samples_arcsec.clear();
        guard.last_status.rms_ra = 0.0;
        guard.last_status.rms_dec = 0.0;
        guard.last_status.rms_total = 0.0;
        guard.last_status.state = if guard.connected {
            "Connected".to_string()
        } else {
            "Disconnected".to_string()
        };
        (guard.stop_flag.take(), guard.task.take())
    };

    if let Some(flag) = stop_flag {
        flag.store(true, std::sync::atomic::Ordering::Relaxed);
    }
    if let Some(handle) = task {
        let _ = handle.await;
    }

    get_state().publish_guiding_event(GuidingEvent::GuidingStopped, EventSeverity::Info);
    Ok(())
}

pub async fn find_star() -> Result<(f64, f64), SkotiqError> {
    ensure_connected().await?;
    let guide_frame = ensure_frame_available().await?;
    let Some(selected) =
        choose_lock_star(&guide_frame.stars, state().read().await.manual_lock, None)
    else {
        // The star count is what separates "the frame is empty" from "the
        // frame is full of stars and none of them are usable" — the operator
        // needs a longer exposure in one case and a different field in the
        // other.
        tracing::warn!(
            "Auto Select: no usable guide star among {} detections in the guide frame",
            guide_frame.stars.len()
        );
        return Err(SkotiqError::OperationFailed(
            "No guide star found".to_string(),
        ));
    };
    tracing::info!(
        "Auto Select: chose a guide star at ({:.1}, {:.1}) px out of {} detections",
        selected.x,
        selected.y,
        guide_frame.stars.len()
    );

    let selected_pos = Vec2 {
        x: selected.x,
        y: selected.y,
    };

    let mut guard = state().write().await;
    guard.manual_lock = Some(selected_pos);
    guard.reference_stars = select_reference_stars(
        &guide_frame.stars,
        guide_frame.image.width,
        guide_frame.image.height,
    );
    update_snapshot_from_frame(&mut guard, &guide_frame, 50);
    get_state().publish_guiding_event(
        GuidingEvent::StarSelected {
            x: selected.x,
            y: selected.y,
        },
        EventSeverity::Info,
    );

    // FRAME coordinates, in both arms — the snapshot's own `star_x/star_y`
    // live inside the 50 px crop made one line above.
    if let Some(snapshot) = &guard.last_snapshot {
        Ok(snapshot.star_frame_position())
    } else {
        Ok((selected.x, selected.y))
    }
}

pub async fn deselect_star() -> Result<(), SkotiqError> {
    let mut guard = state().write().await;
    guard.manual_lock = None;
    guard.reference_stars.clear();
    guard.last_snapshot = None;
    Ok(())
}

pub async fn set_lock_position(x: f64, y: f64) -> Result<(), SkotiqError> {
    ensure_connected().await?;
    let guide_frame = ensure_frame_available().await?;

    let target = {
        let guard = state().read().await;
        if let Some(snapshot) = &guard.last_snapshot {
            Vec2 {
                x: snapshot.crop_origin_x as f64 + x,
                y: snapshot.crop_origin_y as f64 + y,
            }
        } else {
            Vec2 { x, y }
        }
    };

    let selected = nearest_star(
        &guide_frame.stars,
        target,
        GUIDE_MAX_MATCH_DISTANCE_PX * 1.5,
    )
    .ok_or_else(|| {
        SkotiqError::OperationFailed("No star near requested lock position".to_string())
    })?;

    let selected_pos = Vec2 {
        x: selected.x,
        y: selected.y,
    };

    let mut guard = state().write().await;
    guard.manual_lock = Some(selected_pos);
    guard.reference_stars = select_reference_stars(
        &guide_frame.stars,
        guide_frame.image.width,
        guide_frame.image.height,
    );
    update_snapshot_from_frame(&mut guard, &guide_frame, 50);
    get_state().publish_guiding_event(
        GuidingEvent::StarSelected {
            x: selected.x,
            y: selected.y,
        },
        EventSeverity::Info,
    );
    Ok(())
}

pub async fn get_lock_position() -> Result<(f64, f64), SkotiqError> {
    let guard = state().read().await;
    if let Some(snapshot) = &guard.last_snapshot {
        // Frame coordinates, matching `find_star`, `manual_lock` and the
        // `StarSelected` event — not the crop's.
        return Ok(snapshot.star_frame_position());
    }
    if let Some(lock) = guard.manual_lock {
        return Ok((lock.x, lock.y));
    }
    Err(SkotiqError::OperationFailed(
        "No guide star is selected".to_string(),
    ))
}

pub async fn get_star_image(size: u32) -> Result<Phd2StarImage, SkotiqError> {
    // If there is no snapshot yet we must capture a fresh guide frame. That
    // capture MUST happen without holding the state lock: capture_guide_frame
    // re-acquires state().read(), and a tokio RwLock is not reentrant, so
    // holding the write lock across it self-deadlocks and permanently wedges
    // the guider (status/stop/disconnect all then block on the same lock).
    let need_capture = { state().read().await.last_snapshot.is_none() };
    let fresh_frame = if need_capture {
        Some(capture_guide_frame().await?)
    } else {
        None
    };

    let mut guard = state().write().await;
    if let Some(frame) = fresh_frame {
        update_snapshot_from_frame(&mut guard, &frame, size);
        guard.last_frame = Some(frame);
    } else if let Some(frame) = guard.last_frame.clone() {
        update_snapshot_from_frame(&mut guard, &frame, size);
    }

    let snapshot = guard
        .last_snapshot
        .clone()
        .ok_or_else(|| SkotiqError::OperationFailed("No guide frame available".to_string()))?;

    Ok(Phd2StarImage {
        frame: snapshot.frame,
        width: snapshot.width,
        height: snapshot.height,
        star_x: snapshot.star_x,
        star_y: snapshot.star_y,
        pixels: snapshot.pixels,
    })
}

pub async fn get_status() -> Result<Phd2Status, SkotiqError> {
    let guard = state().read().await;
    let status = &guard.last_status;
    Ok(Phd2Status {
        connected: status.connected,
        state: status.state.clone(),
        rms_ra: status.rms_ra,
        rms_dec: status.rms_dec,
        rms_total: status.rms_total,
        snr: status.snr,
        star_mass: status.star_mass,
        // The guider keeps 0 until a camera and binning give it a scale.
        pixel_scale: Some(status.pixel_scale).filter(|scale| scale.is_finite() && *scale > 0.0),
        stop_reason: None,
    })
}

/// Convert the built-in guider's `east`/`north` calibration vectors into the
/// PHD2-shaped `Phd2CalibrationData` (degrees, possibly None) so the unified
/// `api_guider_get_calibration` can return one type across backends.
pub async fn get_calibration_data() -> Result<crate::api::phd2::Phd2CalibrationData, SkotiqError> {
    let guard = state().read().await;
    let calib = match guard.calibration {
        Some(c) => c,
        None => {
            return Ok(crate::api::phd2::Phd2CalibrationData {
                is_calibrated: false,
                ra_angle: None,
                dec_angle: None,
                ra_rate: None,
                dec_rate: None,
            });
        }
    };
    // atan2 returns radians in (-π, π]; convert to degrees in (-180, 180].
    let ra_angle = calib.east.y.atan2(calib.east.x).to_degrees();
    let dec_angle = calib.north.y.atan2(calib.north.x).to_degrees();
    // Pulse magnitude divided by configured calibration_ms gives pixels/ms,
    // which we surface in the same shape PHD2 uses (rate as pixels/ms).
    let ra_rate = if calib.pulse_ms > 0.0 {
        Some(calib.ra_rate())
    } else {
        None
    };
    let dec_rate = if calib.pulse_ms > 0.0 {
        Some(calib.dec_rate())
    } else {
        None
    };
    Ok(crate::api::phd2::Phd2CalibrationData {
        is_calibrated: true,
        ra_angle: Some(ra_angle),
        dec_angle: Some(dec_angle),
        ra_rate,
        dec_rate,
    })
}

pub fn device_id() -> &'static str {
    BUILTIN_GUIDER_ID
}

/// Whether the built-in guider session is active (heartbeat liveness).
pub async fn is_connected() -> bool {
    state().read().await.connected
}
