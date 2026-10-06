//! `grading.rs` — moved verbatim out of the former single-file `instructions.rs`
//! (release-pass C3 mechanical split). No logic changed; private items were
//! widened to `pub(crate)` so the sibling modules and the tests module still
//! see them, and `super::*` supplies the imports the original file had.

use super::*;

// IMAGE-GRADING helpers (Image Grading)

// DEFECT-MAP helpers

/// Outcome of the per-frame defect-map application step. Threaded into
/// the FITS HISTORY card emitter so the saved frame carries provenance
/// of the correction (or its skip reason).
#[derive(Debug, Clone)]
pub(crate) enum DefectMapOutcome {
    /// No defect map is configured for the current run. Common case
    /// for users who haven't opted in to defect correction.
    Disabled,
    /// A map was configured but the connected camera id did not match
    /// the map's camera id, OR the map's dimensions did not match the
    /// frame's. In either case the frame is left as-is and a warn line
    /// is logged so the operator sees the skip.
    ///
    /// `reason` is constructed at the call sites, with the specific mismatch
    /// detail, and surfaced in the warn line emitted there.
    SkippedMismatch {
        #[allow(dead_code)]
        reason: String,
    },
    /// The map matched and was applied. The corrected pixel count may
    /// be smaller than the map's defective_count when some defects had
    /// no healthy neighbours inside the expanded kernel.
    Applied {
        camera_id: String,
        defect_count: u32,
        corrected_count: u32,
        kernel_diameter: u8,
        method: &'static str,
        save_original: bool,
    },
}

impl DefectMapOutcome {
    /// Convert to a FrameContext-side record. Returns `None` when no
    /// correction was actually applied — callers must not emit a
    /// HISTORY card claiming a correction happened when one did not.
    pub(crate) fn into_record(self) -> Option<crate::scheduling::DefectMapCorrectionRecord> {
        match self {
            DefectMapOutcome::Applied {
                camera_id,
                defect_count,
                corrected_count,
                kernel_diameter,
                method,
                save_original: _,
            } => Some(crate::scheduling::DefectMapCorrectionRecord {
                camera_id,
                defect_count,
                corrected_count,
                kernel_diameter,
                method: method.to_string(),
            }),
            DefectMapOutcome::Disabled | DefectMapOutcome::SkippedMismatch { .. } => None,
        }
    }
}

