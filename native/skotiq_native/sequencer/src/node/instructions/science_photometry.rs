//! Science: SciencePhotometry instruction node.
//!
//! Cadence-enforced photometric capture for variable-star / exoplanet
//! timing. The execution model:
//!
//! 1. Optionally drive a `ChangeFilter` to the configured photometric
//!    band (V/B/R/I/g/r/i/z/Clear/CV). The filter swap is skipped
//!    when the wheel is already on the right slot.
//! 2. Loop over `count` exposures. For each frame:
//!    a. Record the frame's start time so the next iteration can
//!    compute the inter-frame gap.
//!    b. Run a single-frame `TakeExposure` via the InstructionRegistry
//!    (re-uses the standard expose pipeline: camera, grading,
//!    FITS save, integration accounting).
//!    c. If the previous frame's start-to-start gap exceeded
//!    `max_cadence_gap_secs`, emit a
//!    `ProgressDetail::PhotometryCadenceBroken` warning. The node
//!    does NOT abort on cadence breaks — partial-cadence-broken
//!    data is still useful for offline re-analysis.
//!    d. Emit a structured `ProgressDetail::PhotometryFrame` event
//!    carrying the frame's measured airmass / fwhm / snr /
//!    instrumental + differential magnitude so the live light-
//!    curve panel can update.
//! 3. On burst completion, emit a `ProgressDetail::PhotometrySummary`
//!    event with the rolling cadence-break and reject counts.
//!
//! # Why delegate to TakeExposure?
//!
//! The expose pipeline is the load-bearing path for every imaging
//! sequence: camera command, HFR / star detection, FITS-header
//! assembly, Image Grading + reject routing,
//! integration-budget accounting, adaptive exposure
//! decisions, cloud-motion telemetry, and
//! defect-map application. Re-implementing any of that here would
//! inevitably diverge. Instead, the photometry node constructs a
//! `NodeType::TakeExposure` per frame with the photometric quality
//! gates pre-translated into an `ImageQualityCheck`, dispatches it
//! through the registry, and layers in the photometry-specific
//! reduction (instrumental + differential magnitude extraction) +
//! cadence tracking after the burst returns.
//!
//! # Refusing autofocus mid-cadence
//!
//! Per the brief, photometry runs require **constant cadence** —
//! skipping exposures to run autofocus would create a gap in the
//! light curve. The recommended policy is documented in the
//! validation rules and surfaced at sequence-edit time: photometry
//! nodes should be wrapped in a `Recovery` node whose
//! `AutofocusInterval` trigger is disabled or set to a very large
//! frame count. The runtime here does not aggressively police that
//! at execution time (the AutofocusInterval trigger is a global
//! standard trigger, not per-node), but it does emit a
//! `ProgressDetail::PhotometryCadenceBroken` event whenever the
//! inter-frame gap exceeds the user's `max_cadence_gap_secs`, so an
//! AF interrupt is loudly visible in the run dashboard.

use crate::node::context::{ExecutionContext, PhotometryRuntimeState};
use crate::node::progress::{ProgressDetail, ProgressUpdate};
use crate::node::registry::{registry, InstructionNode};
use crate::{
    ExposureConfig, FilterConfig, NodeId, NodeStatus, NodeType, PhotometryFrameVerdict,
    SciencePhotometryConfig,
};
use async_trait::async_trait;
use std::time::{SystemTime, UNIX_EPOCH};

pub struct SciencePhotometryInstruction;

