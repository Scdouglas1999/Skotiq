//! `expose.rs` — moved verbatim out of the former single-file `instructions.rs`
//! (release-pass C3 mechanical split). No logic changed; private items were
//! widened to `pub(crate)` so the sibling modules and the tests module still
//! see them, and `super::*` supplies the imports the original file had.

use super::*;

// Exposure instruction

/// Per-frame save-path renderer for the `ExposureConfig.save_to` template.
/// Built once in the expose-instruction wrapper (which has ExecutionContext
/// access) and invoked per frame, so the same engine resolves `${frame:04}`
/// and `${exposure.duration:.0f}`.
///
/// Returns `Ok((dir, filename))` where:
/// * `dir` is the directory portion (absolute, with any user-specified
///   sub-directories from the template already expanded), and
/// * `filename` is the rendered file-name portion.
///
/// Errors surface as `InstructionResult::failure` from the caller — a
/// broken save-path template must abort the exposure rather than silently
/// drop frames into the wrong place.
pub type FrameSavePathRenderer =
    Box<dyn Fn(u32, u32) -> Result<(PathBuf, String), String> + Send + Sync>;

/// Arms an asynchronous camera abort while an exposure future is in flight.
///
/// Cancellation normally takes the explicit `tokio::select!` branch below,
/// where abort is awaited. This guard covers the harder case where the whole
/// instruction Future is dropped by its caller: dropping the camera future
/// alone does not tell many drivers to stop the physical exposure.
pub(crate) struct CameraExposureAbortGuard {
    device_ops: SharedDeviceOps,
    camera_id: String,
    armed: bool,
}

impl CameraExposureAbortGuard {
    pub(crate) fn new(device_ops: SharedDeviceOps, camera_id: String) -> Self {
        Self {
            device_ops,
            camera_id,
            armed: true,
        }
    }

    pub(crate) fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for CameraExposureAbortGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }

        let device_ops = self.device_ops.clone();
        let camera_id = self.camera_id.clone();
        match tokio::runtime::Handle::try_current() {
            Ok(handle) => {
                let _abort_task = handle.spawn(async move {
                    if let Err(error) = device_ops.camera_abort_exposure(&camera_id).await {
                        tracing::error!(
                            "Failed to abort dropped camera exposure on {}: {}",
                            camera_id,
                            error
                        );
                    }
                });
            }
            Err(error) => tracing::error!(
                "Could not schedule camera abort for dropped exposure on {}: {}",
                self.camera_id,
                error
            ),
        }
    }
}

/// Execute an exposure instruction with no save-path renderer, so frames land
/// under the pre-template `<target>_<filter>_<NNNN>.fits` layout.
///
/// Nothing in production calls this: every capture path builds a renderer so
/// the user's naming template applies (the Flat Wizard was the last holdout —
/// see [`crate::flat_wizard::capture_converged_flats`]). It survives as the
/// short form for tests that are about the burst itself and not about where
/// its files land.
pub async fn execute_exposure(
    config: &ExposureConfig,
    ctx: &InstructionContext,
    progress_callback: impl Fn(u32, u32, f64),
) -> InstructionResult {
    execute_exposure_with_renderer(
        config,
        ctx,
        None,
        &BurstControl::default(),
        progress_callback,
    )
    .await
}

/// Run-scoped controls a burst needs but an [`InstructionContext`] cannot
/// carry: the operator-pause handle the per-frame loop honours, and a status
/// sink so a legitimate hold explains itself instead of looking like a stall.
///
/// [`Default`] is "never paused, nowhere to report" — correct for the
/// standalone callers (bridge one-shots, wizards, tests) that have no run
/// behind them.
#[derive(Default)]
pub struct BurstControl<'a> {
    pub pause: crate::node::context::PauseGate,
    pub status: Option<&'a (dyn Fn(&str) + Send + Sync)>,
}

impl BurstControl<'_> {
    pub(crate) fn report(&self, message: &str) {
        if let Some(status) = self.status {
            status(message);
        }
    }
}

