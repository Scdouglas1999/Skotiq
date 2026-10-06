// `@JsonSerializable(...)` and `@JsonKey(...)` are attached to the freezed
// redirecting factory constructors / their parameters below. freezed copies
// those decorators verbatim onto the generated concrete `class` (where they
// are valid) — see `freezed/lib/src/templates/concrete_template.dart`, which
// joins `constructor.decorators` directly above the emitted class. There is no
// other channel to pass per-class json_serializable options such as
// `fieldRename`, `explicitToJson`, and `includeIfNull`: the `@Freezed`
// annotation does not expose them (freezed_annotation 2.4.x), and a global
// `build.yaml` `field_rename` would also rewrite the camelCase models in this
// same file that intentionally keep their Dart key names. The analyzer reports
// these required-on-the-constructor annotations as `invalid_annotation_target`
// because json_annotation's `@Target` is `classType` / field-or-getter only;
// freezed's own generated output silences the identical false positive with
// this exact directive.
// ignore_for_file: invalid_annotation_target
import 'package:equatable/equatable.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:nightshade_planetarium/nightshade_planetarium.dart'
    show ScoringWeights;
import 'package:uuid/uuid.dart';
import '../imaging/imaging_models.dart' show FrameType;
import '../notification/notification_categories.dart'
    show NotificationTransportKind;
import '../meridian_flip_settings.dart'
    show MeridianTriggerMethod, FlipFailureAction;
export '../meridian_flip_settings.dart'
    show MeridianTriggerMethod, FlipFailureAction;
import '../../backend/nightshade_backend.dart' show DeviceType;
import '../../services/scheduler/horizon_profile.dart' show HorizonProfile;
import '_json_converters.dart';
import 'instruction_progress_detail.dart';
import 'sequence_tree_index.dart';
export 'sequence_tree_index.dart' show SequenceTreeIndex;

part 'sequence_models.freezed.dart';
part 'sequence_models.g.dart';
part 'sequence_models/advanced_nodes/cover_calibrator_nodes.dart';
part 'sequence_models/advanced_nodes/adaptive_swap_models.dart';
part 'sequence_models/advanced_nodes/target_scheduler_node.dart';
part 'sequence_models/advanced_nodes/smart_exposure_node.dart';
part 'sequence_models/advanced_nodes/live_stacking_node.dart';
part 'sequence_models/container_nodes/integration_budget_and_target_triggers.dart';
part 'sequence_models/container_nodes/target_header_node.dart';
part 'sequence_models/container_nodes/simple_logic_nodes.dart';
part 'sequence_models/container_nodes/recovery_node.dart';
part 'sequence_models/container_nodes/instruction_set_node.dart';
part 'sequence_models/instruction_nodes/capture_and_guiding.dart';
part 'sequence_models/instruction_nodes/equipment_timing_and_automation.dart';
part 'sequence_models/instruction_nodes/alignment_and_dome.dart';
part 'sequence_models/science_and_plugin_nodes.dart';
part 'sequence_models/sequence_state.dart';
part 'sequence_models/sequence_sky_requirement.dart';

/// Sequence execution state
///
/// `recovering` is the visible recovery-mode state. Mirrors the Rust
/// `ExecutorState::Recovering` variant — the Run Dashboard renders a
/// pulsing red LED, the persistent recovery banner with cause + attempt
/// counter + countdown, and the Try Now / Abort controls when this fires.
enum SequenceExecutionState {
  idle,
  running,
  paused,
  stopping,
  completed,
  failed,
  recovering,

  /// The native stop command FAILED. The hardware was NOT confirmed stopped
  /// and may still be imaging, so this is a live, controllable state — never a
  /// terminal one. Run/session identity, timers, watchdogs and the native
  /// event subscription are all retained; Stop is re-enabled for a retry and
  /// Start is blocked. A later authoritative native Stopped / Completed /
  /// Failed event confirms termination and drives the real teardown.
  stopFailed,