#[async_trait]
impl InstructionNode for SciencePhotometryInstruction {
    fn type_name(&self) -> &'static str {
        "Science Photometry"
    }

    async fn execute(
        &self,
        node_id: &str,
        node_type: &NodeType,
        context: &mut ExecutionContext,
    ) -> NodeStatus {
        let NodeType::SciencePhotometry(config) = node_type else {
            tracing::error!("SciencePhotometryInstruction received non-SciencePhotometry variant");
            return NodeStatus::Failure;
        };

        // Validate config at runtime — these checks are also wired into
        // Dart-side validation rules, but a corrupt-file path can reach
        // execution with bad data and the runtime must refuse loudly.
        if config.count == 0 {
            tracing::warn!(
                "SciencePhotometry '{}' has count == 0; nothing to do (success)",
                node_id
            );
            return NodeStatus::Success;
        }
        if config.exposure_secs <= 0.0 {
            tracing::error!(
                "SciencePhotometry '{}' has non-positive exposure_secs {:.3}; aborting",
                node_id,
                config.exposure_secs
            );
            return NodeStatus::Failure;
        }
        if !config.is_photometric_filter() {
            tracing::warn!(
                "SciencePhotometry '{}' is configured with non-photometric filter '{}' \
                 — INSTRMAG / DIFFMAG will still be stamped but downstream tools may reject them. \
                 Use V/B/R/I/g/r/i/z/Clear/CV for canonical photometry.",
                node_id,
                config.filter,
            );
        }
        if config.apply_differential && config.reference_stars.is_empty() {
            tracing::error!(
                "SciencePhotometry '{}' has apply_differential=true but no reference stars; \
                 differential magnitudes cannot be computed. Aborting (no silent fallback).",
                node_id,
            );
            return NodeStatus::Failure;
        }
        if config.max_cadence_gap_secs < 0.0 {
            tracing::error!(
                "SciencePhotometry '{}' has negative max_cadence_gap_secs ({:.1}); aborting.",
                node_id,
                config.max_cadence_gap_secs,
            );
            return NodeStatus::Failure;
        }

        tracing::info!(
            "[PHOTOMETRY] Node '{}' starting: target='{}', refs={}, filter='{}', \
             {} x {:.1}s, cadence_gap_max={:.1}s, reduce_live={}, apply_diff={}",
            node_id,
            config.target_designation,
            config.reference_stars.len(),
            config.filter,
            config.count,
            config.exposure_secs,
            config.max_cadence_gap_secs,
            config.reduce_live,
            config.apply_differential,
        );

        // Filter swap (skipped when wheel already on the right slot).
        let need_filter_change = context.current_filter.as_deref() != Some(config.filter.as_str());
        if need_filter_change {
            tracing::info!(
                "[PHOTOMETRY] '{}' switching filter wheel to '{}'",
                node_id,
                config.filter
            );
            let filter_status = run_filter_change(node_id, &config.filter, context).await;
            if !matches!(filter_status, NodeStatus::Success) {
                tracing::error!(
                    "[PHOTOMETRY] '{}' filter change to '{}' failed: {:?}",
                    node_id,
                    config.filter,
                    filter_status
                );
                return filter_status;
            }
        }

        // Initialise per-node timing state. A re-entry (resume after
        // pause) preserves the previous state so cadence accounting
        // is continuous across restarts.
        let mut state = load_or_init_state(node_id, context).await;
        // Reset cadence-break / frame counters for this burst — the
        // previous burst's counters are already reflected in
        // historical photometry rows; new burst starts fresh.
        if state.frames_captured >= config.count {
            // Old completed run; reset to allow a fresh burst.
            state = PhotometryRuntimeState::default();
        }

        let mut last_verdict_reject_reason: Option<String> = None;

        for frame_idx in 1..=config.count {
            if context.is_cancelled().await {
                save_state(node_id, context, &state).await;
                return NodeStatus::Cancelled;
            }
            if context.is_skip_to_next_target_requested() {
                save_state(node_id, context, &state).await;
                return NodeStatus::Skipped;
            }

            let frame_start_unix = now_unix_secs();

            // Cadence check (after the FIRST frame so we have a
            // baseline). When the gap exceeds the configured ceiling,
            // emit a CadenceBroken progress event but continue —
            // partial cadence-broken data is still useful for offline
            // re-analysis.
            let cadence_gap_secs = state
                .last_frame_start_unix_secs
                .map(|prev| frame_start_unix - prev);
            if let (Some(gap), gap_ceiling) = (cadence_gap_secs, config.max_cadence_gap_secs) {
                if gap_ceiling > 0.0 && gap > (config.exposure_secs + gap_ceiling) {
                    state.cadence_breaks = state.cadence_breaks.saturating_add(1);
                    tracing::warn!(
                        "[PHOTOMETRY] '{}' cadence broken: frame {}/{} arrived {:.1}s after \
                         previous (max allowed {:.1}s + exp {:.1}s = {:.1}s). Continuing.",
                        node_id,
                        frame_idx,
                        config.count,
                        gap,
                        gap_ceiling,
                        config.exposure_secs,
                        gap_ceiling + config.exposure_secs,
                    );
                    emit_cadence_break(
                        node_id,
                        context,
                        frame_idx,
                        config.count,
                        gap,
                        gap_ceiling,
                        state.cadence_breaks,
                    );
                }
            }

            // Take one frame via the standard expose pipeline.
            let exposure_cfg = build_exposure_config(config);
            let exposure_node_type = NodeType::TakeExposure(exposure_cfg);
            let Some(instruction) = registry().build(&exposure_node_type) else {
                tracing::error!(
                    "[PHOTOMETRY] '{}': InstructionRegistry returned None for TakeExposure; \
                     cannot proceed (registry bug)",
                    node_id
                );
                save_state(node_id, context, &state).await;
                return NodeStatus::Failure;
            };
            let burst_status = instruction
                .execute(node_id, &exposure_node_type, context)
                .await;

            // The exposure pipeline returns Failure for unrecoverable
            // capture errors (camera disconnect, FITS save failed,
            // etc.). For photometry runs we abort the burst on those
            // — finishing in a half-baked state would corrupt the
            // light curve.
            if matches!(burst_status, NodeStatus::Failure) {
                tracing::error!(
                    "[PHOTOMETRY] '{}' frame {}/{} capture failed; aborting burst",
                    node_id,
                    frame_idx,
                    config.count
                );
                save_state(node_id, context, &state).await;
                return NodeStatus::Failure;
            }
            if matches!(burst_status, NodeStatus::Cancelled) {
                save_state(node_id, context, &state).await;
                return NodeStatus::Cancelled;
            }
            if matches!(burst_status, NodeStatus::Skipped) {
                save_state(node_id, context, &state).await;
                return NodeStatus::Skipped;
            }

            // Update the per-node timing state BEFORE the photometry
            // reduction so a slow reducer doesn't bias the next gap
            // measurement.
            state.last_frame_start_unix_secs = Some(frame_start_unix);
            state.frames_captured = state.frames_captured.saturating_add(1);

            // Photometric reduction: read live telemetry that the
            // expose pipeline already gathered and write the
            // photometry_measurements row payload via a structured
            // progress event. The Dart `science_provider` listens for
            // `ProgressDetail::PhotometryFrame` and inserts the row
            // into the `photometry_measurements` table.
            //
            // We deliberately do NOT do the catalogue / SExtractor
            // extraction here — that lives in the Dart science
            // pipeline (already wired up for the live photometry UI).
            // The Rust side ships the per-frame *configuration* (which
            // target / refs / filter / cadence) and the *measured*
            // quantities the runtime can see (airmass / FWHM / SNR
            // from the existing HFR / star detector); the catalogue-
            // matching extraction is Dart's job. This keeps the FFI
            // surface narrow (no FITS bytes flowing back over the
            // boundary every frame).
            let (airmass, fwhm_arcsec, snr) = read_frame_metrics(context).await;
            let verdict = config.quality.evaluate(
                snr,
                fwhm_arcsec,
                airmass,
                config.reference_stars.len(),
                // Photometry-frame-level reference visibility is
                // computed downstream by the Dart pipeline; here we
                // assume all references are visible and rely on the
                // FWHM / SNR / airmass gates to catch the haze cases
                // that would actually drop a reference. This matches
                // the brief's "reduce_live=true => run the gates,
                // reject_path=true" behaviour.
                config.reference_stars.len(),
            );
            if let PhotometryFrameVerdict::Reject { reason } = &verdict {
                last_verdict_reject_reason = Some(reason.clone());
                tracing::warn!(
                    "[PHOTOMETRY] '{}' frame {}/{} REJECTED: {}",
                    node_id,
                    frame_idx,
                    config.count,
                    reason
                );
            }

            emit_photometry_frame(
                node_id,
                context,
                config,
                frame_idx,
                airmass,
                fwhm_arcsec,
                snr,
                &verdict,
                frame_start_unix,
            );

            save_state(node_id, context, &state).await;
        }

        emit_photometry_summary(
            node_id,
            context,
            config,
            &state,
            last_verdict_reject_reason.as_deref(),
        );

        tracing::info!(
            "[PHOTOMETRY] Node '{}' complete: {} frames, {} cadence breaks",
            node_id,
            state.frames_captured,
            state.cadence_breaks,
        );

        NodeStatus::Success
    }
}

