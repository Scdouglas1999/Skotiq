use super::*;

/// dispatch a structured `ProgressDetail` to a typed `SequencerEvent`
/// variant. Returns `None` when the variant has no first-class typed bridge
/// payload (the legacy `InstructionProgress` string variant covers those).
///
/// This is the single source of truth for the structured → typed
/// bridge mapping. The Dart dashboard panels consume the typed variants;
/// the legacy `InstructionProgress` stream is still published in parallel
/// so any subscriber that hasn't migrated keeps working (trigger
/// feed, telemetry exporters, etc.).
#[flutter_rust_bridge::frb(ignore)]
pub(crate) fn typed_sequencer_event_from_progress_detail(
    node_id: &str,
    detail: &skotiq_sequencer::ProgressDetail,
) -> Option<SequencerEvent> {
    use skotiq_sequencer::ProgressDetail as PD;
    // Import the bridge-side `SchedulerScoreEntry` so the FRB-public mapping
    // doesn't reach back into the sequencer crate's internal summary type.
    use crate::event::SchedulerScoreEntry;
    match detail {
        PD::FrameAccepted {
            frame,
            total,
            hfr,
            eccentricity,
            star_count,
            accepted_total,
            rejected_total,
            save_path,
            capture,
        } => Some(SequencerEvent::FrameAccepted {
            node_id: node_id.to_string(),
            frame: *frame,
            total: *total,
            hfr: *hfr,
            eccentricity: *eccentricity,
            star_count: *star_count,
            accepted_total: *accepted_total,
            rejected_total: *rejected_total,
            // surface the on-disk save path to Dart so
            // the thumbnail strip can render an inline preview of the
            // accepted frame (mirrors the existing reject_path flow).
            save_path: save_path.clone(),
            // Forwarded verbatim: this is the FITS header's own source, and
            // rewriting or re-deriving any of it here would recreate the
            // second source of truth the payload exists to remove.
            capture: capture.into(),
        }),
        PD::FrameRejected {
            frame,
            total,
            reason,
            hfr,
            eccentricity,
            star_count,
            reject_path,
            consecutive_rejects,
            accepted_total,
            rejected_total,
            // forensics fields — passed through verbatim so the
            // Dart `ForensicsService` can persist them in the
            // `frame_forensics` table.
            likely_cause,
            evidence,
            sky_brightness_at_capture,
            cloud_cover_at_capture,
            wind_at_capture,
            guide_rms_at_capture,
            sensor_temp_at_capture,
            capture,
        } => Some(SequencerEvent::FrameRejected {
            node_id: node_id.to_string(),
            frame: *frame,
            total: *total,
            reason: reason.clone(),
            hfr: *hfr,
            eccentricity: *eccentricity,
            star_count: *star_count,
            reject_path: reject_path.clone(),
            consecutive_rejects: *consecutive_rejects,
            accepted_total: *accepted_total,
            rejected_total: *rejected_total,
            // forensics — the `LikelyCause` enum's wire-stable
            // `label()` is converted to a String so the FRB schema does
            // not need to mirror the enum on the Dart side. The Dart
            // `ForensicsService` matches against these labels via the
            // `LikelyCauseExt.fromLabel` helper.
            likely_cause_label: likely_cause.map(|c| c.label().to_string()),
            evidence: evidence.clone(),
            sky_brightness_at_capture: *sky_brightness_at_capture,
            cloud_cover_at_capture: *cloud_cover_at_capture,
            wind_at_capture: *wind_at_capture,
            guide_rms_at_capture: *guide_rms_at_capture,
            sensor_temp_at_capture: *sensor_temp_at_capture,
            // Same one-source stamping as the accepted path: a rejected frame
            // is still on disk and still gets a `captured_images` row.
            capture: capture.into(),
        }),
        PD::Scheduler {
            decision_counter,
            picked_target_id,
            picked_target_name,
            picked_score,
            scores,
        } => {
            // Map the internal `SchedulerScoreSummary` to the FRB-facing
            // `SchedulerScoreEntry`. We deliberately collapse to the
            // dashboard-relevant fields (target_id, name, total_score,
            // runnable, skip_reason). Altitude / azimuth / airmass /
            // moon-distance / priority are available via the per-target
            // tooltip elsewhere; surfacing them on every scheduler
            // event would balloon the FRB payload for marginal benefit.
            let entries: Vec<SchedulerScoreEntry> = scores
                .iter()
                .map(|s| SchedulerScoreEntry {
                    target_id: s.target_id.clone(),
                    target_name: s.target_name.clone(),
                    total_score: s.total_score,
                    runnable: s.runnable,
                    reason: s.skip_reason.clone(),
                })
                .collect();
            Some(SequencerEvent::SchedulerDecision {
                node_id: node_id.to_string(),
                decision_counter: *decision_counter,
                picked_target_id: picked_target_id.clone(),
                picked_target_name: picked_target_name.clone(),
                picked_score: *picked_score,
                scores: entries,
            })
        }
        PD::IntegrationBudget {
            target_id,
            filter,
            completed_secs,
            budget_secs,
            fraction,
            budget_met,
        } => Some(SequencerEvent::IntegrationBudget {
            target_id: target_id.clone(),
            filter: filter.clone(),
            completed_secs: *completed_secs,
            budget_secs: *budget_secs,
            fraction: *fraction,
            budget_met: *budget_met,
        }),
        // sky-brightness adaptive exposure.
        PD::ExposureAdjusted {
            adapted_secs,
            nominal_secs,
            sky_brightness_mag,
            filter,
            reason,
        } => Some(SequencerEvent::ExposureAdjusted {
            node_id: node_id.to_string(),
            adapted_secs: *adapted_secs,
            nominal_secs: *nominal_secs,
            sky_brightness_mag: *sky_brightness_mag,
            filter: filter.clone(),
            reason: reason.clone(),
        }),
        // plugin-node progress payload. FRB doesn't
        // bridge `serde_json::Value`, so we stringify the detail for
        // the wire. Dart parses with `jsonDecode`.
        PD::PluginNode {
            plugin_id,
            node_type_id,
            detail,
        } => {
            // `to_string` cannot fail for a valid Value; the
            // `unwrap_or` is purely defensive against future
            // serde_json changes.
            let detail_json = serde_json::to_string(detail).unwrap_or_else(|_| "null".to_string());
            Some(SequencerEvent::PluginNodeProgress {
                node_id: node_id.to_string(),
                plugin_id: plugin_id.clone(),
                node_type_id: node_type_id.clone(),
                detail_json,
            })
        }
        // Science / photometry payloads. Mirror the corresponding
        // `ProgressDetail` field shapes verbatim so the Dart light-curve panel
        // binds to explicit fields instead of re-parsing the legacy string
        // `detail`. Emitted alongside `InstructionProgress` (additional, not a
        // replacement), like the typed progress payloads above.
        PD::PhotometryFrame {
            target_designation,
            reference_stars,
            frame,
            total,
            filter,
            exposure_secs,
            airmass,
            fwhm_arcsec,
            snr,
            mjd_obs,
            frame_start_unix,
            accepted,
            reject_reason,
            reduce_live,
            apply_differential,
        } => Some(SequencerEvent::PhotometryFrame {
            node_id: node_id.to_string(),
            target_designation: target_designation.clone(),
            reference_stars: reference_stars.clone(),
            frame: *frame,
            total: *total,
            filter: filter.clone(),
            exposure_secs: *exposure_secs,
            airmass: *airmass,
            fwhm_arcsec: *fwhm_arcsec,
            snr: *snr,
            mjd_obs: *mjd_obs,
            frame_start_unix: *frame_start_unix,
            accepted: *accepted,
            reject_reason: reject_reason.clone(),
            reduce_live: *reduce_live,
            apply_differential: *apply_differential,
        }),
        PD::PhotometryCadenceBroken {
            frame,
            total,
            gap_secs,
            max_gap_secs,
            cadence_breaks,
        } => Some(SequencerEvent::PhotometryCadenceBroken {
            node_id: node_id.to_string(),
            frame: *frame,
            total: *total,
            gap_secs: *gap_secs,
            max_gap_secs: *max_gap_secs,
            cadence_breaks: *cadence_breaks,
        }),
        PD::PhotometrySummary {
            target_designation,
            filter,
            frames_captured,
            cadence_breaks,
            last_reject_reason,
        } => Some(SequencerEvent::PhotometrySummary {
            node_id: node_id.to_string(),
            target_designation: target_designation.clone(),
            filter: filter.clone(),
            frames_captured: *frames_captured,
            cadence_breaks: *cadence_breaks,
            last_reject_reason: last_reject_reason.clone(),
        }),
        // Every other variant (Exposure, Filter, Slew, Center, Autofocus,
        // …) is well-served by the legacy `InstructionProgress` string
        // channel — adding typed variants for them is future work, not
        // 's scope.
        _ => None,
    }
}