  /// The native stop succeeded (the hardware is safe) but persistence cleanup —
  /// finalizing the run row and ending the durable session — FAILED. Run/
  /// session identity is retained so a Stop retry can re-run the cleanup; Start
  /// is blocked until it completes (a fresh run would collide with the dangling
  /// session). Not terminal.
  cleanupFailed,

  /// A nonterminal, busy finalization phase entered SYNCHRONOUSLY the instant a
  /// natural terminal event (Completed / Failed / Stopped and their aliases) —
  /// or an authoritative native terminal confirming a previously-failed stop —
  /// claims teardown, held until the durable run/session cleanup succeeds.
  ///
  /// The hardware has already terminated authoritatively (a natural terminal is
  /// authoritative; there is nothing left to stop), so this state owns NO
  /// hardware and deliberately offers NO native Stop during pure persistence
  /// finalization. It IS busy: start / resume / reset are blocked, so a rapid
  /// Start cannot begin a new run whose identity an old cleanup could then
  /// clobber. Only once cleanup succeeds does the executor publish the settled
  /// `completed` / `failed` / `idle` state and the one-shot terminal-run result.
  /// If cleanup fails it moves to the retryable [cleanupFailed] (which DOES
  /// re-offer Stop), never back to a settled state.
  finalizing,
}

/// Centralized run-control capabilities for [SequenceExecutionState].
///
/// Every playback surface — desktop toolbar, mobile playback bar, dashboard
/// cockpit, the app-shell mini bar, the mobile sequencer tab — must agree on
/// which buttons are live in each state. Before this extension each surface
/// re-derived that from ad-hoc `state == running || state == paused` checks and
/// they drifted: completed/failed surfaced a dead Pause button (or a silent
/// no-op Start), and a failed native stop hid the Stop-retry affordance.
/// Route every surface through these getters instead of open-coding the set.
extension SequenceExecutionStateCapabilities on SequenceExecutionState {
  /// A settled state a fresh run may start from. `stopFailed` / `cleanupFailed`
  /// are deliberately excluded: the prior run's stop (or its persistence
  /// cleanup) has not finished, so a new run would collide with live hardware
  /// or a dangling session.
  bool get canStart => switch (this) {
    SequenceExecutionState.idle ||
    SequenceExecutionState.completed ||
    SequenceExecutionState.failed => true,
    SequenceExecutionState.running ||
    SequenceExecutionState.paused ||
    SequenceExecutionState.stopping ||
    SequenceExecutionState.recovering ||
    SequenceExecutionState.stopFailed ||
    SequenceExecutionState.cleanupFailed ||
    SequenceExecutionState.finalizing => false,
  };

  /// A settled state that is safe to reset from (same set as [canStart]).
  bool get canReset => canStart;

  /// Stop is a meaningful action — either an initial stop or a retry of a
  /// failed stop / failed cleanup. False for the settled non-active states
  /// (the idle-stop guard) AND for `finalizing`: the hardware has already
  /// terminated authoritatively, so there is nothing to stop during pure
  /// persistence finalization (a cleanup FAILURE re-offers Stop via the
  /// separate [cleanupFailed] state).
  bool get canStop => switch (this) {
    SequenceExecutionState.running ||
    SequenceExecutionState.paused ||
    SequenceExecutionState.recovering ||
    SequenceExecutionState.stopping ||
    SequenceExecutionState.stopFailed ||
    SequenceExecutionState.cleanupFailed => true,
    SequenceExecutionState.idle ||
    SequenceExecutionState.completed ||
    SequenceExecutionState.failed ||
    SequenceExecutionState.finalizing => false,
  };

  /// Pause is meaningful only while the run is actively executing.
  bool get canPause => this == SequenceExecutionState.running;

  /// Resume is meaningful only from a paused run.
  bool get canResume => this == SequenceExecutionState.paused;

  /// Skip / skip-to-node only make sense while the run is live or paused.
  bool get canSkip =>
      this == SequenceExecutionState.running ||
      this == SequenceExecutionState.paused;

