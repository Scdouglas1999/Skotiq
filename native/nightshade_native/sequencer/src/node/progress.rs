//! Structured progress reporting for sequencer nodes.
//!
//! Hand-formatted strings like `"Filter: foo (50%)"`, parsed back into
//! `(instruction, percent, detail)` triples via `split_once` and
//! `rfind('(')`, are brittle (a parenthesis in a target name corrupts
//! parsing), lossy (no way to surface RA/Dec mid-slew or HFR mid-AF), and
//! tightly coupled to message shape.
//!
//! The contract here: every instruction populates a `ProgressUpdate` with a
//! typed `ProgressDetail`. The executor's progress callback consumes the
//! structured payload directly — no parsing. The legacy `message: String`
//! field is still populated (auto-derived from the detail via `legacy_message`)
//! so the bridge layer can emit the existing `SequencerEvent::InstructionProgress`
//! payload without an FRB schema change.

use crate::NodeId;
use crate::NodeStatus;
use serde::{Deserialize, Serialize};

/// Structured payload describing what an instruction is doing right now.
///
/// Each variant carries the field set most useful for the UI. The catch-all
/// `Generic(String)` exists so plugin/script nodes can still ship free-form
/// progress; everything else is strongly typed.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ProgressDetail {
    /// Free-form text. Used by simple no-op instructions (Park, Unpark,
    /// Notification) and as the fallback when richer typing is not warranted.
    Generic(String),
    /// Exposure burst progress. `frame` is 1-based.
    Exposure {
        frame: u32,
        total: u32,
        duration_secs: f64,
    },
    /// Filter wheel change.
    Filter { name: String, position: Option<i32> },
    /// Slew in progress. Coordinates are reported in the same units as the
    /// rest of the sequencer (RA in hours, Dec in degrees) so the UI can
    /// render them without unit conversion.
    Slew {
        target_ra_hours: Option<f64>,
        target_dec_degrees: Option<f64>,
    },
    /// Plate-solve + center attempt.
    Center {
        attempt: u32,
        max_attempts: u32,
        last_separation_arcsec: Option<f64>,
    },
    /// Autofocus run. `step` is 1-based and `total_steps` is the full sweep.
    Autofocus {
        step: u32,
        total_steps: u32,
        current_hfr: Option<f64>,
    },
    /// Camera cooling / warming.
    Thermal {
        current_temp_c: Option<f64>,
        target_temp_c: Option<f64>,
    },
    /// Rotator move.
    Rotator {
        current_angle_deg: Option<f64>,
        target_angle_deg: f64,
    },
    /// Wait / Delay countdown. `remaining_secs` is the time until completion.
    Wait { remaining_secs: f64 },
    /// Dither in progress.
    Dither {
        pixels: f64,
        settle_pixels: f64,
        ra_only: bool,
    },
    /// Guider start/stop.
    Guiding {
        rms_total: Option<f64>,
        is_settled: bool,
    },
    /// Mosaic panel progress. `panel_row` / `panel_col` are
    /// derived from the mosaic grid plan so the Run Dashboard can render
    /// "Panel 5/9 (row 2, col 2)" without crossreferencing the panel
    /// plan. `None` for legacy code paths that emit Mosaic progress
    /// without grid context — the dashboard hides the row/col annotation
    /// when both are absent.
    Mosaic {
        panel_index: u32,
        total_panels: u32,
        panel_row: Option<u32>,
        panel_col: Option<u32>,
    },
    /// Flat wizard ADU tuning.
    FlatWizard {
        current_adu: Option<u16>,
        target_adu: u16,
        current_exposure_secs: Option<f64>,
    },
    /// Polar alignment iteration.
    PolarAlignment { step: String },
    /// Meridian flip phase.
    MeridianFlip { phase: String },
    /// Cover/calibrator open/close/brightness step.
    CoverCalibrator { state: String },
    /// Temperature compensation step.
    TemperatureCompensation { delta_steps: i32 },
    /// Script / external process step.
    Script { phase: String },
    /// Dome shutter / dome park progress.
    Dome { phase: String },
    /// SmartExposure progress. Surfaced so the Run
    /// Dashboard can show "L: 1h12m / 3h goal"-style per-filter progress
    /// without the UI having to parse free-form text. `frame_in_plan` is
    /// 1-based and tracks the *completed* count for the current filter;
    /// `total_frames` is the configured count for the current plan.
    SmartExposure {
        current_filter: String,
        plan_index: usize,
        total_plans: usize,
        frame_in_plan: u32,
        total_frames: u32,
    },
    /// TargetScheduler decision payload. Carries the picked
    /// target id/name + the full score table so the Run Dashboard's Scheduler
    /// panel can render the ranking without re-running the math.
    ///
    /// `picked_target_id` / `picked_target_name` are `None` when no runnable
    /// target cleared `min_score_to_run` — the dashboard renders "no target
    /// picked; see score table for reasons".
    Scheduler {
        /// 1-based decision counter for this scheduler instance.
        decision_counter: u32,
        picked_target_id: Option<String>,
        picked_target_name: Option<String>,
        /// Picked target's total score (0..=100). `None` when nothing was
        /// picked.
        picked_score: Option<f64>,
        /// Sorted score table (runnable first, then by descending total).
        scores: Vec<crate::node::logic::target_scheduler::SchedulerScoreSummary>,
    },
    /// per-target integration budget progress.
    /// Emitted by the exposure instruction after every successful burst
    /// when the active target has an integration budget configured.
    ///
    /// `fraction` is `completed_secs / budget_secs` (or `completed_secs /
    /// total_budget_secs` when this filter has no per-filter cap). The
    /// dashboard renders it as a thin progress bar next to the
    /// per-filter row.
    IntegrationBudget {
        /// The TargetHeader node id this budget belongs to.
        target_id: String,
        /// Filter the credit was applied to (`""` for no-filter cameras).
        filter: String,
        /// Seconds of integration accumulated against this filter.
        completed_secs: f64,
        /// Resolved per-filter cap (seconds). `0.0` when this filter has
        /// no individual cap but the budget has a total — the UI falls
        /// back to the per-target total in that case.
        budget_secs: f64,
        /// `completed_secs / budget_secs` (or against the total when the
        /// per-filter cap is zero). Clamped to [0, 1.5] so renderers can
        /// honestly show overshoot without exploding.
        fraction: f64,
        /// True once the *whole target* budget is met. The dashboard
        /// uses this to surface a green check on the target tile.
        budget_met: bool,
    },
    /// Image Grading: exposure passed configured quality thresholds
    /// and was saved to the normal output folder. Surfaced so the run
    /// dashboard quality panel can update its accept/reject totals and
    /// recent-frames list without subscribing to a separate event.
    FrameAccepted {
        frame: u32,
        total: u32,
        hfr: Option<f64>,
        eccentricity: Option<f64>,
        star_count: Option<u32>,
        accepted_total: u32,
        rejected_total: u32,
        /// path the accepted frame was saved to on disk.
        /// `None` for back-compat with legacy emit sites that did not yet
        /// thread the save path through; new sites in `expose.rs` always
        /// populate this. The thumbnail strip uses it to render
        /// inline previews of accepted frames the same way it already
        /// does for `FrameRejected.reject_path`.
        #[serde(default)]
        save_path: Option<String>,
        /// The capture truth for this exact frame, projected out of the very
        /// `FrameContext` the FITS writer stamped the header from. This is
        /// what makes the `captured_images` row and the file on disk agree:
        /// before it, the row was assembled from a second, thinner source and
        /// landed with NULL gain / offset / temperature / pointing while the
        /// header written microseconds earlier had all of them.
        #[serde(default)]
        capture: crate::scheduling::FrameCaptureMetadata,
    },
    /// Image Grading: the exposure failed at least one quality threshold and was
    /// routed to the reject folder. The integration-budget tracker listens for
    /// this and skips counting the exposure time; the dashboard quality panel
    /// surfaces the reason text + metrics.
    ///
    /// The forensics fields carry a structured cause + evidence list classified
    /// by [`crate::quality::analyze_rejection`]. They are all `Option` so a
    /// classifier-disabled run (headless / standalone smoke tests) can still emit
    /// the event without a verdict. The Dart side persists `likely_cause` +
    /// `evidence` + the per-snapshot env values in the `frame_forensics` table.
    FrameRejected {
        frame: u32,
        total: u32,
        reason: String,
        hfr: Option<f64>,
        eccentricity: Option<f64>,
        star_count: Option<u32>,
        /// Path the rejected FITS landed at, so the UI can offer "preview"
        /// without re-fetching the in-memory image.
        reject_path: String,
        /// Running consecutive-rejects counter. When this reaches the
        /// configured `max_consecutive_rejects`, the operator is notified
        /// once for the streak (a Warning and a decision row); the run
        /// carries on.
        consecutive_rejects: u32,
        accepted_total: u32,
        rejected_total: u32,
        // forensics ----------------------------------------------
        /// Classified cause. `None` when classification was disabled or
        /// no inputs were available.
        #[serde(default)]
        likely_cause: Option<crate::quality::LikelyCause>,
        /// Human-readable evidence bullets the UI surfaces.
        #[serde(default)]
        evidence: Vec<String>,
        /// Sky brightness reading at capture time (mag/arcsec²). `None`
        /// when the sky-brightness tracker has not produced a sample.
        #[serde(default)]
        sky_brightness_at_capture: Option<f64>,
        /// Cloud cover percentage (0-100) at capture time.
        #[serde(default)]
        cloud_cover_at_capture: Option<f64>,
        /// Wind speed at capture time (km/h). `None` when no weather feed
        /// is providing wind data.
        #[serde(default)]
        wind_at_capture: Option<f64>,
        /// Guide RMS (arc-seconds) sampled at capture time.
        #[serde(default)]
        guide_rms_at_capture: Option<f64>,
        /// Sensor temperature (°C) at capture time.
        #[serde(default)]
        sensor_temp_at_capture: Option<f64>,
        /// The capture truth for this exact frame — see
        /// [`ProgressDetail::FrameAccepted::capture`]. A rejected frame is
        /// still written to disk and still gets a `captured_images` row, so it
        /// needs the same one-source stamping as an accepted one.
        #[serde(default)]
        capture: crate::scheduling::FrameCaptureMetadata,
    },
    /// sky-brightness adaptive exposure decision.
    /// Emitted by `expose.rs` immediately before a burst starts whenever
    /// the adaptive-exposure adapter has been consulted (regardless of
    /// whether the adapter actually changed the duration). Drives the
    /// dashboard's "Adapted exposure: 142s (nominal 60s)" surface.
    ExposureAdjusted {
        /// The exposure time we will actually use for this burst (seconds).
        adapted_secs: f64,
        /// The user-configured nominal duration for this burst (seconds).
        nominal_secs: f64,
        /// Live sky brightness (mag/arcsec²) used in the decision. `None`
        /// when the adapter fell back due to unavailable telemetry.
        sky_brightness_mag: Option<f64>,
        /// Filter the burst is being captured through; surfaces in the UI
        /// so the user can see e.g. "L adapted; RGB fixed".
        filter: Option<String>,
        /// Human-readable reason tag — one of `Adapted`, `ClampedMin`,
        /// `ClampedMax`, `Unavailable`, `Disabled`, `OutOfNominalBounds`.
        /// Mirrors `crate::scheduling::AdaptiveExposureReason::label`.
        reason: String,
    },
    /// live progress payload from a plugin-dispatched
    /// `NodeType::PluginNode`. `detail` is an opaque JSON value the
    /// plugin author chose — Rust forwards it verbatim. The bridge
    /// re-serialises it as a string so the FRB wire format stays
    /// primitive (FRB does not bridge `serde_json::Value`).
    ///
    /// Emitted from `plugin_node.rs`: one synthetic "started" tick while the node
    /// waits for the Dart-side reply, and one on the final reply when Dart
    /// attaches `structured_detail`.
    PluginNode {
        plugin_id: String,
        node_type_id: String,
        /// Arbitrary plugin-authored payload. Empty object for the
        /// synthetic "started" / "finished" ticks the executor emits;
        /// non-empty for plugin-pushed intermediate progress.
        #[serde(default)]
        detail: serde_json::Value,
    },
    /// Science — per-frame photometry payload from the
    /// `SciencePhotometryInstruction`. The Dart science pipeline
    /// subscribes to this event, writes a row to
    /// `photometry_measurements`, and updates the live light-curve
    /// chart on the Run Dashboard.
    PhotometryFrame {
        target_designation: String,
        reference_stars: Vec<String>,
        frame: u32,
        total: u32,
        filter: String,
        exposure_secs: f64,
        airmass: Option<f64>,
        fwhm_arcsec: Option<f64>,
        snr: Option<f64>,
        /// Modified Julian Date at exposure midpoint (FITS `MJD-OBS`).
        mjd_obs: f64,
        /// Unix epoch seconds at exposure start.
        frame_start_unix: f64,
        accepted: bool,
        reject_reason: Option<String>,
        reduce_live: bool,
        apply_differential: bool,
    },
    /// Science — cadence violation event emitted whenever the
    /// inter-frame start-to-start gap exceeds the configured ceiling.
    /// Surfaced by the dashboard photometry panel; does NOT abort
    /// the burst.
    PhotometryCadenceBroken {
        frame: u32,
        total: u32,
        gap_secs: f64,
        max_gap_secs: f64,
        /// Cumulative cadence breaks for the current node run.
        cadence_breaks: u32,
    },
    /// Science — end-of-burst summary for the photometry node.
    PhotometrySummary {
        target_designation: String,
        filter: String,
        frames_captured: u32,
        cadence_breaks: u32,
        last_reject_reason: Option<String>,
    },
}

