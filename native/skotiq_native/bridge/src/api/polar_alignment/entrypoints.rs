use super::*;

/// Stop the polar alignment process.
///
/// Returns only once the run is actually terminated. Signals cooperative
/// cancellation, then awaits the owned task handle with a bounded grace; if the
/// task is still mid-exposure it force-aborts (dropping the in-flight future)
/// and confirms termination. If termination cannot be confirmed it returns a
/// truthful timeout error and, crucially, leaves the running flag set and never
/// publishes idle — so a new Start stays blocked until the run truly settles.
///
/// This is applied to *both* TPPA and all-sky, which share this stop path and
/// the single owned task slot, so neither can leave a task running under a new
/// run.
pub async fn api_stop_polar_alignment() -> Result<(), SkotiqError> {
    // Serialize with Start until its task handle is stored; Stop must never
    // report success while an admitted task can still appear afterward.
    let _control = polar_control_lock().lock().await;
    if !get_polar_align_flag().load(PolarOrdering::Relaxed) {
        return Ok(()); // Already stopped
    }

    // Signal cooperative cancellation.
    get_polar_align_cancel().store(true, PolarOrdering::Relaxed);
    tracing::info!("Stopping polar alignment; awaiting task termination");

    // Take the owned task handle and await bounded termination. We never
    // publish idle (or admit a new Start) while the old task could still touch
    // the camera/mount.
    let handle = { polar_task_slot().lock().await.take() };
    if let Some(mut h) = handle {
        let abort = h.abort_handle();

        // First give the task a bounded chance to exit cooperatively at one of
        // its cancel/generation checkpoints.
        let terminated =
            match tokio::time::timeout(Duration::from_secs(POLAR_STOP_CLEAN_GRACE_SECS), &mut h)
                .await
            {
                Ok(_join) => true,
                Err(_elapsed) => {
                    // Likely blocked in a long exposure. Force-abort to drop the
                    // in-flight future, then confirm the task actually unwound.
                    tracing::warn!(
                        "Polar alignment did not stop cooperatively in {}s; aborting task",
                        POLAR_STOP_CLEAN_GRACE_SECS
                    );
                    abort.abort();
                    tokio::time::timeout(Duration::from_secs(POLAR_STOP_ABORT_GRACE_SECS), &mut h)
                        .await
                        .is_ok()
                }
            };

        if !terminated {
            // Could not confirm termination. Keep the run blocked: leave the
            // running flag set, do NOT publish idle, and put the handle back so
            // a later stop can try again.
            *polar_task_slot().lock().await = Some(h);
            return Err(SkotiqError::OperationFailed(
                "Polar alignment stop timed out; task is still terminating".to_string(),
            ));
        }
    }

    get_polar_align_flag().store(false, PolarOrdering::Relaxed);
    emit_polar_status("Stopped", "idle", 0);
    Ok(())
}

// All-sky polar alignment (SharpCap-style)

/// Polar alignment mode selector.
///
/// The traditional `ThreePoint` mode (TPPA) requires a clear view of the
/// celestial pole region. `AllSky` mode performs Sharpcap-style polar
/// alignment from any point in the sky using a single solved frame plus
/// live drift feedback.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PolarAlignmentMode {
    /// Three-Point Polar Alignment — requires pole region visible.
    ThreePoint,
    /// Sharpcap-style all-sky polar alignment — works from any sky direction.
    AllSky,
}

