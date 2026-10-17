use super::*;

/// Sequencer-specific events
#[frb]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum SequencerEvent {
    Started {
        sequence_name: String,
    },
    Paused,
    Resumed,
    Stopped {
        /// The run this terminal belongs to, when the publisher knows it.
        /// Episode identity for the dashboard's stop fold: without it a
        /// bare terminal and a neighbouring press are indistinguishable.
        sequence_run_id: Option<i64>,
    },
    Completed,
    /// The run ended in FAILURE. Terminal, and the counterpart of
    /// [`SequencerEvent::Completed`] / [`SequencerEvent::Stopped`].
    ///
    /// This is what drives Dart's `_onTerminalEvent`; `SequencerEvent::Error` is
    /// handled there as a non-terminal mid-run error, so a failure delivered as
    /// `Error` never finalizes the run — `sequence_runs.status` stays `'running'`
    /// with a null `ended_at`, the imaging session stays active, and the next
    /// start is refused with `active_session_exists`.
    Failed {
        error: String,
    },
    NodeStarted {
        node_id: String,
        node_type: String,
    },
    NodeCompleted {
        node_id: String,
        /// Completion status: "success", "failed", "cancelled", or "skipped"
        status: String,
    },
    Progress {
        current: u32,
        total: u32,
    },
    TargetChanged {
        target_name: String,
        /// Right Ascension in hours (0-24), if available from the target header
        ra: Option<f64>,
        /// Declination in degrees (-90 to +90), if available from the target header
        dec: Option<f64>,
    },
    TargetCompleted {
        target_name: String,
    },
    ExposureStarted {
        frame: u32,
        total: u32,
        filter: Option<String>,
        duration_secs: f64,
    },
    ExposureCompleted {
        frame: u32,
        total: u32,
        duration_secs: f64,
    },
    Error {
        message: String,
    },
    /// A meridian flip finished. Mirrors
    /// `ExecutorEvent::MeridianFlipOutcome`.
    ///
    /// The flip is the most dangerous operation the app runs unattended, so its
    /// verdict rides the wire as this typed variant — consumed by the Dart
    /// run-stats layer, which counts the flip and surfaces a failed post-flip
    /// recenter rather than sniffing either out of a log string.
    MeridianFlipOutcome {
        /// `"success"`, `"failed"`, or `"aborted"`.
        outcome: String,
        /// Target the flip was performed for.
        target_name: String,
        /// Pier side reported after the flip (`East` / `West` / `Unknown`).
        new_pier_side: String,
        /// Wall-clock seconds for the whole flip, retries included.
        duration_secs: f64,
        /// Attempts made; `> 1` means the flip was DEGRADED.
        attempts: u32,
        /// One `"<step>: <error>"` per failed attempt, oldest first.
        failed_steps: Vec<String>,
        /// Terminal error. `None` on a clean success.
        error: Option<String>,
        /// Failure action executed (`"PauseAndAlert"` / `"AbortAndPark"`).
        action_taken: Option<String>,
    },
    /// A trigger watchdog fired during sequence execution
    TriggerFired {
        /// Unique trigger identifier
        trigger_id: String,
        /// Human-readable trigger name
        trigger_name: String,
        /// Action taken (e.g., "Autofocus", "Dither", "PauseSequence")
        action: String,
    },
    /// Progress update for long-running instructions (cooling, autofocus, slewing)
    InstructionProgress {
        /// Node ID for mapping progress to the correct tree node
        node_id: String,
        /// Name of the instruction (e.g., "Cool Camera", "Autofocus")
        instruction: String,
        /// Progress percentage (0.0 to 100.0)
        progress_percent: f64,
        /// Detailed status message
        detail: String,
    },
    /// Structured progress update for long-running instructions. This is
    /// emitted alongside `InstructionProgress` so legacy consumers keep their
    /// string detail while newer UI panels can bind to explicit fields.
    InstructionProgressStructured {
        /// Node ID for mapping progress to the correct tree node
        node_id: String,
        /// Name of the instruction (e.g., "Cool Camera", "Autofocus")
        instruction: String,
        /// Progress percentage (0.0 to 100.0)
        progress_percent: f64,
        /// `ProgressDetail` variant name (e.g. `Exposure`, `Autofocus`)
        detail_kind: String,
        /// JSON-stringified inner payload for the variant.
        detail_json: String,
    },

    // Typed progress payloads.
    //
    // The image-grading and target-scheduler details
    // (`ProgressDetail::FrameAccepted/FrameRejected/Scheduler/IntegrationBudget`)
    // are first-class typed variants rather than strings the Dart side has to
    // regex out of `InstructionProgress.detail`. `run_sequencer_event_loop`
    // matches on the structured `ProgressDetail` and emits the typed variant; the
    // legacy `InstructionProgress` is emitted alongside it, so the typed variants
    // are additional, not replacements, and unmigrated subscribers keep working.
    /// A Smart Exposure plan finished early because its bound DepthLock
    /// goal was achieved. Mirrors `ExecutorEvent::DepthGoalCompleted`; the
    /// numbers are the evidence the verdict rested on, so the run history
    /// can explain the transition without the goal store.
    DepthGoalCompleted {
        node_id: String,
        filter_name: String,
        goal_id: String,
        revision: u64,
        evidence_frames: u32,
        confirmation_frames: u32,
        score: f64,
        threshold: f64,
    },
    /// Image Grading: a frame passed every configured
    /// quality threshold and was saved to the normal output folder.
    /// Mirrors `ProgressDetail::FrameAccepted`.
    FrameAccepted {
        node_id: String,
        /// 1-based frame index within the current TakeExposure burst.
        frame: u32,
        total: u32,
        hfr: Option<f64>,
        eccentricity: Option<f64>,
        star_count: Option<u32>,
        /// Running count of accepted frames for the whole run.
        accepted_total: u32,
        /// Running count of rejected frames for the whole run.
        rejected_total: u32,
        /// on-disk save path of the accepted frame, so
        /// the thumbnail strip can render an inline preview of
        /// accepted frames the same way it already does for rejected
        /// frames via `FrameRejected.reject_path`. `None` for legacy /
        /// non-grading emit sites that did not thread the path through.
        save_path: Option<String>,
        /// Per-frame capture truth, taken from the `FrameContext` the FITS
        /// writer stamped this frame's header from. Dart persists it straight
        /// into `captured_images`, which is why the row and the file agree:
        /// both are written from one struct rather than two independent
        /// reconstructions of the same exposure.
        capture: FrameCaptureMetadata,
    },
    /// Image Grading: a frame failed at least one
    /// quality threshold and was routed to the reject folder. Mirrors
    /// `ProgressDetail::FrameRejected`. A streak of rejects never pauses
    /// the run; this event surfaces the metrics so the
    /// dashboard can render them without parsing.
    FrameRejected {
        node_id: String,
        frame: u32,
        total: u32,
        reason: String,
        hfr: Option<f64>,
        eccentricity: Option<f64>,
        star_count: Option<u32>,
        reject_path: String,
        /// Running consecutive-rejects counter. When this reaches the
        /// configured `max_consecutive_rejects`, the operator is notified
        /// once for the streak; the run carries on.
        consecutive_rejects: u32,
        accepted_total: u32,
        rejected_total: u32,
        // Frame-Failure Forensics ----------------------------
        /// Classified cause label (wire-stable snake_case string from
        /// `LikelyCause::label()`). `None` when the classifier was not
        /// consulted or could not pick a single best guess. Dart maps
        /// this back to its `LikelyCause` enum via
        /// `LikelyCauseExt.fromLabel`.
        likely_cause_label: Option<String>,
        /// Human-readable evidence bullets the dashboard surfaces in
        /// the Forensics panel and Frame Detail dialog. Empty list
        /// when no telemetry was available.
        evidence: Vec<String>,
        /// Sky brightness reading at capture time (mag/arcsec²).
        sky_brightness_at_capture: Option<f64>,
        /// Cloud cover percentage (0-100) at capture time.
        cloud_cover_at_capture: Option<f64>,
        /// Wind speed at capture time (km/h). `None` when no weather
        /// feed is wired through to the sequencer.
        wind_at_capture: Option<f64>,
        /// Guide RMS (arc-seconds) sampled at capture time.
        guide_rms_at_capture: Option<f64>,
        /// Sensor temperature (°C) at capture time.
        sensor_temp_at_capture: Option<f64>,
        /// Per-frame capture truth — see [`SequencerEvent::FrameAccepted`].
        /// A rejected frame is still on disk and still gets a row, so it is
        /// stamped from the same struct.
        capture: FrameCaptureMetadata,
    },
    /// TargetScheduler decision. Mirrors
    /// `ProgressDetail::Scheduler`. The score table is exposed as a
    /// flat `Vec<SchedulerScoreEntry>` so FRB doesn't have to bridge
    /// the internal `SchedulerScoreSummary` type.
    SchedulerDecision {
        node_id: String,
        /// 1-based decision counter for this scheduler instance.
        decision_counter: u32,
        /// `None` when no target cleared `min_score_to_run`.
        picked_target_id: Option<String>,
        picked_target_name: Option<String>,
        /// Picked target's total score (0..=100). `None` when nothing
        /// was picked.
        picked_score: Option<f64>,
        /// Flat score table (runnable first, then by descending total).
        scores: Vec<SchedulerScoreEntry>,
    },
    /// per-target integration budget tick.
    /// Mirrors `ProgressDetail::IntegrationBudget`.
    IntegrationBudget {
        /// The TargetHeader node id this budget belongs to.
        target_id: String,
        /// Filter the credit was applied to (`""` for no-filter cameras).
        filter: String,
        completed_secs: f64,
        budget_secs: f64,
        fraction: f64,
        budget_met: bool,
    },
    /// sky-brightness adaptive exposure decision.
    /// Mirrors `ProgressDetail::ExposureAdjusted`. Emitted before every
    /// exposure burst whenever the adapter was consulted (regardless of
    /// whether the duration actually changed), so the Run Dashboard can
    /// surface live sky brightness + the most recent nominal/adapted
    /// pair and the user understands why the camera is running longer
    /// (or shorter) than configured.
    ExposureAdjusted {
        node_id: String,
        /// Adapted (effective) exposure duration in seconds.
        adapted_secs: f64,
        /// User-configured nominal duration in seconds.
        nominal_secs: f64,
        /// Live sky brightness used in the decision (mag/arcsec²). `None`
        /// when the adapter fell back due to missing telemetry.
        sky_brightness_mag: Option<f64>,
        /// Filter being captured through. `None` for monochrome / no
        /// filter wheel rigs.
        filter: Option<String>,
        /// Lowercase tag: `adapted`, `clamped_min`, `clamped_max`,
        /// `unavailable`, `disabled`, `out_of_nominal_bounds`.
        reason: String,
    },

    // Typed Science / photometry progress payloads.
    //
    // These mirror the field shapes of the `ProgressDetail` photometry variants
    // (`PhotometryFrame`, `PhotometryCadenceBroken`, `PhotometrySummary` — see
    // `skotiq_sequencer::node::progress`) so the Dart light-curve panel binds
    // to explicit floats (SNR / FWHM / airmass) instead of recovering them from a
    // formatted `detail` string. As with the progress payloads above, they are
    // emitted alongside the legacy `InstructionProgress`, not in place of it.
    /// Science: per-frame photometry payload from the
    /// `SciencePhotometryInstruction`. Mirrors
    /// `ProgressDetail::PhotometryFrame`. The Dart science pipeline writes a row
    /// to `photometry_measurements` and updates the live light-curve chart on
    /// the Run Dashboard.
    PhotometryFrame {
        /// Node ID for mapping progress to the correct tree node.
        node_id: String,
        /// Resolved target designation (e.g. `"V* DY Peg"`).
        target_designation: String,
        /// Reference / comparison star designations used for differential
        /// photometry. Empty when differential photometry is disabled.
        reference_stars: Vec<String>,
        /// 1-based frame index within the current photometry burst.
        frame: u32,
        total: u32,
        filter: String,
        exposure_secs: f64,
        /// Airmass at exposure midpoint. `None` when no WCS / pointing was
        /// available to compute it.
        airmass: Option<f64>,
        /// Measured stellar FWHM (arc-seconds). `None` when the frame yielded
        /// no usable star measurement.
        fwhm_arcsec: Option<f64>,
        /// Signal-to-noise ratio of the target aperture. `None` when not
        /// measured.
        snr: Option<f64>,
        /// Modified Julian Date at exposure midpoint (FITS `MJD-OBS`).
        mjd_obs: f64,
        /// Unix epoch seconds at exposure start.
        frame_start_unix: f64,
        /// True when the frame passed every quality gate
        /// (`PhotometryFrameVerdict::Pass`).
        accepted: bool,
        /// Rejection reason when `accepted == false`
        /// (`PhotometryFrameVerdict::Reject { reason }`); `None` when accepted.
        reject_reason: Option<String>,
        /// True when live reduction was performed for this frame.
        reduce_live: bool,
        /// True when differential photometry was applied for this frame.
        apply_differential: bool,
    },
    /// Science: cadence-violation event emitted whenever the inter-frame
    /// start-to-start gap exceeds the configured ceiling. Mirrors
    /// `ProgressDetail::PhotometryCadenceBroken`. Surfaced by the dashboard
    /// photometry panel; does NOT abort the burst.
    PhotometryCadenceBroken {
        /// Node ID for mapping progress to the correct tree node.
        node_id: String,
        /// 1-based frame index whose start broke the cadence.
        frame: u32,
        total: u32,
        /// Observed start-to-start gap (seconds).
        gap_secs: f64,
        /// Configured maximum allowed gap (seconds).
        max_gap_secs: f64,
        /// Cumulative cadence breaks for the current node run.
        cadence_breaks: u32,
    },
    /// Science: end-of-burst summary for the photometry node. Mirrors
    /// `ProgressDetail::PhotometrySummary`.
    PhotometrySummary {
        /// Node ID for mapping progress to the correct tree node.
        node_id: String,
        target_designation: String,
        filter: String,
        /// Number of frames captured during the burst (accepted + rejected).
        frames_captured: u32,
        /// Total cadence breaks observed during the burst.
        cadence_breaks: u32,
        /// Last rejection reason seen during the burst; `None` when no frame
        /// was rejected.
        last_reject_reason: Option<String>,
    },

    // Recovery Mode — typed entry / progress / exit events
    //
    // Pre-Wave-4.5, the Rust executor's `ExecutorEvent::Recovery*` events
    // were routed through the legacy `InstructionProgress` channel with
    // `node_id == "_recovery"` and a JSON-encoded context blob shoved in
    // `detail`. The Dart side string-prefix-matched on `instruction` and
    // jsonDecoded `detail` — fragile, lossy, and silently dropped fields
    // that didn't fit. promotes the four variants to first-class
    // typed payloads. All `context_*` fields are denormalised flat
    // primitives so FRB doesn't need to bridge the chrono-dependent
    // `RecoveryContext` struct. The Dart side rebuilds a `RecoveryStatus`
    // from these flat fields in `_recoveryStatusFromTypedEvent`.
    //
    // `cause_kind` is the Rust enum variant name (`GuideStarLost`,
    // `SlewFailed`, etc.) so the Dart side can map directly to
    // `RecoveryCause.<factory>`. `cause_custom_label` carries the inner
    // string for the `Custom(String)` variant — non-empty only when
    // `cause_kind == "Custom"`.
    //
    // `phase` mirrors `RecoveryPhase` (`Waiting`, `Attempting`,
    // `Recovered`, `GaveUp`) so the dashboard banner knows which row
    // to render.
    /// Recovery Mode: the executor just entered the `Recovering`
    /// state. Subscribers (dashboard banner, audible alert player,
    /// push-notification service) render the cause / attempt counter
    /// / countdown without reaching back into the executor.
    RecoveryStarted {
        started_at_iso: String,
        cause_kind: String,
        cause_custom_label: Option<String>,
        last_attempt_at_iso: Option<String>,
        attempt_count: u32,
        max_attempts: u32,
        retry_interval_secs: f64,
        max_duration_secs: f64,
        phase: String,
        last_error: Option<String>,
    },
    /// Recovery Mode: periodic update of the live recovery context
    /// (attempt counter incremented, phase changed, last_error updated).
    /// Subscribers refresh the dashboard banner from this; the
    /// `RecoveryStarted` / `RecoveryCompleted` / `RecoveryGaveUp` events
    /// bookend the loop while this carries deltas inside the loop.
    RecoveryProgress {
        started_at_iso: String,
        cause_kind: String,
        cause_custom_label: Option<String>,
        last_attempt_at_iso: Option<String>,
        attempt_count: u32,
        max_attempts: u32,
        retry_interval_secs: f64,
        max_duration_secs: f64,
        phase: String,
        last_error: Option<String>,
    },
    /// Recovery Mode: recovery succeeded. The executor will
    /// transition back to `Running`; subscribers clear the dashboard
    /// banner and append to the history list.
    RecoveryCompleted {
        started_at_iso: String,
        cause_kind: String,
        cause_custom_label: Option<String>,
        last_attempt_at_iso: Option<String>,
        attempt_count: u32,
        max_attempts: u32,
        retry_interval_secs: f64,
        max_duration_secs: f64,
        phase: String,
        last_error: Option<String>,
    },
    /// Recovery Mode: recovery exhausted attempts / time / was
    /// aborted by the user. The executor will transition to `Failed` (or
    /// run the configured ParkAndAbort policy). Subscribers append the
    /// history entry and emit a critical-severity event.
    RecoveryGaveUp {
        started_at_iso: String,
        cause_kind: String,
        cause_custom_label: Option<String>,
        last_attempt_at_iso: Option<String>,
        attempt_count: u32,
        max_attempts: u32,
        retry_interval_secs: f64,
        max_duration_secs: f64,
        phase: String,
        last_error: Option<String>,
        /// True when the loop exited because the user pressed Abort.
        /// Distinct from exhaustion so the UI can render different copy
        /// ("Aborted by operator" vs "Exhausted retries").
        aborted_by_user: bool,
    },

    // plugin sequence nodes (Rust dispatch)
    //
    // The Rust executor reaches a `NodeType::PluginNode`, registers a
    // pending oneshot for the node id, and emits PluginNodeRequested.
    // The Dart `SequenceExecutor` consumes this event, dispatches to
    // `PluginNodeExecutor.run`, then calls `api_sequencer_plugin_node_finished`
    // to push the verdict back into Rust via
    // `ExecutorCommand::PluginNodeFinished`. The Rust instruction node
    // unblocks with Success or Failure.
    /// the executor is waiting for the Dart side to
    /// dispatch a plugin node and reply with the verdict.
    PluginNodeRequested {
        /// Executor-side node identifier. The reply MUST echo this.
        node_id: String,
        /// Stable plugin identifier (e.g. `com.example.pushover`).
        plugin_id: String,
        /// Stable per-plugin node type identifier (e.g. `pushover.notify`).
        node_type_id: String,
        /// Opaque JSON payload the plugin author authored on the Dart
        /// side. Rust forwards verbatim.
        config_json: String,
        /// Optional human-readable label. `None` => UI uses
        /// `node_type_id`.
        display_name: Option<String>,
        /// Effective timeout (seconds) the Rust side will wait. Dart
        /// MUST honour this; a longer run on the Dart side will be
        /// timed out by Rust first and surfaced as a failure.
        timeout_secs: u32,
    },
    /// live plugin-node progress payload. Mirrors
    /// `ProgressDetail::PluginNode`. The JSON detail is serialised as a
    /// string at the bridge boundary because FRB does not transport
    /// `serde_json::Value` directly; Dart parses it with
    /// `jsonDecode(detail_json)`.
    PluginNodeProgress {
        node_id: String,
        plugin_id: String,
        node_type_id: String,
        /// Stringified plugin-authored payload. Empty string when the
        /// plugin emitted no payload.
        detail_json: String,
    },

    // Replay Debug: typed decision payload
    /// Replay Debug — a structured decision emitted by the
    /// sequencer (scheduler pick, trigger fire, recovery transition,
    /// frame verdict, adaptive swap, plugin invocation, manual operator
    /// action, or system event). Subscribers persist these to the
    /// `sequence_decisions` Drift table and the Replay screen scrubs
    /// chronologically through them.
    ///
    /// `details_json` is the JSON-stringified payload — FRB does not
    /// bridge `serde_json::Value` directly, so the Dart side does
    /// `jsonDecode(details_json)` to recover the structured map.
    ///
    /// `category` is the stable wire key (`scheduler_pick`,
    /// `trigger_fired`, etc.) — see
    /// `skotiq_sequencer::DecisionCategory::wire_key`.
    DecisionLogged {
        /// ISO-8601 UTC timestamp when the decision was made.
        timestamp_iso: String,
        /// Stable wire key for the underlying DecisionCategory variant.
        category: String,
        /// One-line human-readable summary.
        summary: String,
        /// JSON-stringified opaque details payload.
        details_json: String,
        /// Optional associated node id (scheduler / target / exposure
        /// node).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        node_id: Option<String>,
        /// `sequence_runs.id` this decision belongs to, if the executor
        /// has been stamped with one.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sequence_run_id: Option<i64>,
    },
}