/// entry point that accepts a save-path renderer. Use this from
/// the expose-instruction node wrapper so user templates in
/// `ExposureConfig.save_to` (including hierarchical paths and per-frame
/// placeholders) take effect.
pub async fn execute_exposure_with_renderer(
    config: &ExposureConfig,
    ctx: &InstructionContext,
    path_renderer: Option<FrameSavePathRenderer>,
    control: &BurstControl<'_>,
    // `(frame, total, recorded_secs)`. The third argument is the seconds the
    // frame is RECORDED as — the camera's own report, bounded (see
    // [`recorded_exposure_secs`]) — not the node's planned duration. Every
    // integration total downstream rides on it.
    progress_callback: impl Fn(u32, u32, f64),
) -> InstructionResult {
    let camera_id = match ctx.camera_id() {
        Ok(id) => id.to_string(),
        Err(e) => return e,
    };

    // Native daylight gate. Only an actual LIGHT frame requires darkness;
    // calibration frames stay exempt even below a TargetHeader and with an
    // unparked mount.
    //
    // The gate keys off the FRAME TYPE, never off the presence of a
    // TargetHeader or of `ctx.target_ra`/`target_dec` — keying off those
    // refuses a target-nested node while letting a bare "Take Exposures"
    // write LIGHT frames in full daylight. Whether the rig is pointed at the
    // sky is answered by the mount park state below, which is the real
    // discriminator.
    if frame_type_requires_darkness(&config.frame_type) {
        let on_sky = match &ctx.mount_id {
            // No mount configured: there is no rig to point at the sky, so this
            // cannot be an on-sky light capture — abstain.
            None => false,
            Some(mount_id) => match ctx.device_ops.mount_is_parked(mount_id).await {
                // Parked rig => calibration/darks, never on-sky lights.
                Ok(true) => false,
                Ok(false) => true,
                // Park status unknown (old driver): treat as on-sky so the gate
                // fails CLOSED on a genuine science-target light capture.
                Err(e) => {
                    tracing::debug!(
                        "Daylight gate could not read mount park status ({e}); treating as on-sky (fail-closed)"
                    );
                    true
                }
            },
        };
        if on_sky {
            let max_sun_alt = resolve_max_sun_altitude(ctx).await;
            if let Some(reason) = daylight_gate_block_reason(
                ctx.latitude,
                ctx.longitude,
                max_sun_alt,
                "light-frame exposure",
            ) {
                tracing::warn!("{reason}");
                return InstructionResult::failure_with_recovery(
                    reason,
                    DAYLIGHT_GATE_RECOVERY_CODE,
                );
            }
        }
    }

    if let Err(error) = validate_exposure_filter_request(
        config.filter.as_deref(),
        config.filter_index,
        ctx.filterwheel_id.as_deref(),
    ) {
        return InstructionResult::failure(error);
    }

    // log "(no filter set)" rather than substituting a filter name like
    // "unfiltered", which reads as a real filter in operator logs.
    tracing::info!(
        "Starting {} {} x {:.1}s exposures",
        config.count,
        match config.filter.as_deref() {
            Some(name) if !name.is_empty() => name.to_string(),
            _ => "(no filter set)".to_string(),
        },
        config.duration_secs
    );

    // Claim the imaging train (camera + filter wheel) for the wheel move and
    // the filter-identity read that follows it, so a trigger-fired action
    // cannot be part-way through its own filter move while this one runs.
    //
    // Unarbitrated, the two fought and both lost: on 2026-09-14 a trigger
    // autofocus commanded the wheel to "L" while this burst was cycling
    // Ha/SII/OIII, and autofocus then timed out after 120 s watching a healthy,
    // idle wheel sit at "SII". Ordering matters too — this claim is taken
    // BEFORE the wheel is commanded, not after, because a claim that starts at
    // the exposure has already let the wheel move.
    let filter_claim = match ImagingTrainClaimGuard::acquire(
        ctx,
        "the capture loop's filter change",
        BURST_FILTER_CHANGE_EXPECTED_SECS,
    )
    .await
    {
        Ok(claim) => claim,
        Err(cancelled) => return cancelled,
    };
    // Settle the filter identity ONCE for the whole burst, under the same claim
    // that commanded the wheel, so `observed_wheel_filter` cannot read a slot
    // some other action moved to in between. Every recording surface below
    // reads this pair, so the filename, the FITS FILTER card and the
    // `captured_images` row cannot disagree about the same frame. Resolving
    // here rather than in the TakeExposure node covers the capture paths that
    // do not go through a node at all — the Flat Wizard's final flat burst most
    // of all, where a missing FILTER card makes the flats unmatchable to the
    // lights they were shot for.
    let frame_filter = match apply_burst_filter(config, ctx).await {
        Ok(()) => Ok(resolve_frame_filter(config, ctx).await),
        Err(failure) => Err(failure),
    };
    filter_claim.release(ctx).await;
    let (frame_filter_name, frame_filter_index) = match frame_filter {
        Ok(pair) => pair,
        Err(failure) => return failure,
    };

    let (bin_x, bin_y) = match config.binning {
        Binning::One => (1, 1),
        Binning::Two => (2, 2),
        Binning::Three => (3, 3),
        Binning::Four => (4, 4),
    };

    let mut completed_exposures = 0u32;
    // Warn once per burst when dithers are skipped for lack of a guider.
    let mut dither_skipped_warned = false;
    let mut hfr_values = Vec::new();

    // Image Grading: local bindings for the per-frame grading state.
    // All these are Arc<_> handles shared with ExecutionContext so the
    // dashboard sees consistent totals across instruction boundaries.
    let frame_baseline_handle = ctx.hfr_baseline.clone();
    let frame_baseline_samples_handle = ctx.hfr_baseline_samples.clone();
    let consecutive_rejects_handle = ctx.consecutive_rejects.clone();
    let frames_accepted_handle = ctx.frames_accepted.clone();
    let frames_rejected_handle = ctx.frames_rejected.clone();
    let quality_check_default = ctx.default_quality_check.clone();
    let reject_folder_override = ctx.reject_folder_path.clone();

    // Frame-type gate: star-based analysis (HFR / star count / eccentricity),
    // quality grading, and in-burst dithering are only meaningful for
    // star-field frames. A dark/flat/bias burst has no stars — grading would
    // reject every frame as "0 stars", dithering would pulse the mount for
    // nothing, and per-frame star detection is pure wasted CPU (significant
    // on a Raspberry-Pi-class host). Snapshot frames are star fields, so
    // they keep the analysis but are captured like lights otherwise.
    let is_light_frame = config.frame_type.eq_ignore_ascii_case("light")
        || config.frame_type.eq_ignore_ascii_case("snapshot");

    for frame in 1..=config.count {
        if let Some(result) = ctx.check_cancelled() {
            return result;
        }

        // Operator Pause, honoured BETWEEN frames. The node tree checks
        // `is_paused` at instruction boundaries, but a burst is N frames
        // inside ONE instruction — so a Pause pressed during frame 2 of 3 used
        // to show a PAUSED badge, a Resume button and "Paused 33%" while the
        // camera went on to expose frame 3 and the run then recorded
        // `completed`. An operator pauses to walk in front of the telescope,
        // so no NEW exposure may start while paused.
        //
        // The frame already integrating is allowed to finish: aborting it
        // throws away data the operator did not ask to lose, and the shutter
        // is already open by the time the request lands. The guarantee is
        // therefore "no new exposure starts", not "the shutter shuts now".
        if !control
            .pause
            .wait_while_paused(&ctx.cancellation_token)
            .await
        {
            return InstructionResult::cancelled("Exposure cancelled while paused");
        }

        // Pre-frame meridian gate (N.I.N.A.-style): when the flip trigger
        // would fire while this frame is still exposing, hold here until the
        // trigger-driven flip completes instead of starting a frame the slew
        // would ruin. Only science-target lights are gated — the flip
        // trigger itself only ever fires for a tracked target.
        //
        // The frame-type check is what makes that comment true. Without it a
        // calibration frame sitting inside a TargetHeader was gated as well:
        // observed a 3s DARK held with "meridian flip fires in ~0s and would
        // interrupt it", which stalled the run for the gate's full 30-minute
        // bound. A dark/bias/flat is taken with the shutter closed or on a flat
        // panel, so where the mount is pointing cannot ruin it — and a
        // calibration block is exactly when the operator is not tracking a
        // target at all.
        let gate_for_meridian = config.frame_type.eq_ignore_ascii_case("light")
            && ctx.target_ra.is_some()
            && ctx.mount_id.is_some();
        if gate_for_meridian {
            if let Some(result) =
                wait_for_meridian_flip_window(ctx, config.duration_secs, control).await
            {
                return result;
            }
        }

        tracing::info!(
            "Capturing frame {}/{} ({:.1}s)",
            frame,
            config.count,
            config.duration_secs
        );

        // Take the imaging train before exposing, waiting if a trigger-fired
        // action currently holds it.
        //
        // This is the mirror of the hold on the trigger side, and both halves
        // are needed. With only the trigger waiting for the capture loop, the
        // loop simply started the next frame *during* the autofocus and the
        // same "No exposure is available to download" failure came back 20 s
        // later — the race had swapped ends, not closed. One claim, taken by
        // whoever gets there first, is what actually serialises them.
        //
        // The wait for the train can outlast the pause check above: the action
        // that held it may have paused the run before handing it back (an
        // autofocus that left the guider dead does). So the pause is checked
        // again with the train in hand, and a paused run gives it back and
        // waits instead of starting the frame.
        let frame_claim = loop {
            let claim = match ImagingTrainClaimGuard::acquire(
                ctx,
                "the next exposure",
                config.duration_secs,
            )
            .await
            {
                Ok(claim) => claim,
                Err(cancelled) => return cancelled,
            };
            if !control.pause.is_paused() {
                break claim;
            }
            claim.release(ctx).await;
            if !control
                .pause
                .wait_while_paused(&ctx.cancellation_token)
                .await
            {
                return InstructionResult::cancelled("Exposure cancelled while paused");
            }
        };

        // The instant the shutter opens. FITS DATE-OBS means START of
        // observation, so it is captured here, immediately before the exposure
        // call — stamping it at header-build time (after readout) makes every
        // frame late by its own exposure time.
        let exposure_started_at = chrono::Utc::now();

        // tokio::select! is the only way to honour cancellation during a
        // blocking exposure without driver support; the abort branch tells
        // the camera to stop so it does not continue exposing in the
        // background after we abandon the future.
        let mut abort_guard =
            CameraExposureAbortGuard::new(ctx.device_ops.clone(), camera_id.clone());
        let exposure_result = tokio::select! {
            biased;
            _ = wait_for_cancellation(ctx.cancellation_token.clone()) => {
                tracing::info!("Exposure cancelled, aborting camera...");
                match ctx.device_ops.camera_abort_exposure(&camera_id).await {
                    Ok(()) => abort_guard.disarm(),
                    Err(error) => tracing::error!(
                        "Camera abort failed during exposure cancellation: {}",
                        error
                    ),
                }
                frame_claim.release(ctx).await;
                return InstructionResult::cancelled("Exposure cancelled");
            }
            // Thread the frame type so shuttered cameras (Moravian, FLI, some
            // CCDs) keep the shutter CLOSED for dark/bias frames.
            result = ctx.device_ops.camera_start_exposure_with_frame_type(
                &camera_id,
                config.duration_secs,
                config.gain,
                config.offset,
                bin_x,
                bin_y,
                &config.frame_type,
            ) => {
                abort_guard.disarm();
                result
            }
        };
        // The frame is off the camera (or failed): release the claim on both
        // paths. A failure that returned without releasing would leave the hold
        // to lapse on its expiry, which is safe but delays the next
        // trigger-fired action for no reason.
        frame_claim.release(ctx).await;

        let mut image_data = match exposure_result {
            Ok(data) => {
                tracing::info!(
                    "[SEQ] Exposure completed: {}x{} image ({} pixels)",
                    data.width,
                    data.height,
                    data.data.len()
                );
                data
            }
            Err(error) => return InstructionResult::failure(format!("Exposure failed: {}", error)),
        };

        // per-frame defect-map application.
        //
        // The capture path applies the pre-loaded defect map (pushed in
        // via `ExecutorCommand::UpdateDefectMap`) before HFR / grading
        // / FITS save. We deliberately run BEFORE star detection so the
        // grader doesn't reject frames over hot-pixel-induced false
        // stars; HFR / detection costs are unaffected because the map
        // is sparse (~10k of 26M pixels for typical CMOS sensors) and
        // the correction is O(defects · kernel_area).
        //
        // Mismatches (camera id changed, sensor size changed) are
        // surfaced as warn-level logs and the correction is skipped —
        // applying a map built for a different sensor would silently
        // poison the data, but failing the burst would over-react to
        // an operator hot-swapping cameras. The user sees the warn
        // and the frame's FITS HISTORY card records that no correction
        // ran.
        //
        // When `save_original = true` we snapshot the pre-correction
        // pixels here so the Raw/ archive step can save them alongside
        // the corrected frame later. A pre-clone is a ~50 MB heap
        // copy per 26 MP frame, so we only do it when the user
        // explicitly opted in — opt-out users pay zero.
        let mut original_pixels_snapshot: Option<Vec<u16>> = None;
        let should_snapshot_original = {
            let guard = ctx.defect_map_apply.read().await;
            guard.as_ref().map(|s| s.save_original).unwrap_or(false)
        };
        if should_snapshot_original {
            original_pixels_snapshot = Some(image_data.data.clone());
        }
        let defect_map_outcome =
            apply_defect_map_if_configured(ctx, &camera_id, &mut image_data, frame).await;
        // Drop the snapshot if no correction actually happened — saving a
        // verbatim copy of an uncorrected frame would just duplicate the
        // canonical save and waste disk space.
        if !matches!(defect_map_outcome, DefectMapOutcome::Applied { .. }) {
            original_pixels_snapshot = None;
        }

        // Per-frame HFR feeds the HfrDegraded / FocusDrift triggers; computing
        // it here (rather than only on autofocus) gives the triggers real-time
        // visibility into focus health between AF runs.
        let measured_hfr = if !is_light_frame {
            // Calibration frames have no stars; skip the detector entirely.
            None
        } else {
            match ctx.device_ops.calculate_image_hfr(&image_data).await {
                Ok(Some(hfr)) => {
                    tracing::info!("Frame {}/{} HFR: {:.2} pixels", frame, config.count, hfr);
                    hfr_values.push(hfr);
                    Some(hfr)
                }
                Ok(None) => {
                    tracing::warn!(
                        "Frame {}/{} - no stars detected for HFR calculation",
                        frame,
                        config.count
                    );
                    None
                }
                Err(e) => {
                    tracing::warn!(
                        "Frame {}/{} - HFR calculation failed: {}",
                        frame,
                        config.count,
                        e
                    );
                    None
                }
            }
        };

        // Image Grading: derive star count from the star detector so
        // the grading check can apply the star_count_min floor.
        let measured_star_count = if !is_light_frame {
            None
        } else {
            match ctx.device_ops.detect_stars_in_image(&image_data).await {
                Ok(stars) => Some(stars.len() as u32),
                Err(e) => {
                    tracing::debug!(
                        "Frame {}/{} - star detection failed for grading: {}",
                        frame,
                        config.count,
                        e
                    );
                    None
                }
            }
        };

        // Per-frame eccentricity (0.0 = round, →1.0 = trailed) from the star
        // shape moments. `None` is honest absence — no stars, or too few
        // reliable stars to form a stable median — which `grade_frame` treats
        // as "unknown, don't reject". With stars present this is a real
        // measurement, so a configured `eccentricity_threshold` now fires.
        let measured_eccentricity = if !is_light_frame {
            None
        } else {
            match ctx.device_ops.measure_frame_eccentricity(&image_data).await {
                Ok(ecc) => ecc,
                Err(e) => {
                    tracing::debug!(
                        "Frame {}/{} - eccentricity measurement failed for grading: {}",
                        frame,
                        config.count,
                        e
                    );
                    None
                }
            }
        };
        let metrics = crate::quality::FrameMetrics {
            hfr: measured_hfr,
            eccentricity: measured_eccentricity,
            star_count: measured_star_count,
        };

        // Pick the (base_path, filename) pair. When a path_renderer
        // is supplied (the normal in-sequence case) it owns interpolation of
        // the `ExposureConfig.save_to` template and produces a fully resolved
        // directory + filename; an error from the renderer is fatal because
        // a broken template silently writing to the wrong place would be a
        // data-integrity disaster.
        //
        // When no renderer is supplied (legacy direct invocations from
        // tests), we fall back to the pre-Wave-4 hardcoded layout: base
        // path from `ctx.save_path`, filename `<target>_<filter>_<NNNN>.fits`.
        let (base_path, filename_template) = if let Some(renderer) = path_renderer.as_ref() {
            match renderer(frame, config.count) {
                Ok((dir, name)) => (Some(dir), Some(name)),
                Err(msg) => {
                    let error_message = format!(
                        "Save-path template render failed for frame {}/{}: {}. \
                         Aborting exposure — silently saving to the wrong path \
                         would corrupt the session's data integrity.",
                        frame, config.count, msg
                    );
                    tracing::error!("{}", error_message);
                    if let Some(event_tx) = &ctx.event_tx {
                        let _ = event_tx.send(crate::executor::ExecutorEvent::Error {
                            message: error_message.clone(),
                        });
                    }
                    return InstructionResult::failure(error_message);
                }
            }
        } else {
            (ctx.save_path.clone(), None)
        };

        if let Some(base_path) = base_path {
            // never silently substitute target name or filter.
            // A missing target name during normal imaging is a configuration
            // bug — emitting `image_L_0001.fits` hides which session the
            // frame belongs to and cannot be undone after the fact.
            // A missing filter labelled `L` mis-labels narrowband captures
            // as luminance.
            //
            // We log at warn! and use distinct synthetic placeholders that
            // are obvious in directory listings so an operator can audit
            // the run. If both fields are present this code path is silent.
            let filename = if let Some(name) = filename_template {
                name
            } else {
                // Legacy renderer-less fallback retained verbatim from the
                // pre-Wave-4 contract.
                let target_label = match ctx.target_name.as_deref() {
                    Some(name) if !name.is_empty() => name.to_string(),
                    _ => {
                        tracing::warn!(
                            "[CAPTURE] Saving frame with no target name — using synthetic label \"untargeted\". \
                             This indicates the sequence was started without a TargetHeader/TargetGroup; review the configuration."
                        );
                        "untargeted".to_string()
                    }
                };
                let filter_label = match frame_filter_name.as_deref() {
                    Some(name) if !name.is_empty() => name.to_string(),
                    _ => {
                        tracing::warn!(
                            "[CAPTURE] Saving frame with no filter set — using synthetic label \"nofilter\" (NOT \"L\"). \
                             A missing filter for narrowband/RGB captures would mis-label the frame as luminance."
                        );
                        "nofilter".to_string()
                    }
                };
                format!("{}_{}_{:04}.fits", target_label, filter_label, frame)
            };

            // Image Grading: decide accept/reject BEFORE picking the
            // final path — rejects go to a sibling Reject/ folder. The
            // grading honours the per-burst override (`config.quality_check`)
            // first, then falls back to the global default from runtime_config
            // (set by the executor at start time). If neither is configured
            // the frame is accepted unconditionally and the path stays the
            // canonical capture folder.
            let active_check = if is_light_frame {
                config
                    .quality_check
                    .as_ref()
                    .or(quality_check_default.as_ref())
            } else {
                // Never grade calibration frames — star-quality gates would
                // reject an entire dark/flat/bias burst as "0 stars".
                None
            };
            let (grade, save_dir, was_graded) = if let Some(qc) = active_check {
                // Read baseline (None until the warmup window fills).
                let baseline = { *frame_baseline_handle.read().await };
                let g = crate::quality::grade_frame(qc, &metrics, baseline);
                match g {
                    crate::quality::FrameGrade::Pass => {
                        // Update the rolling baseline with this accepted HFR.
                        {
                            let mut baseline_guard = frame_baseline_handle.write().await;
                            let mut samples_guard = frame_baseline_samples_handle.write().await;
                            crate::quality::update_hfr_baseline(
                                &mut baseline_guard,
                                &mut samples_guard,
                                measured_hfr,
                            );
                        }
                        (g, base_path.clone(), true)
                    }
                    crate::quality::FrameGrade::Reject { .. } => {
                        let dir = resolve_reject_dir(&base_path, reject_folder_override.as_deref());
                        (g, dir, true)
                    }
                }
            } else {
                (crate::quality::FrameGrade::Pass, base_path.clone(), false)
            };

            // Ensure reject dir exists if grading routed us there. The dir
            // create error is fatal because writing into a non-existent path
            // would be a data-loss event identical to the FITS save failure
            // below.
            if grade.is_reject() {
                if let Err(e) = std::fs::create_dir_all(&save_dir) {
                    let error_message = format!(
                        "Reject folder '{}' could not be created: {}. \
                         Frame {}/{} not saved; sequence aborted.",
                        save_dir.display(),
                        e,
                        frame,
                        config.count
                    );
                    tracing::error!("{}", error_message);
                    if let Some(event_tx) = &ctx.event_tx {
                        let _ = event_tx.send(crate::executor::ExecutorEvent::Error {
                            message: error_message.clone(),
                        });
                    }
                    return InstructionResult::failure(error_message);
                }
            }

            let full_path = ensure_unique_save_path(save_dir.join(&filename));

            // archive the uncorrected frame to
            // `<save_dir>/Raw/` BEFORE the canonical save if the user
            // opted in. The raw is written via a minimal FITS header
            // (no defect-map history, IMAGETYP=Light) so re-runs of
            // the correction or independent calibration workflows can
            // re-derive results from the original pixels.
            if matches!(
                defect_map_outcome,
                DefectMapOutcome::Applied {
                    save_original: true,
                    ..
                }
            ) {
                if let Some(original) = &original_pixels_snapshot {
                    if let Err(e) = save_uncorrected_raw_frame(
                        &save_dir,
                        &filename,
                        image_data.width,
                        image_data.height,
                        original,
                    )
                    .await
                    {
                        // Save-original failure is non-fatal — we still
                        // want the corrected frame to land. Log at warn
                        // so the operator sees the partial outcome.
                        tracing::warn!(
                            "[DEFECT] Raw/ archive save failed for frame {}/{}: {}. \
                             The corrected frame will still be saved.",
                            frame,
                            config.count,
                            e,
                        );
                    }
                } else {
                    // Defensive: snapshot is taken only when
                    // save_original was true at correction time, so an
                    // Applied{save_original:true} without snapshot
                    // means an ordering bug in this function.
                    tracing::error!(
                        "[DEFECT] save_original requested but no pre-correction snapshot \
                         exists for frame {}/{}; Raw/ archive skipped.",
                        frame,
                        config.count,
                    );
                }
            }

            // Image Grading: build the per-frame FITS-header bundle
            // from InstructionContext (session-static + per-target fields)
            // plus live device telemetry (sensor temp, focuser position,
            // rotator angle, guide RMS). Each field is best-effort — a
            // device that fails to report its position simply omits that
            // FITS keyword (silent fallbacks would lie about the data).
            //
            // thread the defect-map application outcome
            // so the FITS HISTORY card records the correction provenance.
            let frame_ctx = build_frame_context_for_save(
                ctx,
                config,
                &image_data,
                frame,
                defect_map_outcome.clone(),
                exposure_started_at,
                (frame_filter_name.clone(), frame_filter_index),
            )
            .await;

            if let Err(e) = ctx
                .device_ops
                .save_fits(
                    &image_data,
                    // Why: `PathBuf::to_str()` returns None only when the
                    // path is not valid UTF-8 — on Windows our save paths are always
                    // platform-default (UTF-16 → UTF-8) and on Unix the user's home dir is
                    // the root, both ASCII-safe in practice. Falling back to the bare
                    // filename keeps the save call going against the platform's CWD; the
                    // FITS writer downstream will surface any path-resolution error.
                    full_path.to_str().unwrap_or(&filename),
                    &frame_ctx,
                )
                .await
            {
                // A FITS save failure is data loss — the
                // exposure is already complete and the image bytes are in
                // RAM, so a failed write means that frame is gone. The
                // previous warn-and-continue was the audit-flagged silent
                // fallback: the user would discover the missing frame hours
                // later when checking captures, with no surfaced error.
                //
                // Policy: log at ERROR, emit an ExecutorEvent::Error so the
                // UI sees it, and return InstructionResult::failure so the
                // sequence stops and the user can intervene (out-of-disk,
                // permission denied, drive disconnected — every cause needs
                // human action).
                let error_message = format!(
                    "FITS save failed for frame {}/{} at '{}': {}. \
                     Image data has been lost. Sequence aborted to preserve \
                     remaining storage and surface the issue.",
                    frame,
                    config.count,
                    full_path.display(),
                    e
                );
                tracing::error!("{}", error_message);
                if let Some(event_tx) = &ctx.event_tx {
                    // Why: a closed receiver (no UI subscribers) is benign —
                    // headless / API runs may have no listeners. The log line
                    // above is the durable record.
                    let _ = event_tx.send(crate::executor::ExecutorEvent::Error {
                        message: error_message.clone(),
                    });
                }
                return InstructionResult::failure(error_message);
            }
            tracing::info!("Saved: {}", full_path.display());

            // Register EVERY saved frame, graded or not, and emit the
            // Accepted / Rejected progress event so the dashboard quality panel
            // updates and the budget tracker can skip rejected frames.
            //
            // This emission is also what makes the app RECORD the frame: Dart's
            // `_registerSequenceFrame` listens for `FrameAccepted` and writes the
            // `captured_images` row, populating `producing_node_id` /
            // `producing_run_id`. Behind a `was_graded` check — grading is off by
            // default — a whole automated night produces FITS files on disk and no
            // database rows, so no Analytics stats and no gallery entries. The
            // grader DECISION stays gated inside `emit_grade_progress`.
            emit_grade_progress(
                ctx,
                grade,
                &metrics,
                was_graded,
                frame,
                config.count,
                &full_path,
                // Same struct the `save_fits` call above stamped the header
                // from — not a re-read, not a reconstruction.
                &frame_ctx,
                &frames_accepted_handle,
                &frames_rejected_handle,
                &consecutive_rejects_handle,
                active_check
                    .map(|c| c.max_consecutive_rejects)
                    .unwrap_or(u32::MAX),
            )
            .await;
        } else {
            // No resolvable save location: the frame was captured off the
            // sensor and is about to be counted as a completed exposure, but
            // nothing will be written to disk. Say so LOUDLY — this branch
            // silently discarded science frames, so a whole session could
            // report "completed" at 100% while leaving no files behind
            // (observed live on a headless rig with no save path configured).
            // Not a hard failure: transient exposures (autofocus, framing,
            // live view) legitimately reach here with no save path.
            tracing::warn!(
                "Frame {}/{} captured but NOT SAVED: no save location resolved \
                 (no per-node save_to template and no sequencer save path \
                 configured). Set the sequencer save path (or the node's \
                 save_to) or this frame is discarded.",
                frame,
                config.count
            );
        }

        completed_exposures += 1;

        // The seconds this frame is recorded as — the same number the FITS
        // header and the `captured_images` row were written from — so the run's
        // integration total sums what was collected rather than what was
        // planned.
        let recorded_secs = crate::instructions::recorded_exposure_secs(
            config.duration_secs,
            image_data.exposure_secs,
        );
        progress_callback(frame, config.count, recorded_secs);

        // `frame < config.count` skips the dither after the final frame:
        // dithering after the last exposure of a burst leaves the mount
        // off-target for the next instruction (and wastes time).
        if let Some(dither_every) = config.dither_every {
            // `is_light_frame`: never dither a calibration burst — the serializer
            // inherits the global dither-every default onto every exposure node,
            // so darks/flats would otherwise pulse the mount between frames.
            if is_light_frame
                && dither_every > 0
                && frame % dither_every == 0
                && frame < config.count
            {
                tracing::info!("Dithering...");
                // Dual-rig — guard the burst dither so a piggybacking secondary
                // camera is clear before the mount pulses (no-op single-rig).
                let dither_result = dither_guarded(ctx, || {
                    ctx.device_ops.guider_dither(
                        config.dither_pixels,
                        config.dither_settle_pixels,
                        config.dither_settle_time,
                        config.dither_settle_timeout,
                        config.dither_ra_only,
                    )
                })
                .await;
                if dither_result.is_ok() {
                    // A dither that settled ends a failure streak, as the
                    // standalone Dither node counts it.
                    if let Some(trigger_state) = &ctx.trigger_state {
                        trigger_state.write().await.consecutive_dither_failures = 0;
                    }
                }
                if let Err(e) = dither_result {
                    // An UNGUIDED rig cannot dither, and that is a
                    // CONFIGURATION state — not a guiding failure. No star was
                    // lost, no walking-noise problem is being masked, and no
                    // recovery/guiding trigger can help, so killing an
                    // otherwise-healthy burst over it is wrong.
                    //
                    // It bites by default: the serializer inherits the GLOBAL
                    // dither-every onto every exposure node (see the
                    // `is_light_frame` note above), so a plain light burst on a
                    // rig with no guider schedules a dither it can never perform.
                    // Reproduced on the desktop build with the simulator camera:
                    // an 8-frame burst died after frame 3 with "Dither failed
                    // after frame 3/8: No active guider configured", losing the
                    // remaining 5 frames and the unattended night with them.
                    //
                    // Skip loudly, once per burst, and keep imaging. Every other
                    // dither/settle failure keeps the fail-closed abort below.
                    if crate::device_ops::is_no_guider_configured(&e.to_string()) {
                        if !dither_skipped_warned {
                            dither_skipped_warned = true;
                            tracing::warn!(
                                "Dither requested after frame {}/{} but no guider is \
                                 configured — skipping dithers for the rest of this \
                                 burst. Frames will be UNDITHERED (walking noise); \
                                 connect a guider or set dither-every to 0 to \
                                 silence this.",
                                frame,
                                config.count
                            );
                        }
                    } else if ctx.stops_on_quality_problems().await {
                        // The operator asked for quality problems to stop the
                        // run: fail the burst as this used to by default.
                        let error_message = format!(
                            "Dither failed after frame {}/{}: {}",
                            frame, config.count, e
                        );
                        tracing::error!("{}", error_message);
                        if let Some(event_tx) = &ctx.event_tx {
                            let _ = event_tx.send(crate::executor::ExecutorEvent::Error {
                                message: error_message.clone(),
                            });
                        }
                        return InstructionResult::failure(error_message);
                    } else {
                        // A dither that does not settle costs some stacking
                        // quality, not the frames, and the standalone Dither node
                        // already carries on through it. Failing the burst here
                        // ended the run (owner decision 2026-10-06: only a risk
                        // to the hardware stops a run by itself). The operator is
                        // told once per streak — a lost guide star is the guide
                        // star triggers' business, not this burst's.
                        let streak = match &ctx.trigger_state {
                            Some(trigger_state) => {
                                let mut state = trigger_state.write().await;
                                state.consecutive_dither_failures =
                                    state.consecutive_dither_failures.saturating_add(1);
                                state.consecutive_dither_failures
                            }
                            None => 1,
                        };
                        let problem = format!(
                            "Dither failed after frame {}/{}: {}. The frames are unaffected, \
                             but they are not dithered until a dither settles again.",
                            frame, config.count, e
                        );
                        if streak == 1 {
                            ctx.notify_quality_problem_continuing("Exposure burst", &problem);
                        } else {
                            tracing::warn!("{} ({} in a row)", problem, streak);
                        }
                    }
                }
            }
        }
    }

    InstructionResult {
        status: NodeStatus::Success,
        message: Some(format!("Completed {} exposures", completed_exposures)),
        data: Some(serde_json::json!({
            "completed": completed_exposures,
            "total": config.count,
        })),
        hfr_values,
    }
}