impl ProgressDetail {
    /// Render this detail as the string format the Dart consumers and the
    /// executor's legacy progress-callback pipeline expect. The shape is `"<detail-text>"` — the leading `"<instruction>: "`
    /// prefix and trailing `" (NN%)"` suffix are added by `ProgressUpdate::legacy_message`.
    pub fn detail_text(&self) -> String {
        match self {
            ProgressDetail::Generic(s) => s.clone(),
            ProgressDetail::Exposure {
                frame,
                total,
                duration_secs,
            } => format!("Frame {}/{} ({:.1}s)", frame, total, duration_secs),
            ProgressDetail::Filter { name, position } => match position {
                Some(p) => format!("{} (pos {})", name, p),
                None => name.clone(),
            },
            ProgressDetail::Slew {
                target_ra_hours,
                target_dec_degrees,
            } => match (target_ra_hours, target_dec_degrees) {
                (Some(ra), Some(dec)) => format!("RA {:.4}h Dec {:.4}°", ra, dec),
                _ => "slewing".to_string(),
            },
            ProgressDetail::Center {
                attempt,
                max_attempts,
                last_separation_arcsec,
            } => match last_separation_arcsec {
                Some(sep) => format!("attempt {}/{} sep {:.1}\"", attempt, max_attempts, sep),
                None => format!("attempt {}/{}", attempt, max_attempts),
            },
            ProgressDetail::Autofocus {
                step,
                total_steps,
                current_hfr,
            } => match current_hfr {
                Some(hfr) => format!("step {}/{} HFR {:.2}", step, total_steps, hfr),
                None => format!("step {}/{}", step, total_steps),
            },
            ProgressDetail::Thermal {
                current_temp_c,
                target_temp_c,
            } => match (current_temp_c, target_temp_c) {
                (Some(c), Some(t)) => format!("{:.1}°C → {:.1}°C", c, t),
                (Some(c), None) => format!("{:.1}°C", c),
                (None, Some(t)) => format!("→ {:.1}°C", t),
                _ => "thermal".to_string(),
            },
            ProgressDetail::Rotator {
                current_angle_deg,
                target_angle_deg,
            } => match current_angle_deg {
                Some(c) => format!("{:.1}° → {:.1}°", c, target_angle_deg),
                None => format!("→ {:.1}°", target_angle_deg),
            },
            ProgressDetail::Wait { remaining_secs } => {
                format!("{:.0}s remaining", remaining_secs)
            }
            ProgressDetail::Dither {
                pixels,
                settle_pixels,
                ra_only,
            } => {
                if *ra_only {
                    format!("{:.1}px RA-only (settle {:.1}px)", pixels, settle_pixels)
                } else {
                    format!("{:.1}px (settle {:.1}px)", pixels, settle_pixels)
                }
            }
            ProgressDetail::Guiding {
                rms_total,
                is_settled,
            } => match rms_total {
                Some(rms) if *is_settled => format!("settled (RMS {:.2}\")", rms),
                Some(rms) => format!("settling (RMS {:.2}\")", rms),
                None => "starting".to_string(),
            },
            ProgressDetail::Mosaic {
                panel_index,
                total_panels,
                panel_row,
                panel_col,
            } => match (panel_row, panel_col) {
                (Some(r), Some(c)) => {
                    format!(
                        "panel {}/{} (row {}, col {})",
                        panel_index, total_panels, r, c
                    )
                }
                _ => format!("panel {}/{}", panel_index, total_panels),
            },
            ProgressDetail::FlatWizard {
                current_adu,
                target_adu,
                current_exposure_secs,
            } => match (current_adu, current_exposure_secs) {
                (Some(adu), Some(exp)) => {
                    format!("ADU {}/{} @ {:.3}s", adu, target_adu, exp)
                }
                (Some(adu), None) => format!("ADU {}/{}", adu, target_adu),
                (None, Some(exp)) => format!("@ {:.3}s target {}", exp, target_adu),
                _ => format!("target {} ADU", target_adu),
            },
            ProgressDetail::PolarAlignment { step } => step.clone(),
            ProgressDetail::MeridianFlip { phase } => phase.clone(),
            ProgressDetail::CoverCalibrator { state } => state.clone(),
            ProgressDetail::TemperatureCompensation { delta_steps } => {
                format!("{:+} steps", delta_steps)
            }
            ProgressDetail::Script { phase } => phase.clone(),
            ProgressDetail::Dome { phase } => phase.clone(),
            ProgressDetail::SmartExposure {
                current_filter,
                plan_index,
                total_plans,
                frame_in_plan,
                total_frames,
            } => format!(
                "{} {}/{} (plan {}/{})",
                current_filter,
                frame_in_plan,
                total_frames,
                plan_index + 1,
                total_plans
            ),
            ProgressDetail::Scheduler {
                decision_counter,
                picked_target_name,
                picked_score,
                scores,
                ..
            } => match (picked_target_name, picked_score) {
                (Some(name), Some(score)) => format!(
                    "decision {}: picked {} ({:.0}/100, {} candidates)",
                    decision_counter,
                    name,
                    score,
                    scores.len()
                ),
                _ => format!(
                    "decision {}: no runnable target ({} candidates)",
                    decision_counter,
                    scores.len()
                ),
            },
            ProgressDetail::IntegrationBudget {
                filter,
                completed_secs,
                budget_secs,
                budget_met,
                ..
            } => {
                let label = if filter.is_empty() {
                    "total".to_string()
                } else {
                    filter.clone()
                };
                if *budget_met {
                    format!("{} budget met ({:.0}s)", label, completed_secs)
                } else if *budget_secs > 0.0 {
                    format!("{} {:.0}s / {:.0}s", label, completed_secs, budget_secs)
                } else {
                    format!("{} {:.0}s", label, completed_secs)
                }
            }
            ProgressDetail::FrameAccepted {
                frame,
                total,
                hfr,
                accepted_total,
                rejected_total,
                ..
            } => match hfr {
                Some(h) => format!(
                    "frame {}/{} accepted (HFR {:.2}; {}/{} kept)",
                    frame,
                    total,
                    h,
                    accepted_total,
                    accepted_total + rejected_total
                ),
                None => format!(
                    "frame {}/{} accepted ({}/{} kept)",
                    frame,
                    total,
                    accepted_total,
                    accepted_total + rejected_total
                ),
            },
            ProgressDetail::FrameRejected {
                frame,
                total,
                reason,
                consecutive_rejects,
                likely_cause,
                ..
            } => {
                // forensics: when a likely cause has been
                // classified, surface its label in the legacy detail
                // text so non-typed subscribers (logs, telemetry
                // exporters) still see it.
                let cause_suffix = likely_cause
                    .map(|c| format!(" [cause: {}]", c.label()))
                    .unwrap_or_default();
                if *consecutive_rejects > 1 {
                    format!(
                        "frame {}/{} REJECTED ({}× consecutive): {}{}",
                        frame, total, consecutive_rejects, reason, cause_suffix
                    )
                } else {
                    format!(
                        "frame {}/{} REJECTED: {}{}",
                        frame, total, reason, cause_suffix
                    )
                }
            }
            ProgressDetail::ExposureAdjusted {
                adapted_secs,
                nominal_secs,
                sky_brightness_mag,
                reason,
                ..
            } => match sky_brightness_mag {
                Some(mag) => format!(
                    "{:.1}s (nominal {:.1}s, sky {:.2} mag/arcsec², {})",
                    adapted_secs, nominal_secs, mag, reason
                ),
                None => format!(
                    "{:.1}s (nominal {:.1}s, {})",
                    adapted_secs, nominal_secs, reason
                ),
            },
            // plugin nodes carry an opaque JSON detail.
            // We surface a compact identifier so the legacy
            // `InstructionProgress` text channel still has something to
            // show; the typed `SequencerEvent::PluginNodeProgress` event
            // carries the full structured payload for the dashboard.
            ProgressDetail::PluginNode {
                plugin_id,
                node_type_id,
                detail,
            } => {
                if detail.is_null()
                    || matches!(detail, serde_json::Value::Object(o) if o.is_empty())
                {
                    format!("{}/{}", plugin_id, node_type_id)
                } else {
                    // Compact (no whitespace) so the legacy line stays
                    // dashboard-friendly even when the plugin author
                    // ships a richly-nested payload.
                    let compact = serde_json::to_string(detail)
                        .unwrap_or_else(|_| "<unserialisable>".to_string());
                    format!("{}/{}: {}", plugin_id, node_type_id, compact)
                }
            }
            // Science — render the photometry payloads as compact
            // status text for the legacy InstructionProgress channel.
            ProgressDetail::PhotometryFrame {
                target_designation,
                frame,
                total,
                filter,
                snr,
                fwhm_arcsec,
                airmass,
                accepted,
                reject_reason,
                ..
            } => {
                let outcome = if *accepted {
                    "PASS".to_string()
                } else {
                    reject_reason
                        .as_deref()
                        .map(|r| format!("REJECT ({})", r))
                        .unwrap_or_else(|| "REJECT".to_string())
                };
                format!(
                    "{} frame {}/{} {} | snr={:?} fwhm={:?}\" airmass={:?} {}",
                    target_designation, frame, total, filter, snr, fwhm_arcsec, airmass, outcome,
                )
            }
            ProgressDetail::PhotometryCadenceBroken {
                frame,
                total,
                gap_secs,
                max_gap_secs,
                cadence_breaks,
            } => format!(
                "Cadence broken at frame {}/{}: {:.1}s gap (max {:.1}s); break #{}",
                frame, total, gap_secs, max_gap_secs, cadence_breaks
            ),
            ProgressDetail::PhotometrySummary {
                target_designation,
                filter,
                frames_captured,
                cadence_breaks,
                last_reject_reason,
            } => {
                let suffix = last_reject_reason
                    .as_deref()
                    .map(|r| format!(", last reject: {}", r))
                    .unwrap_or_default();
                format!(
                    "{} {} burst complete: {} frames, {} cadence breaks{}",
                    target_designation, filter, frames_captured, cadence_breaks, suffix,
                )
            }
        }
    }
}