/// Apply the per-frame defect map to the just-captured image data, in
/// place. Returns the outcome (disabled / skipped / applied) so the
/// FITS HISTORY card emitter and the Raw/ archival step know what
/// happened.
///
/// Pre-conditions / safety:
/// * Camera id mismatch returns `SkippedMismatch` rather than
///   silently applying a map built for a different sensor — that
///   would poison the data with the wrong hot-pixel coordinates.
/// * Dimension mismatch returns `SkippedMismatch` for the same
///   reason; the map's bitmap is sized to the sensor it was built
///   against and applying it to a different frame size would write
///   neighbour medians at coordinates that don't correspond to real
///   defects.
///
/// Why a separate helper: keeping the borrow of
/// `defect_map_apply` to a short read-guard scope means the rest of
/// the capture loop is unaffected. Cloning the inner `Arc<DefectMap>`
/// is cheap (refcount bump) and lets us drop the guard before doing
/// the actual O(defects × kernel) correction work.
pub(crate) async fn apply_defect_map_if_configured(
    ctx: &InstructionContext,
    camera_id: &str,
    image_data: &mut crate::device_ops::ImageData,
    frame_idx: u32,
) -> DefectMapOutcome {
    let snapshot = {
        let guard = ctx.defect_map_apply.read().await;
        guard.clone()
    };
    let Some(state) = snapshot else {
        return DefectMapOutcome::Disabled;
    };

    if state.camera_id != camera_id {
        tracing::warn!(
            "[DEFECT] Frame {} skipping defect-map correction: connected camera id `{}` \
             does not match map's camera id `{}`. The map was built for a different \
             sensor and applying it would poison the data.",
            frame_idx,
            camera_id,
            state.camera_id,
        );
        return DefectMapOutcome::SkippedMismatch {
            reason: format!(
                "camera mismatch: map=`{}`, frame=`{}`",
                state.camera_id, camera_id
            ),
        };
    }

    if state.map.width != image_data.width || state.map.height != image_data.height {
        tracing::warn!(
            "[DEFECT] Frame {} skipping defect-map correction: map dimensions {}x{} do not \
             match frame dimensions {}x{}. A subframe / ROI change has invalidated the map; \
             rebuild it at the new sensor crop.",
            frame_idx,
            state.map.width,
            state.map.height,
            image_data.width,
            image_data.height,
        );
        return DefectMapOutcome::SkippedMismatch {
            reason: format!(
                "size mismatch: map={}x{}, frame={}x{}",
                state.map.width, state.map.height, image_data.width, image_data.height,
            ),
        };
    }

    if state.map.defective_count() == 0 {
        // Empty map = no work, but emit a HISTORY card so the operator
        // sees the map was selected (this catches "I built the map but
        // it has zero defects so nothing happened" confusion).
        return DefectMapOutcome::Applied {
            camera_id: state.camera_id.clone(),
            defect_count: 0,
            corrected_count: 0,
            kernel_diameter: state.kernel.diameter(),
            method: state.method.as_str(),
            save_original: state.save_original,
        };
    }

    let pixels_slice = image_data.data.as_mut_slice();
    let width = image_data.width;
    let height = image_data.height;
    // The sequencer's ImageData is mono u16 (camera output before
    // debayering). channels = 1 is enforced by the capture-side
    // contract; if a driver ever returns a multi-channel buffer we
    // skip correction rather than slice into the wrong storage.
    let channels = 1u32;
    let expected_len = (width as usize) * (height as usize) * (channels as usize);
    if pixels_slice.len() != expected_len {
        tracing::warn!(
            "[DEFECT] Frame {} skipping defect-map correction: pixel buffer length \
             {} does not match {}x{}x{} = {} expected u16 samples.",
            frame_idx,
            pixels_slice.len(),
            width,
            height,
            channels,
            expected_len,
        );
        return DefectMapOutcome::SkippedMismatch {
            reason: format!(
                "buffer length {} != expected {}",
                pixels_slice.len(),
                expected_len
            ),
        };
    }

    let start = std::time::Instant::now();
    let result = nightshade_imaging::defect_map::correct_u16_slice(
        pixels_slice,
        width,
        height,
        channels,
        &state.map,
        state.method,
        state.kernel,
    );
    let elapsed = start.elapsed();
    match result {
        Ok(corrected) => {
            tracing::info!(
                "[DEFECT] Frame {} corrected {} of {} defective pixels in {:.1}ms (kernel={}x{}, method={})",
                frame_idx,
                corrected,
                state.map.defective_count(),
                elapsed.as_secs_f64() * 1000.0,
                state.kernel.diameter(),
                state.kernel.diameter(),
                state.method.as_str(),
            );
            DefectMapOutcome::Applied {
                camera_id: state.camera_id.clone(),
                defect_count: state.map.defective_count(),
                corrected_count: corrected,
                kernel_diameter: state.kernel.diameter(),
                method: state.method.as_str(),
                save_original: state.save_original,
            }
        }
        Err(e) => {
            // Defensive: the slice-level corrector validates dimensions
            // before mutating, so we should never reach this branch
            // given the earlier checks. Surface the error rather than
            // silently swallowing it.
            tracing::error!(
                "[DEFECT] Frame {} defect-map correction failed: {}",
                frame_idx,
                e,
            );
            DefectMapOutcome::SkippedMismatch {
                reason: format!("corrector returned error: {}", e),
            }
        }
    }
}

