import 'dart:async';

import '../../models/backend/backend_types.dart';
import '../../models/sequence/sequence_models.dart'
    show AdaptiveSwapSnapshot, ConditionsScore;
import '../../services/adaptive_swap_service.dart' show AdaptiveSwapBackend;

/// Role interface covering sequencer execution, recovery, and checkpoint state.
///
/// What this role owns:
///   * Sequencer lifecycle: start, stop, pause, resume, skip, reset, load,
///     status, plugin-node verdict, jump-to-node.
///   * Runtime configuration of the executor: dither, location, filter
///     offsets, carry-over integration, autofocus interval, quality grading
///     defaults, reject folder, observer profile, sky brightness, adaptive
///     exposure defaults, cloud-motion telemetry, conditions score, adaptive
///     swap snapshot, simulation mode, devices, safety fail mode, safety
///     poll interval, save path, decision logging, sequence run id.
///   * Recovery loop: try-now, abort, config push, current snapshot, history.
///   * Checkpoint persistence: directory, has/get/save/resume/discard.
///
/// What this role deliberately does NOT own:
///   * Device commands the sequencer issues against drivers — see
///     [DeviceBackend].
///   * Image-time grading transforms — see [ImagingBackend]. The role owns
///     the *configuration* of grading thresholds; the FITS-time gate that
///     runs inside the executor is a Rust concern.
///   * Profile / settings persistence — see [ProfileSettingsBackend].
///
/// [AdaptiveSwapBackend] is composed here because the two adaptive-swap
/// methods (`sequencerUpdateConditionsScore`, `sequencerGetAdaptiveSwapSnapshot`)
/// are sequencer-runtime mutations and the adaptive-swap composer depends
/// on exactly that pair.
abstract class SequencerBackend implements AdaptiveSwapBackend {
  // Sequencer control

  /// Start the sequencer
  Future<void> sequencerStart();

  /// Stop the sequencer
  /// `origin` names the caller — `null`/`'operator'` for a human,
  /// `'scheduler'` for the autopilot.
  Future<void> sequencerStop({String? origin});

  /// Pause the sequencer
  Future<void> sequencerPause();

  /// Resume the sequencer
  Future<void> sequencerResume();

  /// Skip the current node in the sequencer
  Future<void> sequencerSkip();

  /// Jump execution to a specific node id, skipping siblings
  /// that precede it. The currently-running instruction continues to
  /// completion first; the jump takes effect on the next container tree-walk
  /// step. Should be gated by execution-state in the UI (only enabled while
  /// running). Throws if the executor is not running.
  Future<void> sequencerSkipToNode(String nodeId);

  /// Report the verdict of a plugin-dispatched
  /// `NodeType::PluginNode` back to the Rust executor. The Rust side has
  /// a pending `tokio::sync::oneshot` keyed on [nodeId]; the verdict
  /// resolves it and the awaiting instruction returns Success / Failure.
  ///
  /// [structuredDetailJson] is forwarded verbatim and surfaced via the
  /// final `ProgressDetail::PluginNode` event. Invalid JSON is logged
  /// and dropped on the Rust side; the verdict still applies.
  ///
  /// Throws if the executor is not running (treat as a stale reply —
  /// the run was cancelled between dispatch and reply).
  Future<void> sequencerPluginNodeFinished({
    required String nodeId,
    required bool success,
    String? message,
    String? structuredDetailJson,
  });

  /// Reset the sequencer to its initial state
  Future<void> sequencerReset();

  /// Load a sequence definition (JSON) into the sequencer
  Future<void> sequencerLoadJson(String json);

  /// Get sequencer status
  Future<SequencerStatus> sequencerGetStatus();

  /// Set simulation mode (use mock devices instead of real hardware)
  Future<void> sequencerSetSimulationMode(bool enabled);

  /// Whether the executor is currently driving simulated device ops.
  ///
  /// This is a readback of what the executor holds, not of what anyone
  /// requested: the flag flips only once the call installing simulated ops
  /// has returned successfully, so a UI badge fed from here cannot claim
  /// simulated hardware while real mounts and cameras are under the run.
  Future<bool> sequencerIsSimulationMode();

  /// Set connected devices for the sequencer
  Future<void> sequencerSetDevices({
    String? cameraId,
    String? mountId,
    String? focuserId,
    String? filterwheelId,
    String? rotatorId,
    List<String>? filterNames,
    Map<String, int>? filterFocusOffsets,
  });