/// Seconds a whole-burst filter change is expected to take, including the focus
/// offset move that follows it.
///
/// An estimate only: it sizes the hold message a waiting trigger logs. A wheel
/// that takes longer keeps the claim (see
/// `IMAGING_TRAIN_CLAIM_OVERRUN_GRACE_SECS`) rather than handing the devices
/// over mid-move.
const BURST_FILTER_CHANGE_EXPECTED_SECS: f64 = 30.0;

/// Command the wheel to this burst's filter and apply its focus offset.
///
/// Extracted from `execute_exposure_with_renderer` so the whole move has one
/// entry and one exit and can therefore be wrapped in a single imaging-train
/// claim; the several failure exits inside it are exactly why a single
/// release point was needed.
async fn apply_burst_filter(
    config: &ExposureConfig,
    ctx: &InstructionContext,
) -> Result<(), InstructionResult> {
    // Position-index is preferred over name because filter names are
    // user-editable strings that can drift between profile and device
    // (e.g. "Ha" vs "H-alpha"); the position is the wheel's stable
    // hardware addressing.
    if config
        .filter
        .as_deref()
        .is_some_and(|name| !name.trim().is_empty())
        || config.filter_index.is_some()
    {
        if let Some(fw_id) = &ctx.filterwheel_id {
            if let Some(index) = config.filter_index {
                tracing::info!(
                    "Changing to filter position: {} (name: {:?})",
                    index,
                    config.filter
                );
                if let Err(e) = ctx.device_ops.filterwheel_set_position(fw_id, index).await {
                    return Err(InstructionResult::failure(format!(
                        "Failed to change filter: {}",
                        e
                    )));
                }
                let filter_name = match config.filter.as_deref() {
                    Some(name) if !name.is_empty() => Some(name.to_string()),
                    _ if !ctx.filter_focus_offsets.is_empty() => {
                        match ctx.device_ops.filterwheel_get_names(fw_id).await {
                            Ok(names) if index >= 0 => match names.get(index as usize) {
                                Some(name) => Some(name.clone()),
                                None => {
                                    return Err(InstructionResult::failure(format!(
                                    "Filter position {} has no configured filter name for focus offset lookup",
                                    index
                                )));
                                }
                            },
                            Ok(_) => {
                                return Err(InstructionResult::failure(format!(
                                    "Invalid negative filter position {} for focus offset lookup",
                                    index
                                )));
                            }
                            Err(e) => {
                                return Err(InstructionResult::failure(format!(
                                    "Failed to read filter names for focus offset lookup: {}",
                                    e
                                )));
                            }
                        }
                    }
                    _ => None,
                };
                if let Some(filter_name) = filter_name {
                    if let Err(e) = apply_filter_focus_offset(&filter_name, ctx, None).await {
                        return Err(InstructionResult::failure(format!(
                            "Focus offset failed for filter \"{}\": {}",
                            filter_name, e
                        )));
                    }
                }
            } else if let Some(filter) = &config.filter {
                tracing::info!("Changing to filter by name: {}", filter);
                if let Err(e) = ctx
                    .device_ops
                    .filterwheel_set_filter_by_name(fw_id, filter)
                    .await
                {
                    return Err(InstructionResult::failure(format!(
                        "Failed to change filter: {}",
                        e
                    )));
                }
                if let Err(e) = apply_filter_focus_offset(filter, ctx, None).await {
                    return Err(InstructionResult::failure(format!(
                        "Focus offset failed for filter \"{}\": {}",
                        filter, e
                    )));
                }
            }
        }
    }
    Ok(())
}