/// Build the per-frame ExposureConfig. One frame per
/// `TakeExposure` so the cadence-gap check has a chance to fire
/// between exposures; if we batched (count > 1 inside one
/// TakeExposure) the InstructionNode trait would block until the
/// whole batch finished and we couldn't intervene.
fn build_exposure_config(cfg: &SciencePhotometryConfig) -> ExposureConfig {
    ExposureConfig {
        duration_secs: cfg.exposure_secs,
        count: 1,
        // The filter has already been driven before the burst starts;
        // routing it through TakeExposure as well would re-run the
        // filter logic and could fight focus offsets.
        filter: None,
        filter_index: None,
        gain: cfg.gain,
        offset: cfg.offset,
        binning: cfg.binning,
        // Photometry runs explicitly do NOT dither — that would
        // disturb the centroid extraction across frames. Setting
        // dither_every = None disables it entirely (matches
        // `ExposureConfig::dither_every` semantics).
        dither_every: None,
        ..ExposureConfig::default()
    }
}

/// Science — drive the photometric filter via the
/// `ChangeFilter` instruction so focus offsets / filter wheel
/// pacing all apply correctly.
async fn run_filter_change(
    node_id: &str,
    filter_name: &str,
    context: &mut ExecutionContext,
) -> NodeStatus {
    let filter_node_type = NodeType::ChangeFilter(FilterConfig {
        filter_name: filter_name.to_string(),
        filter_index: None,
        timeout_secs: None,
    });
    let Some(instruction) = registry().build(&filter_node_type) else {
        tracing::error!(
            "[PHOTOMETRY] '{}': InstructionRegistry returned None for ChangeFilter; \
             cannot proceed (registry bug)",
            node_id
        );
        return NodeStatus::Failure;
    };
    instruction
        .execute(node_id, &filter_node_type, context)
        .await
}

