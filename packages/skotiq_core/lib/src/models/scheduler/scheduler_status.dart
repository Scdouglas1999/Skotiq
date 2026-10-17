import 'package:equatable/equatable.dart';

/// Lifecycle state of the dynamic scheduler.
enum SchedulerState {
  /// Engine is configured but not currently picking targets. Idle is the
  /// default; it lets the operator preview decisions without committing.
  idle,

  /// Engine is actively picking and handing targets to the sequencer.
  running,

  /// Engine is paused; sequencer is not advanced when ticks fire, but
  /// state is preserved so a `resume()` continues seamlessly.
  paused,
}

/// Configurable weights applied to each scoring factor.
///
/// All weights are >= 0. The normalized factor itself is always [0, 1]; the
/// weight scales the contribution, so doubling one weight doubles that
/// factor's influence relative to others.
class SchedulerWeights extends Equatable {
  final double altitude;
  final double meridian;
  final double moon;
  final double timeRemaining;
  final double filterCoverage;
  final double userPriority;

  const SchedulerWeights({
    this.altitude = 1.0,
    this.meridian = 1.0,
    this.moon = 1.0,
    this.timeRemaining = 0.75,
    this.filterCoverage = 1.25,
    this.userPriority = 1.0,
  });

  /// Default set of weights used when the operator has not customized them.
  /// Filter-coverage is intentionally weighted slightly higher so the
  /// scheduler prefers targets that still need data — the whole point of
  /// the integration-goal system.
  static const SchedulerWeights defaults = SchedulerWeights();

  SchedulerWeights copyWith({
    double? altitude,
    double? meridian,
    double? moon,
    double? timeRemaining,
    double? filterCoverage,
    double? userPriority,
  }) {
    return SchedulerWeights(
      altitude: altitude ?? this.altitude,
      meridian: meridian ?? this.meridian,
      moon: moon ?? this.moon,
      timeRemaining: timeRemaining ?? this.timeRemaining,
      filterCoverage: filterCoverage ?? this.filterCoverage,
      userPriority: userPriority ?? this.userPriority,
    );
  }

  /// Serialize to a JSON-safe map for durable storage.
  Map<String, Object?> toStorageJson() => {
    'altitude': altitude,
    'meridian': meridian,
    'moon': moon,
    'timeRemaining': timeRemaining,
    'filterCoverage': filterCoverage,
    'userPriority': userPriority,
  };

  /// Rebuild from [toStorageJson], falling back to the default for any missing
  /// or non-numeric field.
  factory SchedulerWeights.fromStorageJson(Map<String, dynamic> json) {
    return SchedulerWeights.defaults.copyWith(
      altitude: (json['altitude'] as num?)?.toDouble(),
      meridian: (json['meridian'] as num?)?.toDouble(),
      moon: (json['moon'] as num?)?.toDouble(),
      timeRemaining: (json['timeRemaining'] as num?)?.toDouble(),
      filterCoverage: (json['filterCoverage'] as num?)?.toDouble(),
      userPriority: (json['userPriority'] as num?)?.toDouble(),
    );
  }

  @override
  List<Object?> get props => [
    altitude,
    meridian,
    moon,
    timeRemaining,
    filterCoverage,
    userPriority,
  ];
}

/// Runtime configuration controlling the engine's tick behavior.
class SchedulerConfig extends Equatable {
  /// Period between automatic re-evaluations.
  final Duration tickInterval;

  /// Minimum ratio by which a challenger's score must exceed the current
  /// target's score before the engine will switch. 1.20 means challenger
  /// must be 20% better. Must be >= 1.0; 1.0 disables hysteresis.
  final double hysteresisRatio;

  /// Minimum altitude (degrees) below which a target's altitude factor
  /// drops to 0 regardless of dec/latitude. Operator-tunable for site
  /// horizon limitations not captured by a custom horizon profile.
  ///
  /// This is THE site minimum altitude for the whole product: the sequence
  /// builder and the planner's altitude charts read it through
  /// `siteMinimumAltitudeDegProvider` and never re-derive their own number. A
  /// second threshold anywhere lets the scheduler admit a target the builder
  /// then refuses.
  final double minAltitudeDegrees;