/// Archive the uncorrected (pre-defect-map) pixels to `<save_dir>/Raw/`.
///
/// We use a minimal FITS writer here that only writes width/height +
/// the u16 sample data — the canonical FITS header (with target,
/// telescope, observer, etc.) is reserved for the corrected frame.
/// This keeps the Raw/ folder a literal "what the sensor produced"
/// archive that a re-stacking workflow can pull through a different
/// correction pipeline without having to subtract out the previous
/// Nightshade correction.
///
/// Why this writer (and not a DeviceOps call): the device-ops
/// `save_fits` writes the full FrameContext header. We deliberately
/// want a bare-bones FITS here so the raw archive can be replayed
/// through external calibration with no Nightshade-specific keywords
/// already on it.
pub(crate) async fn save_uncorrected_raw_frame(
    save_dir: &std::path::Path,
    filename: &str,
    width: u32,
    height: u32,
    pixels: &[u16],
) -> Result<(), String> {
    let raw_dir = save_dir.join("Raw");
    std::fs::create_dir_all(&raw_dir).map_err(|e| {
        format!(
            "could not create Raw/ directory `{}`: {}",
            raw_dir.display(),
            e
        )
    })?;
    let raw_path = raw_dir.join(filename);

    // We rely on the imaging crate's FITS writer for consistency with
    // the rest of the save pipeline. Constructing the ImageData here
    // is a u16→bytes shuffle — for a 26 MP frame that's ~50 MB but
    // it happens off-thread inside spawn_blocking so the capture loop
    // is not blocked.
    let pixels = pixels.to_vec();
    let raw_path_clone = raw_path.clone();
    let join = tokio::task::spawn_blocking(move || {
        let image = nightshade_imaging::ImageData::from_u16(width, height, 1, &pixels);
        let mut header = nightshade_imaging::FitsHeader::new();
        header.set_string("IMAGETYP", "LIGHT");
        header.set_string(
            "COMMENT",
            "Nightshade uncorrected raw (defect map not yet applied)",
        );
        nightshade_imaging::write_fits(&raw_path_clone, &image, &header)
            .map_err(|e| format!("write_fits failed: {}", e))
    })
    .await;
    match join {
        Ok(Ok(())) => {
            tracing::info!("[DEFECT] Raw archive written: {}", raw_path.display());
            Ok(())
        }
        Ok(Err(e)) => Err(e),
        Err(e) => Err(format!("spawn_blocking join failed: {}", e)),
    }
}

/// Resolve the directory where rejected frames go.
///
/// * `override_path = None`: use `<base>/Reject/`.
/// * `override_path = Some(absolute)`: use that path verbatim.
/// * `override_path = Some(relative)`: resolve against `base`.
pub fn resolve_reject_dir(base: &std::path::Path, override_path: Option<&str>) -> PathBuf {
    match override_path {
        Some(p) => {
            let candidate = std::path::Path::new(p);
            if candidate.is_absolute() {
                candidate.to_path_buf()
            } else {
                base.join(candidate)
            }
        }
        None => base.join("Reject"),
    }
}

/// forensics — snapshot the live environmental telemetry into a
/// single `EnvironmentSnapshot`. Each field is read independently with
/// `try_read()` semantics emulated by an `await`; the analyzer treats
/// `None` honestly (no fabrication of stand-ins).
pub(crate) async fn build_environment_snapshot(
    ctx: &InstructionContext,
) -> crate::quality::EnvironmentSnapshot {
    let sky_brightness_mag = *ctx.current_sky_brightness_mag.read().await;
    let cloud_cover_percent = ctx.cloud_motion_snapshot.read().await.current_cover_percent;
    let wind_kph = *ctx.current_wind_kph.read().await;
    // Guide RMS — pull the most recent sample from the trigger state's
    // rolling guide-RMS history. The history is a `Vec<(Instant, f64)>`
    // already maintained for the GuidingFailed trigger evaluator.
    let guide_rms_arcsec = if let Some(trigger_state_lock) = &ctx.trigger_state {
        let state = trigger_state_lock.read().await;
        state
            .guiding_rms_history
            .as_ref()
            .and_then(|h| h.last())
            .map(|(_, rms)| *rms)
    } else {
        None
    };
    let sensor_temp_c = *ctx.current_sensor_temp_c.read().await;
    crate::quality::EnvironmentSnapshot {
        sky_brightness_mag,
        cloud_cover_percent,
        wind_kph,
        guide_rms_arcsec,
        sensor_temp_c,
    }
}

/// forensics — append a sample to the rolling history, enforcing
/// the [`crate::quality::FORENSIC_HISTORY_LEN`] bound. Lock window is
/// minimal (one write_lock acquisition per frame) and the push is
/// guaranteed O(1) regardless of run length.
pub(crate) async fn push_forensic_sample(
    ctx: &InstructionContext,
    sample: crate::quality::RecentFrameSample,
) {
    let mut history = ctx.forensics_history.write().await;
    history.push_back(sample);
    while history.len() > crate::quality::FORENSIC_HISTORY_LEN {
        history.pop_front();
    }
}

/// Summary line of the decision row written when a streak of rejected frames
/// reaches the operator's limit. The app raises its "Frames being rejected"
/// notification from this row, once per streak; the run carries on.
pub const IMAGE_GRADING_REJECT_STREAK_SUMMARY: &str =
    "Frames rejected in a row — the run continues";