/// Progress update emitted by a node during execution.
///
/// `message` is auto-derived from `instruction` + `detail` + `progress_percent`
/// in the legacy format the bridge / Dart consumers expect (`"Filter: name (50%)"`).
/// Producers should populate the structured fields; the executor callback
/// reads the structured payload directly and does NOT parse `message`.
#[derive(Debug, Clone)]
pub struct ProgressUpdate {
    pub node_id: NodeId,
    pub status: NodeStatus,
    /// Display name of the instruction emitting this update (e.g. "Filter",
    /// "Autofocus", "Slew"). `None` for container/logic nodes that emit
    /// life-cycle messages instead of instruction progress.
    pub instruction: Option<String>,
    /// 0-100. `None` when the update is a life-cycle event (NodeStarted /
    /// NodeCompleted) rather than a progress increment.
    pub progress_percent: Option<f64>,
    /// Structured payload. `None` for container/logic life-cycle events.
    pub detail: Option<ProgressDetail>,
    /// Free-form fallback message. Populated by container/logic nodes that
    /// have no instruction-level detail (e.g. "Loop iteration 3",
    /// "Step 2/5: Slew To Target"). For instruction nodes this is normally
    /// `None` — the executor derives the legacy message from the structured
    /// fields via [`ProgressUpdate::legacy_message`].
    pub message: Option<String>,
    pub current_frame: Option<u32>,
    pub total_frames: Option<u32>,
    pub current_child: Option<usize>,
    pub total_children: Option<usize>,
    /// Exposure time just completed (seconds). Carried only on the final
    /// burst-completion event so the executor's global integration counter
    /// is incremented exactly once per burst.
    pub completed_exposure_secs: Option<f64>,
    /// Seconds the frame named by [`ProgressUpdate::current_frame`] was
    /// RECORDED as — the camera's own report, bounded (see
    /// `instructions::recorded_exposure_secs`), which is the same number the
    /// FITS `EXPTIME` card and the `captured_images` row were written from.
    ///
    /// `None` on any update that is not a per-frame sighting. The executor
    /// credits integration and stamps the exposure events from this when it is
    /// present, and falls back to the node's PLANNED duration when it is not —
    /// crediting the plan is what makes surfaces that sum the rows disagree with
    /// surfaces that multiply.
    pub frame_exposure_secs: Option<f64>,
}