#[flutter_rust_bridge::frb(ignore)]
pub(crate) fn structured_progress_payload_from_progress_detail(
    detail: &skotiq_sequencer::ProgressDetail,
) -> Option<(String, String)> {
    let value = serde_json::to_value(detail).ok()?;
    match value {
        serde_json::Value::Object(tagged) if tagged.len() == 1 => {
            let (kind, payload) = tagged.into_iter().next()?;
            Some((kind, payload.to_string()))
        }
        other => Some(("Unknown".to_string(), other.to_string())),
    }
}

// typed recovery event builders
//
// These helpers flatten the chrono-bearing `RecoveryContext` Rust struct into
// the FRB-friendly primitive payload exposed via `SequencerEvent::Recovery{
// Started, Progress, Completed, GaveUp}`. Centralised here so any future
// recovery-event channel uses the same wire shape.

/// Split a `RecoveryCause` into the `cause_kind` discriminant string + the
/// optional custom payload. The discriminant matches the Rust enum variant
/// name verbatim so the Dart side's `RecoveryCause.fromJson` factory maps
/// without a translation table.
#[flutter_rust_bridge::frb(ignore)]
pub(crate) fn recovery_cause_fields(
    cause: &skotiq_sequencer::recovery::RecoveryCause,
) -> (String, Option<String>) {
    use skotiq_sequencer::recovery::RecoveryCause as RC;
    match cause {
        RC::GuideStarLost => ("GuideStarLost".to_string(), None),
        RC::SlewFailed => ("SlewFailed".to_string(), None),
        RC::PlateSolveFailed => ("PlateSolveFailed".to_string(), None),
        RC::WeatherUnsafe => ("WeatherUnsafe".to_string(), None),
        RC::MountTrackingLost => ("MountTrackingLost".to_string(), None),
        RC::FocusDriftCritical => ("FocusDriftCritical".to_string(), None),
        RC::ConsecutiveRejectsExceeded => ("ConsecutiveRejectsExceeded".to_string(), None),
        RC::DeviceDisconnected => ("DeviceDisconnected".to_string(), None),
        RC::Custom(label) => ("Custom".to_string(), Some(label.clone())),
    }
}