/// Emit a structured FrameAccepted / FrameRejected progress event and (on
/// reject) update the consecutive-rejects atomic. When a streak of rejects
/// reaches the limit the operator is notified once for that streak; nothing
/// pauses, stops or parks the run.
///
/// Frame-Failure Forensics: in addition to the existing event,
/// this function:
///
/// 1. Snapshots live environmental telemetry (sky brightness, cloud cover,
///    wind, guide RMS, sensor temperature) from the shared
///    `ExecutionContext` Arcs.
/// 2. On reject, consults [`crate::quality::analyze_rejection`] with the
///    rolling history to classify the rejection (`LikelyCause`) and
///    produce an evidence-bullet list.
/// 3. Pushes the new frame sample (accepted or rejected) onto the rolling
///    history so subsequent rejects have full context.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn emit_grade_progress(
    ctx: &InstructionContext,
    grade: crate::quality::FrameGrade,
    metrics: &crate::quality::FrameMetrics,
    // Whether a grader actually ran. The frame is REGISTERED either way (the
    // progress event below is what makes the app record it), but no grader
    // decision is written to the replay/decision log when no grader made one.
    was_graded: bool,
    frame: u32,
    total: u32,
    full_path: &std::path::Path,
    // The SAME `FrameContext` the FITS header for this frame was built from.
    // Passing it here (rather than re-reading the devices, or letting Dart
    // reconstruct the values from the sequence tree) is the whole point: one
    // struct stamps both the file and the database row, so they cannot drift.
    frame_ctx: &crate::scheduling::FrameContext,
    frames_accepted: &Arc<std::sync::atomic::AtomicU32>,
    frames_rejected: &Arc<std::sync::atomic::AtomicU32>,
    consecutive_rejects: &Arc<std::sync::atomic::AtomicU32>,
    max_consecutive: u32,
) {
    use std::sync::atomic::Ordering;
    let capture = crate::scheduling::FrameCaptureMetadata::from(frame_ctx);
    // forensics — snapshot the environment once up-front so the
    // values reported in the event match the values fed to the
    // classifier. (Two separate reads could race against the
    // ExecutorCommand::UpdateCloudMotion / UpdateSkyBrightness handlers.)
    let env_snapshot = build_environment_snapshot(ctx).await;
    match &grade {
        crate::quality::FrameGrade::Pass => {
            let accepted = frames_accepted.fetch_add(1, Ordering::Relaxed) + 1;
            consecutive_rejects.store(0, Ordering::Relaxed);
            let rejected = frames_rejected.load(Ordering::Relaxed);
            // forensics: log the accepted sample so subsequent
            // rejects can compare against it. We capture the env
            // snapshot too — the SeeingSpike / FocusDrift heuristics
            // require trailing accepted frames to have HFR populated.
            push_forensic_sample(
                ctx,
                crate::quality::RecentFrameSample {
                    unix_secs: chrono::Utc::now().timestamp() as f64,
                    accepted: true,
                    hfr: metrics.hfr,
                    eccentricity: metrics.eccentricity,
                    star_count: metrics.star_count,
                    sky_brightness_mag: env_snapshot.sky_brightness_mag,
                    cloud_cover_percent: env_snapshot.cloud_cover_percent,
                    wind_kph: env_snapshot.wind_kph,
                    guide_rms_arcsec: env_snapshot.guide_rms_arcsec,
                    sensor_temp_c: env_snapshot.sensor_temp_c,
                },
            )
            .await;
            // emit a structured `ProgressDetail::FrameAccepted` so
            // the bridge can dispatch the typed `SequencerEvent::FrameAccepted`
            // variant. The legacy `detail` string is still populated from
            // `ProgressDetail::detail_text()` so any subscriber that hasn't
            // migrated keeps working. The metrics come from `_metrics` (the
            // `FrameMetrics` computed by the grader) because `FrameGrade::Pass`
            // is a unit variant.
            let structured = crate::node::ProgressDetail::FrameAccepted {
                frame,
                total,
                hfr: metrics.hfr,
                eccentricity: metrics.eccentricity,
                star_count: metrics.star_count,
                accepted_total: accepted,
                rejected_total: rejected,
                // surface the on-disk save path so the
                // thumbnail strip can render an inline preview of
                // accepted frames the same way it already does for
                // rejected ones via `FrameRejected.reject_path`. The
                // path is the resolved FITS file we just wrote (so the
                // strip's path resolver can hand it straight to the
                // image-loader without further translation).
                save_path: Some(full_path.display().to_string()),
                capture: capture.clone(),
            };
            let detail_text = structured.detail_text();
            if let Some(event_tx) = &ctx.event_tx {
                let _ = event_tx.send(crate::executor::ExecutorEvent::NodeProgress {
                    node_id: ctx.node_id.clone(),
                    instruction: "Exposure".to_string(),
                    progress_percent: 100.0 * frame as f64 / total.max(1) as f64,
                    detail: detail_text,
                    structured_detail: Some(Box::new(structured)),
                });
            }
            // Replay Debug — record a FrameAccepted decision so
            // the replay timeline surfaces every accepted frame next
            // to the rejected ones. We hand the path through too so
            // the replay UI can cross-link to the captured-image row.
            //
            // Gated on `was_graded`: an ungraded frame is still registered
            // (above), but no grader DECISION is invented for it — nothing
            // graded it, so the replay timeline must not claim otherwise.
            if was_graded {
                ctx.emit_decision(crate::decision::DecisionEvent::new(
                    crate::decision::DecisionCategory::FrameAccepted,
                    format!(
                        "Frame {}/{} accepted{}",
                        frame,
                        total,
                        metrics
                            .hfr
                            .map(|h| format!(" (HFR {:.2})", h))
                            .unwrap_or_default(),
                    ),
                    serde_json::json!({
                        "frame": frame,
                        "total": total,
                        "hfr": metrics.hfr,
                        "eccentricity": metrics.eccentricity,
                        "star_count": metrics.star_count,
                        "save_path": full_path.display().to_string(),
                        "accepted_total": accepted,
                        "rejected_total": rejected,
                    }),
                ));
            }
        }
        crate::quality::FrameGrade::Reject {
            reason,
            hfr,
            eccentricity,
            star_count,
        } => {
            let rejected = frames_rejected.fetch_add(1, Ordering::Relaxed) + 1;
            let accepted = frames_accepted.load(Ordering::Relaxed);
            let consecutive = consecutive_rejects.fetch_add(1, Ordering::Relaxed) + 1;

            tracing::warn!(
                "[GRADE] Frame {}/{} REJECTED ({}× consecutive): {} (HFR={:?}, ecc={:?}, stars={:?}, path={})",
                frame,
                total,
                consecutive,
                reason,
                hfr,
                eccentricity,
                star_count,
                full_path.display()
            );

            // forensics — read the rolling history (cheap clone of
            // VecDeque -> Vec since only the analyzer needs a contiguous
            // slice) and consult the classifier. The history read MUST
            // happen before `push_forensic_sample` below so the current
            // frame doesn't classify against itself. We snapshot the HFR
            // baseline from the shared Arc the grader already uses, so
            // the classifier sees the same "what counts as elevated"
            // anchor.
            let history_snapshot: Vec<crate::quality::RecentFrameSample> = {
                let lock = ctx.forensics_history.read().await;
                lock.iter().cloned().collect()
            };
            let baseline_snapshot = *ctx.hfr_baseline.read().await;
            let verdict = crate::quality::analyze_rejection(&crate::quality::ForensicInputs {
                hfr: *hfr,
                eccentricity: *eccentricity,
                star_count: *star_count,
                hfr_baseline: baseline_snapshot,
                environment: env_snapshot.clone(),
                recent_frames: &history_snapshot,
                grader_reason: reason.as_str(),
            });
            tracing::info!(
                "[FORENSICS] Frame {}/{} cause={} evidence={:?}",
                frame,
                total,
                verdict.likely_cause.map(|c| c.label()).unwrap_or("none"),
                verdict.evidence,
            );

            // structured FrameRejected payload mirrors what the
            // bridge needs to dispatch SequencerEvent::FrameRejected; the
            // legacy detail string remains for back-compat.
            // forensics fields are populated from the verdict + the
            // pre-classification environment snapshot.
            let structured = crate::node::ProgressDetail::FrameRejected {
                frame,
                total,
                reason: reason.clone(),
                hfr: *hfr,
                eccentricity: *eccentricity,
                star_count: *star_count,
                reject_path: full_path.display().to_string(),
                consecutive_rejects: consecutive,
                accepted_total: accepted,
                rejected_total: rejected,
                likely_cause: verdict.likely_cause,
                evidence: verdict.evidence.clone(),
                sky_brightness_at_capture: env_snapshot.sky_brightness_mag,
                cloud_cover_at_capture: env_snapshot.cloud_cover_percent,
                wind_at_capture: env_snapshot.wind_kph,
                guide_rms_at_capture: env_snapshot.guide_rms_arcsec,
                sensor_temp_at_capture: env_snapshot.sensor_temp_c,
                capture: capture.clone(),
            };
            // Append the rejected sample to the history AFTER
            // classification so the next reject sees this one in its
            // neighbour cluster.
            push_forensic_sample(
                ctx,
                crate::quality::RecentFrameSample {
                    unix_secs: chrono::Utc::now().timestamp() as f64,
                    accepted: false,
                    hfr: *hfr,
                    eccentricity: *eccentricity,
                    star_count: *star_count,
                    sky_brightness_mag: env_snapshot.sky_brightness_mag,
                    cloud_cover_percent: env_snapshot.cloud_cover_percent,
                    wind_kph: env_snapshot.wind_kph,
                    guide_rms_arcsec: env_snapshot.guide_rms_arcsec,
                    sensor_temp_c: env_snapshot.sensor_temp_c,
                },
            )
            .await;
            let detail_text = structured.detail_text();
            if let Some(event_tx) = &ctx.event_tx {
                let _ = event_tx.send(crate::executor::ExecutorEvent::NodeProgress {
                    node_id: ctx.node_id.clone(),
                    instruction: "Exposure".to_string(),
                    progress_percent: 100.0 * frame as f64 / total.max(1) as f64,
                    detail: detail_text,
                    structured_detail: Some(Box::new(structured)),
                });
            }
            // Replay Debug — record a FrameRejected decision so
            // the replay timeline carries the verdict + forensics
            // payload alongside the consecutive-rejects escalation.
            // Cross-links to forensics via the `reject_path` field
            // which the replay UI uses to deep-link.
            ctx.emit_decision(crate::decision::DecisionEvent::new(
                crate::decision::DecisionCategory::FrameRejected,
                format!(
                    "Frame {}/{} REJECTED: {}{}",
                    frame,
                    total,
                    reason,
                    if consecutive > 1 {
                        format!(" ({}× consecutive)", consecutive)
                    } else {
                        String::new()
                    },
                ),
                serde_json::json!({
                    "frame": frame,
                    "total": total,
                    "reason": reason,
                    "hfr": hfr,
                    "eccentricity": eccentricity,
                    "star_count": star_count,
                    "reject_path": full_path.display().to_string(),
                    "consecutive_rejects": consecutive,
                    "accepted_total": accepted,
                    "rejected_total": rejected,
                }),
            ));

            // A streak of rejects reaching the limit is something the operator
            // should know about, and nothing more: the run keeps imaging, every
            // frame is still graded and the rejects stay in the Reject folder
            // (owner decision 2026-10-06: "this limit should never stop a
            // sequence or end a night. Again, just notify users of these
            // issues"). This used to hand the streak to the recovery driver,
            // which paused the run, or parked the mount under the opt-in
            // give-up policy, and it raised an Error banner on every further
            // reject. Told once, at the crossing: `consecutive` resets to 0 on
            // the next accepted frame, so a later streak is told about again.
            if max_consecutive > 0 && consecutive == max_consecutive {
                let notice = format!(
                    "Image grading: {} frames in a row rejected (notify limit {}), most recently \
                     frame {}/{}: {}. The run continues and every frame is kept; rejects are in \
                     the Reject folder. Accepted so far: {}, rejected: {}.",
                    consecutive, max_consecutive, frame, total, reason, accepted, rejected,
                );
                tracing::warn!("{}", notice);
                if let Some(event_tx) = &ctx.event_tx {
                    let _ =
                        event_tx.send(crate::executor::ExecutorEvent::Warning { message: notice });
                }
                ctx.emit_decision(crate::decision::DecisionEvent::new(
                    crate::decision::DecisionCategory::SystemEvent,
                    IMAGE_GRADING_REJECT_STREAK_SUMMARY.to_string(),
                    serde_json::json!({
                        "consecutive_rejects": consecutive,
                        "limit": max_consecutive,
                        "frame": frame,
                        "total": total,
                        "reason": reason,
                        "reject_path": full_path.display().to_string(),
                        "accepted_total": accepted,
                        "rejected_total": rejected,
                    }),
                ));
            }
        }
    }
}
