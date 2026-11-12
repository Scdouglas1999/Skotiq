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
///   * The executor's run configuration (one value, every operator setting a
///     run reads), its wiring (simulation mode, devices, save path, sequence
///     run id), the next start's carry-over integration, and the live feeds:
///     sky brightness, cloud motion, weather verdict, conditions score,
///     adaptive swap snapshot.
///   * Recovery loop: try-now, abort, current snapshot, history.
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
  Future<void> sequencerStart();

  /// Stop the sequencer
  /// `origin` names the caller — `null`/`'operator'` for a human,
  /// `'scheduler'` for the autopilot.
  Future<void> sequencerStop({String? origin});

  Future<void> sequencerPause();

  Future<void> sequencerResume();

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

  Future<void> sequencerReset();

  /// Load a sequence definition (JSON) into the sequencer
  Future<void> sequencerLoadJson(String json);

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

  Future<void> sequencerSetDevices({
    String? cameraId,
    String? mountId,
    String? focuserId,
    String? filterwheelId,
    String? rotatorId,
    List<String>? filterNames,
  });

  /// Replace the executor's run configuration: [runConfigJson] is a whole
  /// native `RunConfig` as JSON, built from the operator's settings by
  /// `RunConfigSync`, the one sender. Throws with the executor's reason when
  /// it refuses the value; nothing changes then. Only the host that runs the
  /// rig has an executor to configure: a linked client throws.
  Future<void> sequencerApplyRunConfig(String runConfigJson);

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

  /// Push the latest live sky-brightness reading
  /// (mag/arcsec²; bigger = darker) so the next TakeExposure burst's
  /// adaptive-exposure decision honours it. Pass `null` when the
  /// tracker has lost lock — the adapter falls back to nominal and
  /// emits a structured `Unavailable` reason.
  Future<void> sequencerUpdateSkyBrightness({required double? mag});

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
  /// this layer stays inert. [advisory] marks an UNSAFE verdict that rests
  /// only on a forecast or cloud model: it holds the run until the sky clears
  /// and never parks the mount or ends the run.
  Future<void> sequencerUpdateWeatherVerdict({
    bool? unsafeOverride,
    bool advisory = false,
  });

  /// The operator says the sky is clear: for [durationSecs] the app's weather
  /// verdict is not acted on and a run held for weather resumes at once. `0`
  /// ends the override. A hardware safety monitor that reads unsafe still
  /// holds the run. [reason] is recorded with the operator action.
  Future<void> sequencerSetWeatherOperatorClear({
    required int durationSecs,
    required String reason,
  });

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

  /// Operator pressed "Try Now" on the Run Dashboard banner — fires the
  /// next recovery attempt immediately (skipping the wait timer). No-op
  /// when the executor is not currently in `Recovering`.
  Future<void> recoveryTryNow();

  /// Operator pressed "Abort" on the Run Dashboard banner — exits the
  /// recovery loop and transitions the executor to `Failed`. No-op when
  /// the executor is not currently in `Recovering`.
  Future<void> recoveryAbort();

  /// Snapshot of the current in-flight recovery context. Returns `null`
  /// when the executor is not in `Recovering`. Wire format is the
  /// JSON-serialised Rust `RecoveryContext`.
  Future<String?> getCurrentRecoveryJson();

  /// Dump of every completed recovery loop since the executor was
  /// constructed. Returned as a JSON array of `RecoveryHistoryEntry`
  /// records.
  Future<String> getRecoveryHistoryJson();

  Future<void> sequencerSetCheckpointDir(String path);

  Future<bool> hasCheckpoint();

  Future<CheckpointInfo?> getCheckpointInfo();

  Future<void> resumeFromCheckpoint();

  Future<void> discardCheckpoint();

  Future<void> saveCheckpoint();

  /// Ask the RUNNING sequence to flip at its next safe point, through its own
  /// meridian trigger (wait for the frame in flight, stop guiding, flip,
  /// re-center, restart guiding, settle). Completes once the request is
  /// queued; the flip's outcome arrives as the usual meridian-flip event.
  /// Throws with the native reason when the flip cannot run now, e.g. the
  /// target has not crossed the meridian or the mount is parked.
  Future<void> sequencerRequestMeridianFlip();

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