/// flat scheduler score row exposed across FRB. Mirrors
/// `skotiq_sequencer::node::logic::target_scheduler::SchedulerScoreSummary`
/// but lives in the bridge crate so we don't have to expose the sequencer
/// type to FRB. The Dart side consumes this directly in the run-dashboard
/// scheduler panel.
#[frb]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SchedulerScoreEntry {
    pub target_id: String,
    pub target_name: String,
    /// Total score (0..=100) the scheduler computed.
    pub total_score: f64,
    /// True when the target was eligible to run (cleared
    /// `min_score_to_run` and any altitude / window gates).
    pub runnable: bool,
    /// Human-readable reason, populated when `runnable == false`
    /// (e.g. "below altitude limit", "before start window").
    pub reason: Option<String>,
}

/// Per-frame capture truth carried across FRB on the frame events. Mirrors
/// `skotiq_sequencer::scheduling::FrameCaptureMetadata` field for field,
/// living in the bridge crate for the same reason [`SchedulerScoreEntry`] does.
///
/// Every one of these values is already in the FITS header the sequencer wrote
/// for the same exposure. Shipping them on the event is what lets Dart write
/// the `captured_images` row from the header's own source instead of
/// reconstructing a second, thinner version of the frame from the sequence
/// tree — the reconstruction that left rows with NULL gain, offset, sensor
/// temperature, pointing, focuser position and rotator angle.
#[frb]
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
pub struct FrameCaptureMetadata {
    pub gain: Option<i32>,
    pub offset: Option<i32>,
    pub sensor_temp_c: Option<f64>,
    pub cooler_power_percent: Option<f64>,
    /// Mount right ascension in HOURS, matching `captured_images.mount_ra`.
    /// The FITS `RA` card is degrees; do not copy this into a degrees-valued
    /// field without multiplying by 15.
    pub mount_ra_hours: Option<f64>,
    pub mount_dec_degrees: Option<f64>,
    pub mount_altitude_deg: Option<f64>,
    pub mount_azimuth_deg: Option<f64>,
    /// `"East"` / `"West"`, or `None` when no mount answered.
    pub pier_side: Option<String>,
    pub focuser_position: Option<i32>,
    pub focuser_temperature_c: Option<f64>,
    pub rotator_angle_deg: Option<f64>,
    pub exposure_secs: f64,
    pub bin_x: u32,
    pub bin_y: u32,
    /// "Light" / "Dark" / "Flat" / "Bias" — the FITS `IMAGETYP` string.
    pub frame_type: String,
    pub target_id: Option<String>,
}

impl From<&skotiq_sequencer::scheduling::FrameCaptureMetadata> for FrameCaptureMetadata {
    fn from(m: &skotiq_sequencer::scheduling::FrameCaptureMetadata) -> Self {
        Self {
            gain: m.gain,
            offset: m.offset,
            sensor_temp_c: m.sensor_temp_c,
            cooler_power_percent: m.cooler_power_percent,
            mount_ra_hours: m.mount_ra_hours,
            mount_dec_degrees: m.mount_dec_degrees,
            mount_altitude_deg: m.mount_altitude_deg,
            mount_azimuth_deg: m.mount_azimuth_deg,
            pier_side: m.pier_side.clone(),
            focuser_position: m.focuser_position,
            focuser_temperature_c: m.focuser_temperature_c,
            rotator_angle_deg: m.rotator_angle_deg,
            exposure_secs: m.exposure_secs,
            bin_x: m.bin_x,
            bin_y: m.bin_y,
            frame_type: m.frame_type.clone(),
            target_id: m.target_id.clone(),
        }
    }
}
