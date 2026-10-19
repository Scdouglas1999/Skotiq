// The manual-action contract that P2 implements.
part of '../night_control_contracts.dart';

// ---------------------------------------------------------------------------
// Manual actions (P2)
// ---------------------------------------------------------------------------

/// One action-bar button.
@immutable
class ManualActionVm {
  const ManualActionVm({
    required this.id,
    required this.label,
    required this.enabled,
    this.sub,
    this.disabledReason,
    this.running = false,
  });

  final ManualActionId id;

  /// "Snapshot", "Flip now", "Stop loop".
  final NightText label;

  /// The small second line ("5 s", "Ha", "M74", "running"). Hidden when the
  /// center column is narrower than `NightControlDensity.hideActionSubLabels`
  /// allows.
  final NightText? sub;

  final bool enabled;

  /// Required when [enabled] is false: tooltip and semantics hint.
  final NightText? disabledReason;

  /// This action is the one in flight (warning tint on the boards).
  final bool running;

  @override
  bool operator ==(Object other) =>
      other is ManualActionVm &&
      other.id == id &&
      other.label == label &&
      other.sub == sub &&
      other.enabled == enabled &&
      other.disabledReason == disabledReason &&
      other.running == running;

  @override
  int get hashCode =>
      Object.hash(id, label, sub, enabled, disabledReason, running);
}

/// The steps a manual action goes through (plan section 3, RunPauseGuard).
enum ManualActionPhase {
  idle,

  /// Pause requested; the in-flight exposure is still running.
  pausingRun,

  /// Run paused, waiting for the camera to go idle.
  waitingForFrame,

  running,

  /// The action finished and the run is being resumed.
  resuming,
}

/// The action controller's state.
@immutable
class ManualActionState {
  const ManualActionState({
    required this.phase,
    this.active,
    this.startedRunPause = false,
    this.waitingForFrame,
    this.exposureRemaining,
    this.message,
    this.error,
    this.runLeftPaused = false,
    this.lastSolveDuration,
  });

  static const ManualActionState idle =
      ManualActionState(phase: ManualActionPhase.idle);

  final ManualActionPhase phase;

  /// The action in flight; null when idle.
  final ManualActionId? active;

  /// True when this controller paused the run and so owes the resume.
  final bool startedRunPause;

  /// "Pausing after #44 · 108 s": the frame being waited for and its
  /// remaining exposure.
  final int? waitingForFrame;
  final Duration? exposureRemaining;

  /// Progress copy ("Stop loop to resume").
  final NightText? message;

  /// The last failure, kept until the next action starts.
  final NightText? error;

  /// The resume after an action failed; the run stays paused and visible.
  /// Never stopped, never parked.
  final bool runLeftPaused;

  /// How long the last plate solve took, for the Solve tab.
  final Duration? lastSolveDuration;

  bool get isBusy => phase != ManualActionPhase.idle;

  @override
  bool operator ==(Object other) =>
      other is ManualActionState &&
      other.phase == phase &&
      other.active == active &&
      other.startedRunPause == startedRunPause &&
      other.waitingForFrame == waitingForFrame &&
      other.exposureRemaining == exposureRemaining &&
      other.message == message &&
      other.error == error &&
      other.runLeftPaused == runLeftPaused &&
      other.lastSolveDuration == lastSolveDuration;

  @override
  int get hashCode => Object.hash(
        phase,
        active,
        startedRunPause,
        waitingForFrame,
        exposureRemaining,
        message,
        error,
        runLeftPaused,
        lastSolveDuration,
      );
}

/// What the screen can ask of the rig outside the sequence's own steps.
///
/// P2 implements it (a Riverpod Notifier behind `nightActionApiProvider`).
/// The contract every implementation keeps:
///  * methods never throw to the UI; a failure lands in
///    [ManualActionState.error] and the log;
///  * one action at a time. Calling the in-flight action again returns the
///    same future; calling a different one while busy returns at once and
///    changes nothing;
///  * a running sequence is paused first and resumed afterwards only when
///    this controller paused it ([ManualActionState.startedRunPause]). A
///    failed resume leaves the run paused. Nothing here stops a run or parks
///    the mount;
///  * an action that is disabled for the current state (see
///    [ManualActionVm.disabledReason]) returns at once and changes nothing.
abstract interface class NightActionApi {
  /// The current state; the same value `nightActionStateProvider` exposes.
  ManualActionState get state;

  /// Dispatches to the method for [id].
  Future<void> run(ManualActionId id);

  /// One short frame with the manual exposure settings; not saved to the
  /// session.
  Future<void> snapshot();

  /// Starts looping, or stops a running loop. During a run the loop holds
  /// the run paused ([NightRunPhase.pausedForAction]) until it stops.
  Future<void> toggleLoop();

  Future<void> autofocus();

  /// Solves the last frame taken at the current pointing, or a short new
  /// one, then syncs the mount.
  Future<void> solveAndSync();

  /// Slew and center on the active target, stopping guiding before the slew
  /// and restarting it (settled) before the run resumes.
  Future<void> center();

  /// Dithers through PHD2 and waits for settle.
  Future<void> dither();

  /// Standalone meridian flip; disabled while a run is loaded, because the
  /// run's meridian trigger owns flips.
  Future<void> flipNow();

  /// Sidereal tracking on, or tracking off. No run active only.
  Future<void> toggleTracking();

  /// Cooler on to the profile setpoint, or off. No run active only.
  Future<void> toggleCooler();

  /// Cancels the in-flight action, then resumes the run if this controller
  /// paused it.
  Future<void> cancel();

  /// When an armed "Start at dark" fires; null when not armed. The same
  /// value as [NightHeaderVm.armedStartAt].
  DateTime? get armedStartAt;

  /// Arms the run to start at tonight's astronomical dark. Held in this app
  /// process only: it does not survive a restart and does not reach a
  /// headless host, and the UI says so.
  Future<void> armStartAtDark();

  void cancelArmedStart();
}