/// Start all-sky polar alignment.
///
/// Unlike TPPA this routine does not require the celestial pole region to
/// be visible. It takes a single exposure anywhere in the sky, plate-solves
/// it to anchor a baseline, then re-solves every `iteration_cadence_secs`
/// to measure drift relative to that baseline. From the drift signature
/// and the observer's geographic location it recovers the polar-axis
/// azimuth and altitude error.
///
/// Alignment auto-completes once the total error stays under
/// `acceptance_threshold_arcsec` for 3 seconds; 30″ is the default and is good
/// for ~3-minute unguided subs. `iteration_cadence_secs` defaults to 3 s.
///
/// Fails with `SkotiqError::OperationFailed` when no plate solver is
/// installed, no camera or mount is connected, or the observer location is not
/// configured.
pub async fn api_start_all_sky_polar_alignment(
    exposure_time: f64,
    solve_timeout: f64,
    binning: i32,
    is_north: bool,
    acceptance_threshold_arcsec: f64,
    iteration_cadence_secs: f64,
    gain: Option<i32>,
    offset: Option<i32>,
) -> Result<(), SkotiqError> {
    use skotiq_sequencer::all_sky_polar::{
        perform_all_sky_polar_alignment, AllSkyPolarAlignConfig, PolarAlignError,
    };
    use skotiq_sequencer::{Binning, InstructionContext};

    let _control = polar_control_lock().lock().await;

    // Fail loudly if the plate solver isn't installed — the all-sky
    // algorithm is plate-solve-only by design.
    if !skotiq_imaging::is_solver_available() {
        return Err(SkotiqError::OperationFailed(
            "Plate solver required — install ASTAP and re-run all-sky polar alignment".to_string(),
        ));
    }

    let generation = try_admit_polar_run().ok_or_else(|| {
        SkotiqError::OperationFailed("Polar alignment already running".to_string())
    })?;

    tracing::info!(
        "Starting all-sky polar alignment (gen {generation}): exposure={}s, threshold={}\", cadence={}s, north={}",
        exposure_time,
        acceptance_threshold_arcsec,
        iteration_cadence_secs,
        is_north
    );

    // Resolve connected devices.
    let connected = api_get_connected_devices().await;
    let camera_id = connected
        .iter()
        .find(|d| d.device_type == DeviceType::Camera)
        .map(|d| d.id.clone())
        .ok_or_else(|| {
            release_polar_run_if_current(generation);
            SkotiqError::DeviceNotFound("No camera connected".to_string())
        })?;
    let mount_id = connected
        .iter()
        .find(|d| d.device_type == DeviceType::Mount)
        .map(|d| d.id.clone())
        .ok_or_else(|| {
            release_polar_run_if_current(generation);
            SkotiqError::DeviceNotFound("No mount connected".to_string())
        })?;

    // Observer location is mandatory for the horizontal-frame projection.
    let location = get_state()
        .get_observer_location()
        .map_err(|e| {
            release_polar_run_if_current(generation);
            SkotiqError::OperationFailed(format!("Failed to read observer location: {}", e))
        })?
        .ok_or_else(|| {
            release_polar_run_if_current(generation);
            SkotiqError::OperationFailed(
                "Observer latitude/longitude is required for all-sky polar alignment".to_string(),
            )
        })?;

    let config = AllSkyPolarAlignConfig {
        exposure_time,
        solve_timeout,
        gain,
        offset,
        binning: Some(binning),
        is_north,
        acceptance_threshold_arcsec,
        iteration_cadence_secs,
    };

    // Spawn the alignment task. Errors are emitted on the polar alignment
    // event stream so the UI can present them clearly.
    let cancel_flag = Arc::new(AtomicBool::new(false));
    let cancel_flag_outer = cancel_flag.clone();

    // Bridge between the global cancel flag (set by `api_stop_polar_alignment`)
    // and the per-task cancellation token used by InstructionContext.
    tokio::spawn(async move {
        loop {
            if polar_generation().load(PolarOrdering::Relaxed) != generation {
                break;
            }
            if get_polar_align_cancel().load(PolarOrdering::Relaxed) {
                cancel_flag_outer.store(true, Ordering::Relaxed);
                break;
            }
            if !get_polar_align_flag().load(PolarOrdering::Relaxed) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
    });

    let device_ops = create_unified_device_ops();

    // Hand the alignment task its own executor-event bridge so instruction-level
    // failures (e.g. a FITS-save error on a polar-align exposure) reach the same
    // SkotiqEvent stream the rest of the app listens to. The status_cb /
    // image_cb callbacks below cover the alignment workflow itself; anything the
    // instructions layer emits directly reaches the stream only through this
    // bridge.
    //
    // `event_tx` is moved into the spawned task; the background bridge task
    // exits when the task drops the sender after the alignment finishes.
    let event_tx_for_align =
        crate::util::executor_event_bridge::spawn_executor_event_bridge(get_state().clone());

    let align_handle = tokio::spawn(async move {
        let ctx = InstructionContext {
            node_id: String::new(),
            target_ra: None,
            target_dec: None,
            target_name: None,
            target_rotation: None,
            current_filter: None,
            current_binning: Binning::One,
            cancellation_token: cancel_flag,
            camera_id: Some(camera_id.clone()),
            mount_id: Some(mount_id.clone()),
            focuser_id: None,
            filterwheel_id: None,
            rotator_id: None,
            dome_id: None,
            cover_calibrator_id: None,
            save_path: None,
            latitude: Some(location.latitude),
            longitude: Some(location.longitude),
            device_ops,
            trigger_state: None,
            filter_focus_offsets: std::collections::HashMap::new(),
            event_tx: Some(event_tx_for_align),
            recovery_request_tx: None,
            // Image Grading: polar alignment does not write FITS
            // frames into the sequencer's save_path; the alignment images
            // go through a separate dedicated channel. Empty defaults
            // satisfy the InstructionContext shape without lying.
            session_id: String::new(),
            target_id: None,
            mosaic_panel: None,
            current_filter_index: None,
            set_temp_c: None,
            bayer_pattern: None,
            observer_name: None,
            site_elevation_m: None,
            camera_make: None,
            camera_model: None,
            telescope_name: None,
            telescope_focal_length_mm: None,
            telescope_aperture_mm: None,
            last_plate_solve: std::sync::Arc::new(tokio::sync::RwLock::new(None)),
            hfr_baseline: std::sync::Arc::new(tokio::sync::RwLock::new(None)),
            hfr_baseline_samples: std::sync::Arc::new(tokio::sync::RwLock::new(Vec::new())),
            consecutive_rejects: std::sync::Arc::new(std::sync::atomic::AtomicU32::new(0)),
            frames_accepted: std::sync::Arc::new(std::sync::atomic::AtomicU32::new(0)),
            frames_rejected: std::sync::Arc::new(std::sync::atomic::AtomicU32::new(0)),
            default_quality_check: None,
            reject_folder_path: None,
            // defect map state. Polar alignment captures
            // do not go through the sequencer save_path; defect maps are
            // not applied here, so pass an empty slot.
            defect_map_apply: std::sync::Arc::new(tokio::sync::RwLock::new(None)),
            // Forensics: polar alignment does not grade frames.
            forensics_history: std::sync::Arc::new(tokio::sync::RwLock::new(
                std::collections::VecDeque::new(),
            )),
            current_sky_brightness_mag: std::sync::Arc::new(tokio::sync::RwLock::new(None)),
            cloud_motion_snapshot: std::sync::Arc::new(tokio::sync::RwLock::new(
                skotiq_sequencer::CloudMotionSnapshot::default(),
            )),
            current_wind_kph: std::sync::Arc::new(tokio::sync::RwLock::new(None)),
            current_sensor_temp_c: std::sync::Arc::new(tokio::sync::RwLock::new(None)),
            // Replay Debug — one-shot bridge API doesn't emit
            // decisions (no associated sequence_runs row).
            decision_tx: None,
            active_sequence_run_id: std::sync::Arc::new(parking_lot::RwLock::new(None)),
            // Polar alignment is not driven by the node-runtime disconnect-retry
            // loop, so this one-shot context owns a fresh, unshared flag.
            device_disconnect_recovery_pending: std::sync::Arc::new(
                std::sync::atomic::AtomicBool::new(false),
            ),
            // Dual-rig — polar alignment runs standalone, no secondary coord.
            dither_barrier: None,
            device_retry: skotiq_sequencer::instructions::DeviceRetryHandle::single_attempt(),
        };

        let status_cb = |status: String, _progress: Option<f64>| {
            emit_polar_status(&status, "adjusting", 0);
        };
        let image_cb = |image_data: skotiq_sequencer::PolarAlignmentImageData| {
            get_state().publish_event(create_event_auto_id(
                EventSeverity::Info,
                EventCategory::PolarAlignment,
                EventPayload::PolarAlignmentImage(PolarAlignmentImageEvent {
                    image_data: image_data.image_data,
                    width: image_data.width,
                    height: image_data.height,
                    solved_ra: image_data.solved_ra,
                    solved_dec: image_data.solved_dec,
                    point: image_data.point,
                    phase: image_data.phase,
                }),
            ));
        };
        let error_cb = |result: &skotiq_sequencer::PolarAlignResult| {
            emit_polar_error(
                result.azimuth_error,
                result.altitude_error,
                result.total_error,
                result.current_ra,
                result.current_dec,
                result.target_ra,
                result.target_dec,
            );
        };

        let result =
            perform_all_sky_polar_alignment(&config, &ctx, status_cb, image_cb, error_cb).await;

        // Only emit terminal status if we still own the run; a superseded /
        // force-aborted task must stay silent so it can't stomp a newer run.
        if polar_generation().load(PolarOrdering::Relaxed) == generation {
            match result {
                Ok(()) => {
                    emit_polar_status("All-sky polar alignment complete", "complete", 0);
                }
                Err(PolarAlignError::Cancelled) => {
                    emit_polar_status("Stopped", "idle", 0);
                }
                Err(PolarAlignError::SolverUnavailable) => {
                    emit_polar_status(
                        "Plate solver required — install ASTAP and re-run all-sky polar alignment",
                        "error",
                        0,
                    );
                    tracing::error!("All-sky polar alignment aborted: plate solver not available");
                }
                Err(e) => {
                    emit_polar_status(&format!("Error: {}", e), "error", 0);
                    tracing::error!("All-sky polar alignment failed: {}", e);
                }
            }
        }

        release_polar_run_if_current(generation);
    });

    // Hand the owned alignment task to the stop path so a subsequent stop can
    // await real termination (same owned slot as TPPA — one run at a time).
    store_polar_task(align_handle).await;

    Ok(())
}