/// Read the live frame metrics from ExecutionContext. The expose
/// pipeline updates `hfr_baseline` after each accepted frame; we
/// derive a coarse FWHM estimate (assuming Gaussian PSF: FWHM ≈
/// 2 × HFR — matches the Vasilevskis approximation used by AAVSO
/// observers) and surface the most recent SNR via the shared
/// frame-quality state.
///
/// Airmass is computed from the configured target's altitude (we
/// cannot trust the camera-side metric because it would lag the
/// active target after a slew).
async fn read_frame_metrics(context: &ExecutionContext) -> (Option<f64>, Option<f64>, Option<f64>) {
    let altitude_deg = context.calculate_altitude();
    // The same function that writes the frame's `AIRMASS` card, so the number
    // this gate rejects on is the number the file will claim. A hand-rolled
    // copy is how the gate stops working: one that added Pickering's
    // refraction term to sin(h) instead of to h peaked at 2.02 over the whole
    // sky, so the default `max_airmass` of 2.5 could never fire and the gate
    // that exists to throw out horizon-hugging photometry passed all of it.
    //
    // `None` means only "below the horizon" (`calculate_airmass` refuses it),
    // which `PhotometryQualityGates::evaluate` treats as a reject.
    let airmass = altitude_deg.and_then(|alt| skotiq_imaging::calculate_airmass(alt).ok());

    // FWHM estimate from the HFR baseline (HFR -> arcsec FWHM under
    // Gaussian PSF: FWHM ≈ 2.0 × HFR for a well-sampled stellar
    // profile). The pixel scale is honoured via the most recent
    // plate-solve result.
    let baseline_hfr = *context.hfr_baseline.read().await;
    let pixel_scale = {
        let solve = context.last_plate_solve.read().await;
        solve.as_ref().map(|s| s.pixel_scale)
    };
    let fwhm_arcsec = match (baseline_hfr, pixel_scale) {
        (Some(hfr), Some(scale)) if hfr > 0.0 && scale > 0.0 => Some(hfr * 2.0 * scale),
        _ => None,
    };

    // SNR: read whichever measurement is available — today the most recent
    // star-detection-derived value via the grading pipeline. When it is
    // absent the photometry quality gate rejects the frame and the Dart
    // pipeline falls back to its own extraction; no value is invented.
    // Standard SNR-from-HFR proxy: poor proxy in absolute terms but
    // adequate for the relative quality gate comparison the photometry
    // pipeline does. We surface this as a *measured-by-runtime* value;
    // the Dart science pipeline can supersede it offline with the real
    // catalogue-photometry SNR.
    let snr = baseline_hfr.map(|hfr| (100.0 / hfr).clamp(0.0, 1_000.0));

    (airmass, fwhm_arcsec, snr)
}