  /// Set the safety fail mode for the sequencer.
  /// Determines behavior when safety devices fail or are unavailable:
  /// - "fail_closed": Treat unavailable safety data as unsafe (enforced)
  /// - legacy aliases ("fail_open", "warn_only") are coerced to fail-closed
  Future<void> sequencerSetSafetyFailMode(String mode);

  /// Tell the executor whether quality problems it judges stop the run: the
  /// operator's "Stop the run for quality problems" setting (off by default).
  /// Off, guiding RMS over the limit, a Center or drift recenter that cannot
  /// solve, a StartGuiding calibration or RMS check, a dither that does not
  /// settle and the post-flip recenter and guiding checks notify and the run
  /// keeps imaging; on, each of them stops the run.
  Future<void> sequencerSetStopOnQualityProblems(bool stop);

  /// Tell the executor whether its standard Weather Unsafe and Dawn
  /// Approaching triggers may park the mount and close the cover and dome:
  /// the operator's "Park on unsafe weather" and "Park before dawn" settings.
  /// With one off the trigger still protects the data (unsafe weather stops
  /// the run exposing, dawn ends the run) without moving or closing anything.
  Future<void> sequencerSetParkPolicy({
    required bool parkOnUnsafeWeather,
    required bool parkBeforeDawn,
  });

  /// Tell the executor how many times to retry a failed camera exposure and a
  /// failed filter-wheel move before the failure counts: the operator's
  /// "Camera retries" and "Filter wheel retries" settings (0 to 10, 0 for a
  /// single attempt). Applies to the next attempt of a running sequence.
  Future<void> sequencerSetDeviceRetries({
    required int cameraRetries,
    required int filterWheelRetries,
  });

  /// Set the live safety/humidity polling interval for the sequencer.
  /// Valid backend values are 5..3600 seconds.
  Future<void> sequencerSetSafetyCheckIntervalSeconds(int seconds);

  /// Set the save path for sequencer images.
  /// This is the base directory where captured images will be saved.
  /// If null or empty, images will NOT be saved to disk.
  Future<void> sequencerSetSavePath(String? path);

  /// Replay Debug — stamp the active `sequence_runs.id` on the
  /// Rust executor so every subsequent emitted DecisionEvent carries
  /// it as `sequence_run_id`. Called immediately after the Dart side
  /// inserts the run row. Pass `null` (e.g. at run end / reset) to
  /// clear the slot.
  Future<void> sequencerSetActiveSequenceRunId(int? sequenceRunId);

  /// Replay Debug — runtime toggle for the decision-logging
  /// channel. When `false`, the Rust executor short-circuits all
  /// `DecisionEvent` emission (zero allocation, zero channel writes).
  /// Defaults to ON; the settings UI flips it via this method.
  Future<void> sequencerSetDecisionLoggingEnabled(bool enabled);

  /// Update dither configuration at runtime during sequence execution.
  /// Values are propagated to the Rust executor for use by subsequent operations.
  Future<void> sequencerUpdateDitherConfig({
    required double pixels,
    required double settlePixels,
    required double settleTime,
    required double settleTimeout,
    required bool raOnly,
  });

  /// Push the operator's meridian-flip settings onto the standard
  /// `meridian_flip` trigger.
  ///
  /// [configJson] is a serialised Rust `MeridianFlipConfig` — the same wire
  /// shape a `MeridianFlipNode` already sends inside the sequence JSON.
  ///
  /// Required because the Rust trigger is seeded with
  /// `MeridianFlipConfig::default()` and nothing else ever replaces it, so
  /// without this call the Settings → Meridian Flip panel has no effect on the
  /// trigger-driven flip.
  Future<void> sequencerUpdateMeridianFlipConfig(String configJson);

  /// Update observer location at runtime during sequence execution.
  /// Updates the executor's stored location for altitude-based trigger evaluation.
  Future<void> sequencerUpdateLocation({
    required double latitude,
    required double longitude,
  });

  /// Update filter focus offsets at runtime during sequence execution.
  /// Propagates new offsets to the executor for focus compensation.
  Future<void> sequencerUpdateFilterOffsets(Map<String, int> offsets);