  /// Maximum moon separation penalty radius (degrees). Targets within this
  /// many degrees of the moon get their separation factor reduced; outside
  /// it the factor is 1.0. Weighted by moon illumination at evaluation time.
  final double moonAvoidanceRadiusDegrees;

  /// Maximum Sun altitude (degrees) at which the engine will still image.
  /// A candidate is hard-rejected while the Sun is above this — preventing
  /// the scheduler from slewing and exposing in daylight or bright twilight,
  /// making it wait for darkness at dusk and stop at dawn. Default -12°
  /// (nautical darkness); set -18° for astronomical-only, or 0° to image to
  /// the horizon. Without this gate the engine imaged in full daylight and
  /// never knew the night was over.
  final double maxSunAltitudeDegrees;

  final SchedulerWeights weights;

  const SchedulerConfig({
    this.tickInterval = const Duration(seconds: 60),
    this.hysteresisRatio = 1.20,
    // 30°, matching SmartNightSettings.minAltitudeDeg, the `targets`
    // table's min_altitude column and the planner's altitude threshold. The
    // default must not be looser than the builder's threshold, or the
    // scheduler promises a target the builder refuses.
    this.minAltitudeDegrees = 30.0,
    this.moonAvoidanceRadiusDegrees = 60.0,
    this.maxSunAltitudeDegrees = -12.0,
    this.weights = SchedulerWeights.defaults,
  });

  static const SchedulerConfig defaults = SchedulerConfig();

  SchedulerConfig copyWith({
    Duration? tickInterval,
    double? hysteresisRatio,
    double? minAltitudeDegrees,
    double? moonAvoidanceRadiusDegrees,
    double? maxSunAltitudeDegrees,
    SchedulerWeights? weights,
  }) {
    return SchedulerConfig(
      tickInterval: tickInterval ?? this.tickInterval,
      hysteresisRatio: hysteresisRatio ?? this.hysteresisRatio,
      minAltitudeDegrees: minAltitudeDegrees ?? this.minAltitudeDegrees,
      moonAvoidanceRadiusDegrees:
          moonAvoidanceRadiusDegrees ?? this.moonAvoidanceRadiusDegrees,
      maxSunAltitudeDegrees:
          maxSunAltitudeDegrees ?? this.maxSunAltitudeDegrees,
      weights: weights ?? this.weights,
    );
  }

  /// Serialize the operator-tunable fields (weights, min altitude, hysteresis)
  /// for durable storage. Fixed engine tuning (tick interval, moon/sun gates)
  /// is intentionally omitted so it always tracks the current engine defaults.
  Map<String, Object?> toStorageJson() => {
    'hysteresisRatio': hysteresisRatio,
    'minAltitudeDegrees': minAltitudeDegrees,
    'weights': weights.toStorageJson(),
  };

  /// Rebuild from [toStorageJson], layering the stored operator fields over
  /// [defaults] so unstored fields keep their engine defaults.
  factory SchedulerConfig.fromStorageJson(Map<String, dynamic> json) {
    final weightsJson = json['weights'];
    return SchedulerConfig.defaults.copyWith(
      hysteresisRatio: (json['hysteresisRatio'] as num?)?.toDouble(),
      minAltitudeDegrees: (json['minAltitudeDegrees'] as num?)?.toDouble(),
      weights: weightsJson is Map
          ? SchedulerWeights.fromStorageJson(
              weightsJson.cast<String, dynamic>(),
            )
          : null,
    );
  }

  @override
  List<Object?> get props => [
    tickInterval,
    hysteresisRatio,
    minAltitudeDegrees,
    moonAvoidanceRadiusDegrees,
    maxSunAltitudeDegrees,
    weights,
  ];
}