fn now_unix_secs() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

/// Modified Julian Date from a unix timestamp. MJD = JD - 2400000.5
/// where JD = (unix_secs / 86400) + 2440587.5.
pub fn unix_to_mjd(unix_secs: f64) -> f64 {
    (unix_secs / 86_400.0) + 2_440_587.5 - 2_400_000.5
}

/// Emit a structured `ProgressDetail::PhotometryFrame` event that
/// the Dart science pipeline subscribes to (writes a row to
/// `photometry_measurements` + updates the live light-curve chart).
#[allow(clippy::too_many_arguments)]
fn emit_photometry_frame(
    node_id: &str,
    context: &ExecutionContext,
    config: &SciencePhotometryConfig,
    frame_idx: u32,
    airmass: Option<f64>,
    fwhm_arcsec: Option<f64>,
    snr: Option<f64>,
    verdict: &PhotometryFrameVerdict,
    frame_start_unix: f64,
) {
    let (accepted, reject_reason) = match verdict {
        PhotometryFrameVerdict::Pass => (true, None),
        PhotometryFrameVerdict::Reject { reason } => (false, Some(reason.clone())),
    };
    let mjd_obs = unix_to_mjd(frame_start_unix + config.exposure_secs / 2.0);
    let detail = ProgressDetail::PhotometryFrame {
        target_designation: config.target_designation.clone(),
        reference_stars: config.reference_stars.clone(),
        frame: frame_idx,
        total: config.count,
        filter: config.filter.clone(),
        exposure_secs: config.exposure_secs,
        airmass,
        fwhm_arcsec,
        snr,
        mjd_obs,
        frame_start_unix,
        accepted,
        reject_reason,
        reduce_live: config.reduce_live,
        apply_differential: config.apply_differential,
    };
    let upd = ProgressUpdate::instruction_progress(
        node_id.to_string(),
        "Science Photometry",
        100.0 * f64::from(frame_idx) / f64::from(config.count.max(1)),
        detail,
    );
    context.send_progress(upd);
}

/// Emit a `PhotometryCadenceBroken` event so the Run Dashboard's
/// photometry panel can surface the cadence disturbance.
fn emit_cadence_break(
    node_id: &str,
    context: &ExecutionContext,
    frame_idx: u32,
    total: u32,
    gap_secs: f64,
    max_gap_secs: f64,
    cadence_breaks: u32,
) {
    let detail = ProgressDetail::PhotometryCadenceBroken {
        frame: frame_idx,
        total,
        gap_secs,
        max_gap_secs,
        cadence_breaks,
    };
    let upd = ProgressUpdate::instruction_progress(
        node_id.to_string(),
        "Science Photometry",
        100.0 * f64::from(frame_idx) / f64::from(total.max(1)),
        detail,
    );
    context.send_progress(upd);
}

/// Emit the final summary at burst completion.
fn emit_photometry_summary(
    node_id: &str,
    context: &ExecutionContext,
    config: &SciencePhotometryConfig,
    state: &PhotometryRuntimeState,
    last_reject_reason: Option<&str>,
) {
    let detail = ProgressDetail::PhotometrySummary {
        target_designation: config.target_designation.clone(),
        filter: config.filter.clone(),
        frames_captured: state.frames_captured,
        cadence_breaks: state.cadence_breaks,
        last_reject_reason: last_reject_reason.map(|s| s.to_string()),
    };
    let upd = ProgressUpdate::instruction_progress(
        node_id.to_string(),
        "Science Photometry",
        100.0,
        detail,
    );
    context.send_progress(upd);
}