  /// Stage per-target / per-filter carry-over integration so
  /// the next `sequencerStart()` seeds the IntegrationBudget tracker
  /// with frames already captured in prior sessions. The Dart
  /// `SequenceExecutor.start()` reads
  /// `sessionHandoffDecisionProvider(family)` per TargetHeader and
  /// calls this method with the resolved per-filter totals.
  ///
  /// Map shape: `target_id` -> { `filter_name` -> `seconds_captured` }.
  ///
  ///   * `Resume`      → populate the entry from
  ///                     `SessionCarryOver.perFilterIntegrationSecs`.
  ///   * `Restart`     → populate with an empty inner map (explicitly
  ///                     zeroes any pre-existing carry-over).
  ///   * `ContinueNew` → omit the target entirely (no carry-over, no
  ///                     zeroing).
  Future<void> sequencerUpdatePendingIntegrationCarryOver(
    Map<String, Map<String, double>> carryOver,
  );

  /// Update the standard `AutofocusInterval` trigger's
  /// `every_n_frames` cadence at runtime. The Rust default (25 frames) is
  /// the wrong order of magnitude for most subs, so this MUST be tunable.
  /// `everyNFrames` must be >= 1 (the bridge rejects 0).
  Future<void> sequencerUpdateAutofocusInterval(int everyNFrames);

  /// Push the operator's autofocus settings so trigger-fired refocus uses
  /// them instead of library defaults when the sequence has no Autofocus
  /// node. `configJson` is the same shape an Autofocus node carries.
  Future<void> sequencerUpdateAutofocusConfig(String configJson);

  /// Update the global default image-grading thresholds. When
  /// `enabled` is false, grading is disabled globally (per-node
  /// `quality_check` on TakeExposure still wins). Drives the FITS-time
  /// frame Pass/Reject gate.
  Future<void> sequencerUpdateDefaultQualityCheck({
    double? hfrThreshold,
    double? hfrBaselinePercent,
    double? eccentricityThreshold,
    int? starCountMin,
    required int maxConsecutiveRejects,
    required bool enabled,
  });

  /// Update the reject-folder override at runtime. `null` or
  /// empty string => fall back to `<save_path>/Reject/`.
  Future<void> sequencerUpdateRejectFolderPath(String? path);

  /// Push observer / equipment identification so subsequent FITS
  /// headers carry real OBSERVER, TELESCOP, FOCALLEN, APTDIA, INSTRUME,
  /// SITEELEV keywords. Every field is optional — null / empty values are
  /// omitted from FITS rather than emitted as sentinels.
  Future<void> sequencerUpdateObserverProfile({
    String? observerName,
    double? siteElevationM,
    String? cameraMake,
    String? cameraModel,
    String? telescopeName,
    double? telescopeFocalLengthMm,
    double? telescopeApertureMm,
  });

  /// Push the latest live sky-brightness reading
  /// (mag/arcsec²; bigger = darker) so the next TakeExposure burst's
  /// adaptive-exposure decision honours it. Pass `null` when the
  /// tracker has lost lock — the adapter falls back to nominal and
  /// emits a structured `Unavailable` reason.
  Future<void> sequencerUpdateSkyBrightness({required double? mag});

  /// Push the global default sky-brightness adaptive
  /// exposure config. Per-node overrides still win; this is the runtime
  /// fallback for TakeExposure nodes that don't carry their own block.
  Future<void> sequencerUpdateDefaultAdaptiveExposure({
    required bool enabled,
    required double targetSnr,
    required double referenceSkyBrightnessMag,
    required double minExposureSecs,
    required double maxExposureSecs,
    required Map<String, bool> perFilterEnabled,
    required Map<String, double> perFilterMinSecs,
    required Map<String, double> perFilterMaxSecs,
  });

  /// Disable the global default sky-brightness
  /// adaptive exposure config.
  Future<void> sequencerClearDefaultAdaptiveExposure();

  /// Push the latest cloud-motion analyzer output to the
  /// Rust sequencer. Drives the `CloudArrivingIn`, `CloudOpeningIn`, and
  /// `CloudCoverThreshold` triggers. All fields are optional; `null`
  /// values disable the corresponding evaluator branch rather than
  /// firing on a default.
  ///
  /// `predictedClearSkyAlt` / `predictedClearSkyAz` must be either both
  /// set or both null; a half-specified direction is logged at WARN and
  /// treated as "no direction reported".
  Future<void> sequencerUpdateCloudMotion({
    double? currentCoverPercent,
    double? predictedArrivalMinutes,
    double? predictedOpeningMinutes,
    double? predictedOpeningDurationSecs,
    double? predictedClearSkyAlt,
    double? predictedClearSkyAz,
  });