/// External event that should trigger an out-of-band re-evaluation.
///
/// The engine subscribes to a stream of these from the rest of the app
/// (weather changes, mount park/unpark, guiding loss/recovery, manual
/// override) so it can switch targets between regular ticks.
enum SchedulerTriggerEvent {
  weatherChange,
  guidingLost,
  guidingRecovered,
  mountParked,
  mountUnparked,
  manualOverride,
  integrationGoalsUpdated,
  candidatesUpdated,

  /// The autopilot's currently-dispatched sequence finished all its work
  /// (natural completion, not an operator/scheduler stop). The engine reacts
  /// by re-picking immediately so the rig doesn't sit idle until the next
  /// periodic tick — and so a still-eligible current target gets its
  /// remaining work re-dispatched instead of being held idle by hysteresis.
  sequenceCompleted,
}

/// Snapshot exposed to the UI describing what the scheduler is doing.
class SchedulerStatus extends Equatable {
  final SchedulerState state;
  final int? currentTargetId;
  final String? currentTargetName;

  /// Wall-clock instant when the next periodic tick will fire. Null while
  /// idle.
  final DateTime? nextEvaluationAt;

  /// Last error message, if the engine entered a degraded state. Cleared
  /// when the operator successfully restarts the engine.
  final String? lastError;

  /// True while [state] is [SchedulerState.paused] BECAUSE somebody outside
  /// the autopilot ended the run it had dispatched — the operator's Stop.
  ///
  /// Without it the next tick would see a free rig and re-dispatch the same
  /// target, overruling the person who just stopped it. It also lets the
  /// scheduler surface offer "Autopilot paused — resume?" instead of an
  /// ordinary operator-commanded pause.
  final bool pausedByOperatorStop;

  const SchedulerStatus({
    this.state = SchedulerState.idle,
    this.currentTargetId,
    this.currentTargetName,
    this.nextEvaluationAt,
    this.lastError,
    this.pausedByOperatorStop = false,
  });

  Map<String, dynamic> toJson() => {
    'state': state.name,
    if (currentTargetId != null) 'currentTargetId': currentTargetId,
    if (currentTargetName != null) 'currentTargetName': currentTargetName,
    if (nextEvaluationAt != null)
      'nextEvaluationAt': nextEvaluationAt!.toIso8601String(),
    if (lastError != null) 'lastError': lastError,
    if (pausedByOperatorStop) 'pausedByOperatorStop': true,
  };

  factory SchedulerStatus.fromJson(Map<String, dynamic> json) {
    final stateName = json['state'] as String?;
    final state = SchedulerState.values.where((value) {
      return value.name == stateName;
    }).firstOrNull;
    return SchedulerStatus(
      state: state ?? SchedulerState.idle,
      currentTargetId: (json['currentTargetId'] as num?)?.toInt(),
      currentTargetName: json['currentTargetName'] as String?,
      nextEvaluationAt: DateTime.tryParse(
        json['nextEvaluationAt'] as String? ?? '',
      ),
      lastError: json['lastError'] as String?,
      pausedByOperatorStop: json['pausedByOperatorStop'] as bool? ?? false,
    );
  }

  SchedulerStatus copyWith({
    SchedulerState? state,
    int? currentTargetId,
    String? currentTargetName,
    DateTime? nextEvaluationAt,
    String? lastError,
    bool? pausedByOperatorStop,
    bool clearCurrentTarget = false,
    bool clearNextEvaluation = false,
    bool clearError = false,
  }) {
    return SchedulerStatus(
      state: state ?? this.state,
      currentTargetId: clearCurrentTarget
          ? null
          : (currentTargetId ?? this.currentTargetId),
      currentTargetName: clearCurrentTarget
          ? null
          : (currentTargetName ?? this.currentTargetName),
      nextEvaluationAt: clearNextEvaluation
          ? null
          : (nextEvaluationAt ?? this.nextEvaluationAt),
      lastError: clearError ? null : (lastError ?? this.lastError),
      pausedByOperatorStop: pausedByOperatorStop ?? this.pausedByOperatorStop,
    );
  }

  @override
  List<Object?> get props => [
    state,
    currentTargetId,
    currentTargetName,
    nextEvaluationAt,
    lastError,
    pausedByOperatorStop,
  ];
}