impl ProgressUpdate {
    /// Build the legacy progress message string the bridge layer publishes.
    /// Format matches the consumer regex: `"<instruction>: <detail> (<NN>%)"`.
    /// Returns `message` verbatim when no structured fields are populated
    /// (the container/logic life-cycle case).
    pub fn legacy_message(&self) -> Option<String> {
        // Instruction-progress event: synthesize "Foo: detail (NN%)".
        if let (Some(instruction), Some(percent)) =
            (self.instruction.as_ref(), self.progress_percent)
        {
            let detail_text = self
                .detail
                .as_ref()
                .map(|d| d.detail_text())
                .unwrap_or_default();
            return Some(format!(
                "{}: {} ({:.0}%)",
                instruction, detail_text, percent
            ));
        }
        // Life-cycle event: pass `message` through unchanged.
        self.message.clone()
    }

    /// Construct a life-cycle update (NodeStarted, NodeCompleted, etc.).
    /// These do not carry structured instruction-progress data.
    pub fn lifecycle(node_id: NodeId, status: NodeStatus, message: impl Into<String>) -> Self {
        Self {
            node_id,
            status,
            instruction: None,
            progress_percent: None,
            detail: None,
            message: Some(message.into()),
            current_frame: None,
            total_frames: None,
            current_child: None,
            total_children: None,
            completed_exposure_secs: None,
            frame_exposure_secs: None,
        }
    }