  /// Full-night audit 2026-06-04 (defense-in-depth) — push the Dart-side
  /// weather-safety verdict into the Rust executor so the in-sequencer
  /// `WeatherUnsafe` trigger reacts even on rigs without a hardware safety
  /// device. The hardware `safety_is_safe` poll knows nothing about the
  /// user's configured thresholds + API/cloud sources that
  /// `weatherSafetyProvider` evaluates; this carries that overall verdict as
  /// an additional unsafe source (folded OR-of-unsafe — never makes the rig
  /// less safe than the hardware reading).
  ///
  /// `unsafeOverride == true` => Dart computed UNSAFE; `false` => Dart
  /// computed SAFE; `null` => Dart abstains (provider disabled / no data) and
  /// this layer stays inert.
  Future<void> sequencerUpdateWeatherVerdict({bool? unsafeOverride});

  /// JSON-serialised snapshot of the latest cloud-motion
  /// reading for the run dashboard. Returns `null` until the first push
  /// has been received. The shape mirrors the `CloudMotionSnapshot` Rust
  /// struct with `last_update_secs_ago` instead of the raw monotonic
  /// `Instant`.
  Future<String?> sequencerGetCloudMotionJson();

  /// Push the latest composite sky-conditions score to the
  /// running executor. `null` clears the slot so the target scheduler
  /// knows telemetry is missing instead of receiving a fabricated score.
  @override
  Future<void> sequencerUpdateConditionsScore(ConditionsScore? score);

  /// Snapshot of the adaptive target-swap state for the Run
  /// Dashboard. Returns `null` until the first conditions score has been
  /// pushed.
  @override
  Future<AdaptiveSwapSnapshot?> sequencerGetAdaptiveSwapSnapshot();

  // Recovery mode

  /// Operator pressed "Try Now" on the Run Dashboard banner — fires the
  /// next recovery attempt immediately (skipping the wait timer). No-op
  /// when the executor is not currently in `Recovering`.
  Future<void> recoveryTryNow();

  /// Operator pressed "Abort" on the Run Dashboard banner — exits the
  /// recovery loop and transitions the executor to `Failed`. No-op when
  /// the executor is not currently in `Recovering`.
  Future<void> recoveryAbort();

  /// Push updated recovery defaults (retry interval, max duration,
  /// stop-tracking flag, abort-on-meridian flag, audible-alert flag, and
  /// whether an exhausted recovery may park and close up) into the executor's
  /// runtime config. The next recovery entry uses these values.
  Future<void> updateRecoveryConfig({
    required double retryIntervalSecs,
    required double maxDurationSecs,
    required bool stopTrackingDuringRecovery,
    required bool abortOnMeridian,
    required bool audibleAlertWhenEntered,
    required bool parkAndCloseWhenRecoveryGivesUp,
  });

  /// Snapshot of the current in-flight recovery context. Returns `null`
  /// when the executor is not in `Recovering`. Wire format is the
  /// JSON-serialised Rust `RecoveryContext`.
  Future<String?> getCurrentRecoveryJson();

  /// Dump of every completed recovery loop since the executor was
  /// constructed. Returned as a JSON array of `RecoveryHistoryEntry`
  /// records.
  Future<String> getRecoveryHistoryJson();

  // Checkpoint / Crash Recovery

  /// Set the directory for checkpoint files
  Future<void> sequencerSetCheckpointDir(String path);

  /// Check if a recoverable checkpoint exists
  Future<bool> hasCheckpoint();

  /// Get information about the current checkpoint
  Future<CheckpointInfo?> getCheckpointInfo();

  /// Resume sequence from checkpoint
  Future<void> resumeFromCheckpoint();

  /// Discard the current checkpoint
  Future<void> discardCheckpoint();

  /// Save a checkpoint of current execution state
  Future<void> saveCheckpoint();

  /// Standalone meridian flip via the canonical native flip engine,
  /// outside any running sequence. The native side refuses while the
  /// sequencer is running (the in-sequence trigger owns flips there).
  Future<void> performMeridianFlip({
    required String mountId,
    String? cameraId,
    String? focuserId,
    String? coverCalibratorId,
    required String targetName,
    required double targetRaHours,
    required double targetDecDegrees,
    required bool pauseGuiding,
    required bool autoCenter,
    required bool refocusAfter,
    required bool resumeGuiding,
    required double settleTimeSecs,
  });
}