  /// The native executor / hardware may still be imaging. True for every live
  /// state AND for `stopFailed` (a failed stop command means the hardware was
  /// NOT confirmed stopped). False for `cleanupFailed` (native stop confirmed;
  /// only persistence remains).
  bool get ownsHardware => switch (this) {
    SequenceExecutionState.running ||
    SequenceExecutionState.paused ||
    SequenceExecutionState.stopping ||
    SequenceExecutionState.recovering ||
    SequenceExecutionState.stopFailed => true,
    SequenceExecutionState.idle ||
    SequenceExecutionState.completed ||
    SequenceExecutionState.failed ||
    SequenceExecutionState.cleanupFailed ||
    SequenceExecutionState.finalizing => false,
  };

  /// A run is in progress or in a non-idle lifecycle phase (live, tearing
  /// down, recovering, or awaiting a stop/cleanup retry). The inverse of
  /// [canStart]; drives "show the run controls / hide the Start button" logic.
  bool get isBusy => !canStart;

  /// A settled state (idle / completed / failed). Convenience inverse of
  /// [isBusy]; equal to [canStart].
  bool get isSettled => canStart;

  /// The run needs operator attention — a failure surface the UI should call
  /// out (failed, recovering, or a failed stop / cleanup awaiting retry).
  bool get needsAttention => switch (this) {
    SequenceExecutionState.failed ||
    SequenceExecutionState.recovering ||
    SequenceExecutionState.stopFailed ||
    SequenceExecutionState.cleanupFailed => true,
    SequenceExecutionState.idle ||
    SequenceExecutionState.running ||
    SequenceExecutionState.paused ||
    SequenceExecutionState.stopping ||
    SequenceExecutionState.finalizing ||
    SequenceExecutionState.completed => false,
  };
}

/// Node execution status
enum NodeStatus { pending, running, success, failure, skipped, cancelled }

// FrameType is imported from imaging_models.dart

/// Binning options
enum BinningMode { one, two, three, four }

extension BinningModeExtension on BinningMode {
  String get label {
    switch (this) {
      case BinningMode.one:
        return '1x1';
      case BinningMode.two:
        return '2x2';
      case BinningMode.three:
        return '3x3';
      case BinningMode.four:
        return '4x4';
    }
  }
}

/// Autofocus method
enum AutofocusMethod { vCurve, hyperbolic, quadratic }

/// Loop condition type
enum LoopConditionType {
  count,
  untilTime,
  untilAltitude,

  /// Loop until altitude is above threshold (condition_value = altitude degrees).
  /// Note: untilAltitude means "below", altitudeAbove means "above".
  altitudeAbove,

  /// Loop until accumulated integration time reaches threshold (condition_value = seconds)
  integrationTime,
  forever,
  whileDark,
}

/// Configurable per-operation overhead estimates for realistic time estimation.
/// These values represent typical real-world durations for each operation
/// beyond the raw integration time.
@freezed
abstract class SequenceOverheadConfig with _$SequenceOverheadConfig {
  const factory SequenceOverheadConfig({
    /// Time for a slew operation (seconds)
    @Default(30.0) double slewSecs,

    /// Time for an autofocus run (seconds)
    @Default(180.0) double autofocusSecs,

    /// Time for a filter wheel change (seconds)
    @Default(10.0) double filterChangeSecs,

    /// Time for a dither + settle cycle (seconds)
    @Default(15.0) double ditherSecs,

    /// Time for a meridian flip including re-centering (seconds)
    @Default(300.0) double meridianFlipSecs,

    /// Time for guide acquisition and settle (seconds)
    @Default(30.0) double guideAcquireSecs,

    /// Time for a plate solve (seconds)
    @Default(15.0) double plateSolveSecs,

    /// Time for camera cool-down (seconds)
    @Default(600.0) double coolingSecs,

    /// Time for camera warm-up (seconds)
    @Default(300.0) double warmingSecs,

    /// Per-exposure download overhead (seconds)
    @Default(3.0) double downloadOverheadPerExposureSecs,

    /// Time for cover calibrator open/close (seconds)
    @Default(30.0) double coverMoveSecs,

    /// Time for center target operation (plate solve + slew iterations) (seconds)
    @Default(45.0) double centerTargetSecs,
  }) = _SequenceOverheadConfig;
}