/// Phase enum → stable Debug-format string. Matches the JSON wire shape
/// `serde` produces for the Rust `RecoveryPhase` unit-variant enum so the
/// Dart `_phaseFromWire` parser keeps working.
#[flutter_rust_bridge::frb(ignore)]
pub(crate) fn recovery_phase_str(phase: skotiq_sequencer::recovery::RecoveryPhase) -> String {
    use skotiq_sequencer::recovery::RecoveryPhase as RP;
    match phase {
        RP::Waiting => "Waiting",
        RP::Attempting => "Attempting",
        RP::Recovered => "Recovered",
        RP::GaveUp => "GaveUp",
    }
    .to_string()
}

#[flutter_rust_bridge::frb(ignore)]
pub(crate) fn recovery_event_started(
    ctx: &skotiq_sequencer::recovery::RecoveryContext,
) -> SequencerEvent {
    let (cause_kind, cause_custom_label) = recovery_cause_fields(&ctx.cause);
    SequencerEvent::RecoveryStarted {
        started_at_iso: ctx.started_at.to_rfc3339(),
        cause_kind,
        cause_custom_label,
        last_attempt_at_iso: ctx.last_attempt_at.map(|t| t.to_rfc3339()),
        attempt_count: ctx.attempt_count,
        max_attempts: ctx.max_attempts,
        retry_interval_secs: ctx.retry_interval_secs,
        max_duration_secs: ctx.max_duration_secs,
        phase: recovery_phase_str(ctx.phase),
        last_error: ctx.last_error.clone(),
    }
}

#[flutter_rust_bridge::frb(ignore)]
pub(crate) fn recovery_event_progress(
    ctx: &skotiq_sequencer::recovery::RecoveryContext,
) -> SequencerEvent {
    let (cause_kind, cause_custom_label) = recovery_cause_fields(&ctx.cause);
    SequencerEvent::RecoveryProgress {
        started_at_iso: ctx.started_at.to_rfc3339(),
        cause_kind,
        cause_custom_label,
        last_attempt_at_iso: ctx.last_attempt_at.map(|t| t.to_rfc3339()),
        attempt_count: ctx.attempt_count,
        max_attempts: ctx.max_attempts,
        retry_interval_secs: ctx.retry_interval_secs,
        max_duration_secs: ctx.max_duration_secs,
        phase: recovery_phase_str(ctx.phase),
        last_error: ctx.last_error.clone(),
    }
}

#[flutter_rust_bridge::frb(ignore)]
pub(crate) fn recovery_event_completed(
    ctx: &skotiq_sequencer::recovery::RecoveryContext,
) -> SequencerEvent {
    let (cause_kind, cause_custom_label) = recovery_cause_fields(&ctx.cause);
    SequencerEvent::RecoveryCompleted {
        started_at_iso: ctx.started_at.to_rfc3339(),
        cause_kind,
        cause_custom_label,
        last_attempt_at_iso: ctx.last_attempt_at.map(|t| t.to_rfc3339()),
        attempt_count: ctx.attempt_count,
        max_attempts: ctx.max_attempts,
        retry_interval_secs: ctx.retry_interval_secs,
        max_duration_secs: ctx.max_duration_secs,
        phase: recovery_phase_str(ctx.phase),
        last_error: ctx.last_error.clone(),
    }
}

#[flutter_rust_bridge::frb(ignore)]
pub(crate) fn recovery_event_gave_up(
    ctx: &skotiq_sequencer::recovery::RecoveryContext,
    aborted_by_user: bool,
) -> SequencerEvent {
    let (cause_kind, cause_custom_label) = recovery_cause_fields(&ctx.cause);
    SequencerEvent::RecoveryGaveUp {
        started_at_iso: ctx.started_at.to_rfc3339(),
        cause_kind,
        cause_custom_label,
        last_attempt_at_iso: ctx.last_attempt_at.map(|t| t.to_rfc3339()),
        attempt_count: ctx.attempt_count,
        max_attempts: ctx.max_attempts,
        retry_interval_secs: ctx.retry_interval_secs,
        max_duration_secs: ctx.max_duration_secs,
        phase: recovery_phase_str(ctx.phase),
        last_error: ctx.last_error.clone(),
        aborted_by_user,
    }
}