    /// Construct an instruction progress update with structured detail.
    pub fn instruction_progress(
        node_id: NodeId,
        instruction: impl Into<String>,
        percent: f64,
        detail: ProgressDetail,
    ) -> Self {
        Self {
            node_id,
            status: NodeStatus::Running,
            instruction: Some(instruction.into()),
            progress_percent: Some(percent),
            detail: Some(detail),
            message: None,
            current_frame: None,
            total_frames: None,
            current_child: None,
            total_children: None,
            completed_exposure_secs: None,
            frame_exposure_secs: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_message_matches_pre_refactor_format() {
        let upd = ProgressUpdate::instruction_progress(
            "node1".to_string(),
            "Filter",
            50.0,
            ProgressDetail::Filter {
                name: "Red".to_string(),
                position: Some(2),
            },
        );
        assert_eq!(
            upd.legacy_message().as_deref(),
            Some("Filter: Red (pos 2) (50%)")
        );
    }

    #[test]
    fn legacy_message_for_lifecycle_passes_message_through() {
        let upd =
            ProgressUpdate::lifecycle("node1".to_string(), NodeStatus::Running, "Loop iteration 3");
        assert_eq!(upd.legacy_message().as_deref(), Some("Loop iteration 3"));
    }

    #[test]
    fn progress_detail_serde_roundtrip() {
        let d = ProgressDetail::Autofocus {
            step: 5,
            total_steps: 13,
            current_hfr: Some(2.3),
        };
        let s = serde_json::to_string(&d).expect("serialize");
        let back: ProgressDetail = serde_json::from_str(&s).expect("deserialize");
        match back {
            ProgressDetail::Autofocus {
                step,
                total_steps,
                current_hfr,
            } => {
                assert_eq!(step, 5);
                assert_eq!(total_steps, 13);
                assert_eq!(current_hfr, Some(2.3));
            }
            other => panic!("unexpected variant: {:?}", other),
        }
    }

    #[test]
    fn legacy_message_format_with_no_percent_is_none_for_instruction_progress() {
        // An instruction event without percent shouldn't synthesize; it's
        // either a life-cycle event (None percent) or an inconsistent state
        // — we treat it as the life-cycle fallback.
        let mut upd = ProgressUpdate::instruction_progress(
            "n".to_string(),
            "Slew",
            10.0,
            ProgressDetail::Slew {
                target_ra_hours: None,
                target_dec_degrees: None,
            },
        );
        upd.progress_percent = None;
        upd.message = Some("Manual life-cycle".to_string());
        assert_eq!(upd.legacy_message().as_deref(), Some("Manual life-cycle"));
    }
}