/// Result of sequence integration time estimation
@freezed
abstract class SequenceEstimate with _$SequenceEstimate {
  const SequenceEstimate._();

  const factory SequenceEstimate({
    /// Estimated total integration time in seconds (pure shutter-open time)
    required double estimatedSecs,

    /// Estimated total overhead time in seconds (slews, AF, dithers, etc.)
    @Default(0.0) double overheadSecs,

    /// Time for a single iteration (useful for unbounded loops)
    required double singleIterationSecs,

    /// Whether the sequence contains unbounded loops (forever, whileDark, etc.)
    required bool isUnbounded,

    /// For untilTime loops, the target end time
    DateTime? untilTime,

    /// For unbounded loops, the condition type
    LoopConditionType? conditionType,
  }) = _SequenceEstimate;

  /// Total estimated wall-clock time (integration + overhead)
  double get totalEstimatedSecs => estimatedSecs + overheadSecs;

  /// Format the estimate as a human-readable string
  String format() {
    if (isUnbounded) {
      final iterationMins = (singleIterationSecs / 60).round();
      return '${iterationMins}m/iter (unbounded)';
    }
    final hours = (estimatedSecs / 3600).floor();
    final mins = ((estimatedSecs % 3600) / 60).round();
    if (hours > 0) {
      return '${hours}h ${mins}m';
    }
    return '${mins}m';
  }

  /// Format with overhead-aware total time display
  /// Returns "Integration: 6h 30m | Est. total: ~9h 15m"
  String formatWithOverhead() {
    final integrationStr = format();
    if (overheadSecs <= 0 || isUnbounded) {
      return integrationStr;
    }
    final totalSecs = totalEstimatedSecs;
    final totalHours = (totalSecs / 3600).floor();
    final totalMins = ((totalSecs % 3600) / 60).round();
    String totalStr;
    if (totalHours > 0) {
      totalStr = '~${totalHours}h ${totalMins}m';
    } else {
      totalStr = '~${totalMins}m';
    }
    return 'Integration: $integrationStr | Est. total: $totalStr';
  }
}

/// Conditional check type
enum ConditionalType {
  always,
  altitudeAbove,
  timeAfter,
  guidingRmsBelow,
  hfrBelow,
  weatherSafe,
  moonSeparationAbove,
  safetyMonitorSafe,
}

/// Recovery action type
enum RecoveryActionType {
  continueExecution,
  pause,
  autofocus,
  nextTarget,
  retry,
  parkAndAbort,
  customBranch,
  // Cloud-motion-aware recovery actions. `pauseAndWaitForClear`
  // promotes the pause to a RecoveryCause: :WeatherUnsafe so the
  // dashboard banner / audible alert fire; `slewToGapAndContinue` re-points
  // the mount to a clear-sky direction reported by the analyzer.
  pauseAndWaitForClear,
  slewToGapAndContinue,
  // Science — transparency-adaptive recovery. Paired with
  // [TriggerType.transparencyDropped]. Consults the operator's
  // pre-configured backup plan (backup filter and/or backup target id)
  // and either swaps the filter, skips to the backup target, or both.
  switchTargetOrFilter,
  // Tell the operator and keep imaging: once per episode on a trigger, and
  // after the retries on a node whose steps keep failing. What a quality
  // trigger gets in the editor (see [RecoveryNode.withTriggerType]); owner
  // decision 2026-10-06: only a risk to the hardware stops a run by itself.
  notify,
}