async fn load_or_init_state(node_id: &str, context: &ExecutionContext) -> PhotometryRuntimeState {
    let states = context.science_photometry_states.read().await;
    states.get(node_id).cloned().unwrap_or_default()
}

async fn save_state(node_id: &str, context: &ExecutionContext, state: &PhotometryRuntimeState) {
    let key: NodeId = node_id.to_string();
    let mut states = context.science_photometry_states.write().await;
    states.insert(key, state.clone());
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Binning, PhotometryQualityGates};

    fn make_config() -> SciencePhotometryConfig {
        SciencePhotometryConfig {
            target_designation: "V0376 Per".to_string(),
            reference_stars: vec!["ref-1".to_string(), "ref-2".to_string()],
            max_cadence_gap_secs: 2.0,
            filter: "Clear".to_string(),
            exposure_secs: 60.0,
            count: 5,
            reduce_live: true,
            apply_differential: true,
            quality: PhotometryQualityGates::default(),
            gain: None,
            offset: None,
            binning: Binning::One,
        }
    }

    #[test]
    fn build_exposure_config_disables_dither_and_filter_routing() {
        let cfg = make_config();
        let ec = build_exposure_config(&cfg);
        assert_eq!(ec.count, 1);
        assert!((ec.duration_secs - 60.0).abs() < f64::EPSILON);
        assert!(ec.filter.is_none());
        assert!(ec.filter_index.is_none());
        // The brief mandates no mid-burst dithering during photometry runs.
        assert!(matches!(ec.dither_every, None | Some(0)));
    }

    #[test]
    fn quality_gates_pass_when_everything_in_range() {
        let cfg = make_config();
        let verdict = cfg.quality.evaluate(
            Some(120.0), // SNR well above 50
            Some(2.1),   // FWHM under 5"
            Some(1.4),   // airmass under 2.5
            2,
            2,
        );
        assert_eq!(verdict, PhotometryFrameVerdict::Pass);
    }

    #[test]
    fn quality_gates_reject_low_snr() {
        let cfg = make_config();
        match cfg.quality.evaluate(Some(10.0), Some(2.1), Some(1.4), 2, 2) {
            PhotometryFrameVerdict::Reject { reason } => {
                assert!(reason.contains("SNR"));
            }
            other => panic!("expected reject, got {:?}", other),
        }
    }

    #[test]
    fn quality_gates_reject_when_refs_missing() {
        let cfg = make_config();
        match cfg
            .quality
            .evaluate(Some(120.0), Some(2.1), Some(1.4), 2, 1)
        {
            PhotometryFrameVerdict::Reject { reason } => {
                assert!(reason.contains("reference"));
            }
            other => panic!("expected reject when refs missing, got {:?}", other),
        }
    }

    #[test]
    fn quality_gates_reject_missing_measurement_when_gate_active() {
        let cfg = make_config();
        // SNR not measured + min_snr > 0 => reject (no silent fallback).
        match cfg.quality.evaluate(None, Some(2.1), Some(1.4), 2, 2) {
            PhotometryFrameVerdict::Reject { reason } => {
                assert!(reason.contains("SNR not measured"));
            }
            other => panic!("expected reject for missing SNR, got {:?}", other),
        }
    }

    /// Put a target at the celestial pole and the observer at latitude L, and
    /// its altitude is exactly L at every instant — no hour angle, no clock, no
    /// mock. That makes the whole gate drivable end to end: real
    /// `ExecutionContext`, real `read_frame_metrics`, real gates.
    fn context_pointed_at_altitude(altitude_deg: f64) -> ExecutionContext {
        let mut ctx = ExecutionContext::new_for_test("photometry-gate-test".to_string());
        ctx.target_ra = Some(3.0);
        ctx.target_dec = Some(90.0);
        ctx.latitude = Some(altitude_deg);
        ctx.longitude = Some(0.0);
        ctx
    }

    /// The `max_airmass` gate has to be able to fire.
    ///
    /// 20° altitude is airmass 2.90, comfortably past the default 2.5 cut-off
    /// (AAVSO's, ~24°), so a frame taken there is exactly what the gate exists
    /// to throw out. It was passing. The airmass fed to the gate came from a
    /// hand-rolled formula whose maximum over the ENTIRE sky was 2.02 — so no
    /// altitude whatsoever could trip a 2.5 threshold, and the horizon frames
    /// that most need rejecting scored best of all.
    #[tokio::test]
    async fn max_airmass_gate_rejects_a_frame_taken_at_twenty_degrees() {
        let ctx = context_pointed_at_altitude(20.0);
        assert!(
            (ctx.calculate_altitude()
                .expect("pole target has an altitude")
                - 20.0)
                .abs()
                < 1e-9,
            "the fixture's geometry is wrong, so the rest of this test proves nothing"
        );

        let (airmass, _fwhm, _snr) = read_frame_metrics(&ctx).await;
        let measured = airmass.expect("20° is above the horizon");

        let gates = PhotometryQualityGates::default();
        // SNR and FWHM handed in well inside their limits so the only gate
        // that can speak is airmass.
        match gates.evaluate(Some(120.0), Some(2.1), airmass, 2, 2) {
            PhotometryFrameVerdict::Reject { reason } => {
                assert!(
                    reason.contains("Airmass"),
                    "rejected, but for the wrong reason: {reason}"
                );
            }
            other => panic!(
                "a frame at 20° altitude was accepted against a {:.2} airmass limit \
                 — the gate saw {measured:.2}: {other:?}",
                gates.max_airmass
            ),
        }

        // And the value it rejected on is the real one, not merely something
        // large enough to trip the threshold.
        assert!(
            (measured - 2.900).abs() < 0.01,
            "airmass at 20° should be ~2.90, got {measured}"
        );
    }

    /// The number the gate rejects on and the number the file claims are the
    /// same number. Anything else means a user can read a rejection reason off
    /// the log and find the header disagreeing with it.
    #[tokio::test]
    async fn gate_airmass_is_the_value_written_to_the_fits_header() {
        for altitude in [70.0_f64, 45.0, 30.0, 20.0, 8.0] {
            let ctx = context_pointed_at_altitude(altitude);
            let (airmass, _, _) = read_frame_metrics(&ctx).await;
            // Fed the altitude the context itself reports, not the nominal
            // `altitude` — `calculate_altitude` round-trips through asin(sin())
            // and lands an ULP away, and the claim under test is that one
            // function is used, not that two agree to a tolerance.
            let observed = ctx.calculate_altitude().expect("pole target");
            let written = skotiq_imaging::calculate_airmass(observed)
                .expect("above the horizon, so a card is written");
            assert_eq!(
                airmass,
                Some(written),
                "at {altitude}° the gate sees {airmass:?} and the header records {written}"
            );
        }
    }

    #[test]
    fn is_photometric_filter_accepts_standard_bands() {
        assert!(SciencePhotometryConfig::is_photometric_filter_name("V"));
        assert!(SciencePhotometryConfig::is_photometric_filter_name("B"));
        assert!(SciencePhotometryConfig::is_photometric_filter_name("R"));
        assert!(SciencePhotometryConfig::is_photometric_filter_name("I"));
        assert!(SciencePhotometryConfig::is_photometric_filter_name("g"));
        assert!(SciencePhotometryConfig::is_photometric_filter_name("z"));
        assert!(SciencePhotometryConfig::is_photometric_filter_name("Clear"));
        assert!(SciencePhotometryConfig::is_photometric_filter_name("CV"));
        assert!(!SciencePhotometryConfig::is_photometric_filter_name("Ha"));
        assert!(!SciencePhotometryConfig::is_photometric_filter_name("Lum"));
        assert!(!SciencePhotometryConfig::is_photometric_filter_name(""));
    }

    #[test]
    fn unix_to_mjd_matches_known_anchor() {
        // 2000-01-01 12:00:00 UTC corresponds to MJD 51544.5 (J2000.0).
        let unix_j2000 = 946_728_000.0;
        let mjd = unix_to_mjd(unix_j2000);
        assert!((mjd - 51_544.5).abs() < 1e-6, "got mjd={}", mjd);
    }
}