/// Trigger type.
///
/// Mirrors the Rust `TriggerType` enum in
/// `native/nightshade_native/sequencer/src/lib.rs`. Adding a new variant here
/// REQUIRES extending [`SequenceExecutor._nodeToConfig`]'s RecoveryNode
/// serializer so the trigger config round-trips to Rust correctly. The
/// This set fills in the long-standing gap where the Rust side
/// had 17 trigger variants but Dart only modelled 8.
enum TriggerType {
  hfrDegraded,
  meridianFlip,
  guidingFailed,
  altitudeLimit,
  weatherUnsafe,
  temperatureShift,
  filterChange,
  dawnApproaching,
  // Config payload fields are stored in the
  // dedicated columns on [`RecoveryNode`] (triggerThreshold for single-double
  // payloads; the FocusDrift-specific window/count/increase fields are
  // dedicated). Trigger types that take no payload (mountTrackingLost,
  // domeShutterNotOpen, guideStarLost) read no config.
  humidityThreshold,
  focusDrift,
  mountTrackingLost,
  domeShutterNotOpen,
  guideStarLost,
  autofocusInterval,
  ditherInterval,
  driftLimit,
  // Cloud-motion-aware triggers backed by the live
  // CloudMotionAnalyzer. The runtime sample data is pushed from Dart via
  // `backend.sequencerUpdateCloudMotion` on a ~60s cadence; the trigger
  // config payloads are stored on [`RecoveryNode`] in the dedicated
  // cloud* fields below.
  cloudArrivingIn,
  cloudOpeningIn,
  cloudCoverThreshold,
  // Science — transparency-adaptive trigger backed by the live
  // sky transparency sampler. The runtime sample data is pushed from
  // the Dart science pipeline via `backend.sequencerUpdateTransparency`.
  // Paired with [RecoveryActionType.switchTargetOrFilter] for the
  // "swap from faint RGB target to a brighter Lum backup when the sky
  // goes hazy" workflow.
  transparencyDropped,
}

/// Notification level
enum NotificationLevel { info, warning, error, success }

/// Twilight type
enum TwilightType { civil, nautical, astronomical }

/// Base class for all sequence nodes.
///
/// Sealed for exhaustive switch matching: every `switch (node)` statement
/// must cover all 37 subtypes (or use a `_` wildcard) — adding a new node
/// type will produce compile-time errors at every dispatch site that
/// hasn't been updated.
///
/// All subclasses are declared in this same library, which is the
/// requirement for sealed types.
sealed class SequenceNode extends Equatable {
  final String id;
  final String name;
  final bool isEnabled;
  final List<String> childIds;
  final String? parentId;
  final int orderIndex;

  /// Optional user comment/annotation for this node
  final String? comment;

  SequenceNode({
    String? id,
    required this.name,
    this.isEnabled = true,
    this.childIds = const [],
    this.parentId,
    this.orderIndex = 0,
    this.comment,
  }) : id = id ?? const Uuid().v4();

  /// Get the node type identifier
  String get nodeType;

  /// Get the icon name for this node
  String get iconName;

  /// Get the color category for this node
  NodeCategory get category;

  /// Device types required by this node to execute.
  /// Override in subclasses that need specific hardware.
  Set<DeviceType> get requiredDevices => {};

  /// Create a copy with updated values
  SequenceNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
  });

  @override
  List<Object?> get props => [
    id,
    name,
    isEnabled,
    childIds,
    parentId,
    orderIndex,
    comment,
  ];
}

/// Node category for coloring
enum NodeCategory { instruction, trigger, logic, target }

// Mosaic panel info

/// Information about a mosaic panel for multi-panel imaging
@Freezed(fromJson: true, toJson: true)
abstract class MosaicPanelInfo with _$MosaicPanelInfo {
  const MosaicPanelInfo._();

  @JsonSerializable(fieldRename: FieldRename.snake)
  const factory MosaicPanelInfo({
    required String mosaicName,
    required int panelIndex,
    required int totalPanels,
    required int row,
    required int column,
  }) = _MosaicPanelInfo;

  String get displayLabel => 'Panel ${panelIndex + 1}/$totalPanels';

  factory MosaicPanelInfo.fromJson(Map<String, dynamic> json) =>
      _$MosaicPanelInfoFromJson(json);
}
