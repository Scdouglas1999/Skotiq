// ignore_for_file: invalid_annotation_target

part of '../../sequence_models.dart';

/// Recovery node - handles errors with retry/recovery logic
class RecoveryNode extends SequenceNode {
  final RecoveryActionType recoveryAction;
  final int maxRetries;
  final TriggerType? triggerType;

  /// Generic threshold value whose meaning depends on [triggerType]:
  /// - For [TriggerType.hfrDegraded]: absolute HFR threshold in arcsec/px
  ///   (0 = disabled, use only relative mode)
  /// - For [TriggerType.altitudeLimit]: minimum altitude in degrees
  /// - For [TriggerType.humidityThreshold]: max percent humidity (e.g. 85)
  /// - For [TriggerType.driftLimit]: max drift in pixels (e.g. 30)
  /// - For [TriggerType.temperatureShift]: degrees of change to trigger
  /// - For [TriggerType.guidingFailed]: RMS threshold in arcsec
  /// - For [TriggerType.dawnApproaching]: minutes before astronomical twilight
  /// - For [TriggerType.autofocusInterval] / [TriggerType.ditherInterval]:
  ///   the integer cadence (every-N-frames) is read from [triggerEveryNFrames]
  ///   instead so the int type is preserved on the wire.
  final double? triggerThreshold;

  /// HFR-specific: percentage above baseline HFR that triggers recovery.
  /// E.g. 20.0 means trigger when HFR is 20% above the post-autofocus baseline.
  /// Only used when [triggerType] is [TriggerType.hfrDegraded].
  /// Set to 0 to disable relative mode and use only absolute threshold.
  final double hfrThresholdPercent;

  /// HFR-specific: number of consecutive frames that must exceed the threshold
  /// before the trigger fires. Prevents false positives from momentary seeing
  /// spikes. Only used when [triggerType] is [TriggerType.hfrDegraded].
  final int hfrConsecutiveFrames;

  // Trigger-config fields

  /// Cadence in frames for [TriggerType.autofocusInterval] /
  /// [TriggerType.ditherInterval]. The Rust side rejects 0 (`silently
  /// disables`); use the node's `enabled` flag to disable instead.
  final int triggerEveryNFrames;

  /// [TriggerType.focusDrift] rolling-window size (number of HFR samples).
  /// Rust clamps to [`FOCUS_DRIFT_WINDOW_MAX`] (100) at trigger-create time
  /// and emits a user-visible ExecutorEvent::Error when clamping occurs.
  final int focusDriftWindowSize;

  /// [TriggerType.focusDrift] minimum number of consecutive increasing HFR
  /// samples before firing. Must be >= 2.
  final int focusDriftMinIncreasingCount;

  /// [TriggerType.focusDrift] minimum total HFR increase across the
  /// increasing run to fire.
  final double focusDriftMinTotalIncrease;

  /// [TriggerType.guidingFailed] required duration (seconds) of elevated RMS
  /// before firing.
  final double guidingFailedDurationSecs;

  // Cloud-motion trigger config fields

  /// [TriggerType.cloudArrivingIn] and [TriggerType.cloudOpeningIn]:
  /// fire when arrival/opening is at or below this many minutes.
  final double cloudMinutesBefore;

  /// [TriggerType.cloudArrivingIn]: required predicted coverage percentage
  /// (0-100). Trigger fires only when predicted cover exceeds this value.
  final double cloudCoverageThresholdPercent;

  /// [TriggerType.cloudOpeningIn]: minimum opening duration (seconds) that
  /// counts as imageable. Smaller gaps are ignored.
  final double cloudOpeningMinDurationSecs;

  /// [TriggerType.cloudCoverThreshold]: maximum allowed cover (0-100).
  /// Fire when current cover exceeds this value for [cloudCoverDurationSecs].
  final double cloudCoverMaxPercent;

  /// [TriggerType.cloudCoverThreshold]: required duration (seconds) above
  /// the threshold before firing. Acts as a debounce.
  final double cloudCoverDurationSecs;

  /// [TriggerType.transparencyDropped]: transparency fraction (0.0..=1.0)
  /// below which the trigger fires after [transparencyDurationSecs] of
  /// continuous samples at or below the threshold.
  final double transparencyBelowThreshold;

  /// [TriggerType.transparencyDropped]: required duration (seconds) at or
  /// below the threshold before firing. Acts as a debounce. Default 60s.
  final double transparencyDurationSecs;

  RecoveryNode({
    super.id,
    super.name = 'Recovery',
    super.isEnabled,
    super.childIds,
    super.parentId,
    super.orderIndex,
    super.comment,
    this.recoveryAction = RecoveryActionType.retry,
    this.maxRetries = 3,
    this.triggerType,
    this.triggerThreshold,
    this.hfrThresholdPercent = 20.0,
    this.hfrConsecutiveFrames = 3,
    this.triggerEveryNFrames = 25,
    this.focusDriftWindowSize = 10,
    this.focusDriftMinIncreasingCount = 5,
    this.focusDriftMinTotalIncrease = 0.5,
    this.guidingFailedDurationSecs = 30.0,
    // Cloud-motion defaults. 10 min lead time + 70%
    // coverage matches the SGP-style "act before clouds hit" semantic;
    // the 30 s opening minimum prevents firing on a wisp.
    this.cloudMinutesBefore = 10.0,
    this.cloudCoverageThresholdPercent = 70.0,
    this.cloudOpeningMinDurationSecs = 300.0,
    this.cloudCoverMaxPercent = 80.0,
    this.cloudCoverDurationSecs = 60.0,
    // Science — transparency-adaptive trigger defaults. 0.7 +
    // 60s matches the brief's recommended "swap when transparency
    // drops below 70% for a minute" workflow.
    this.transparencyBelowThreshold = 0.7,
    this.transparencyDurationSecs = 60.0,
  });

  @override
  String get nodeType => 'Recovery';

  @override
  String get iconName => 'shield-check';

  @override
  NodeCategory get category => NodeCategory.logic;

  @override
  RecoveryNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    RecoveryActionType? recoveryAction,
    int? maxRetries,
    TriggerType? triggerType,
    double? triggerThreshold,
    double? hfrThresholdPercent,
    int? hfrConsecutiveFrames,
    int? triggerEveryNFrames,
    int? focusDriftWindowSize,
    int? focusDriftMinIncreasingCount,
    double? focusDriftMinTotalIncrease,
    double? guidingFailedDurationSecs,
    double? cloudMinutesBefore,
    double? cloudCoverageThresholdPercent,
    double? cloudOpeningMinDurationSecs,
    double? cloudCoverMaxPercent,
    double? cloudCoverDurationSecs,
    double? transparencyBelowThreshold,
    double? transparencyDurationSecs,
  }) {
    return RecoveryNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      recoveryAction: recoveryAction ?? this.recoveryAction,
      maxRetries: maxRetries ?? this.maxRetries,
      triggerType: triggerType ?? this.triggerType,
      triggerThreshold: triggerThreshold ?? this.triggerThreshold,
      hfrThresholdPercent: hfrThresholdPercent ?? this.hfrThresholdPercent,
      hfrConsecutiveFrames: hfrConsecutiveFrames ?? this.hfrConsecutiveFrames,
      triggerEveryNFrames: triggerEveryNFrames ?? this.triggerEveryNFrames,
      focusDriftWindowSize: focusDriftWindowSize ?? this.focusDriftWindowSize,
      focusDriftMinIncreasingCount:
          focusDriftMinIncreasingCount ?? this.focusDriftMinIncreasingCount,
      focusDriftMinTotalIncrease:
          focusDriftMinTotalIncrease ?? this.focusDriftMinTotalIncrease,
      guidingFailedDurationSecs:
          guidingFailedDurationSecs ?? this.guidingFailedDurationSecs,
      cloudMinutesBefore: cloudMinutesBefore ?? this.cloudMinutesBefore,
      cloudCoverageThresholdPercent:
          cloudCoverageThresholdPercent ?? this.cloudCoverageThresholdPercent,
      cloudOpeningMinDurationSecs:
          cloudOpeningMinDurationSecs ?? this.cloudOpeningMinDurationSecs,
      cloudCoverMaxPercent: cloudCoverMaxPercent ?? this.cloudCoverMaxPercent,
      cloudCoverDurationSecs:
          cloudCoverDurationSecs ?? this.cloudCoverDurationSecs,
      transparencyBelowThreshold:
          transparencyBelowThreshold ?? this.transparencyBelowThreshold,
      transparencyDurationSecs:
          transparencyDurationSecs ?? this.transparencyDurationSecs,
    );
  }

  /// Trigger types that judge the frames or the guiding rather than protect
  /// the rig. Stopping the run for one of them is the operator's choice to
  /// make, never a default.
  static const Set<TriggerType> qualityTriggerTypes = {
    TriggerType.hfrDegraded,
    TriggerType.focusDrift,
    TriggerType.guidingFailed,
    TriggerType.driftLimit,
    TriggerType.transparencyDropped,
  };

  /// This node watching [value]. A node still at its default Retry — which on
  /// a trigger means "pause the run after that many firings" — gets Notify
  /// when it is given a quality trigger (owner decision 2026-10-06: only a
  /// risk to the hardware stops a run by itself). An action the operator
  /// chose is kept.
  RecoveryNode withTriggerType(TriggerType? value) {
    final notify =
        value != null &&
        qualityTriggerTypes.contains(value) &&
        recoveryAction == RecoveryActionType.retry;
    return copyWith(
      triggerType: value,
      recoveryAction: notify ? RecoveryActionType.notify : null,
    );
  }

  @override
  List<Object?> get props => [
    ...super.props,
    recoveryAction,
    maxRetries,
    triggerType,
    triggerThreshold,
    hfrThresholdPercent,
    hfrConsecutiveFrames,
    triggerEveryNFrames,
    focusDriftWindowSize,
    focusDriftMinIncreasingCount,
    focusDriftMinTotalIncrease,
    guidingFailedDurationSecs,
    cloudMinutesBefore,
    cloudCoverageThresholdPercent,
    cloudOpeningMinDurationSecs,
    cloudCoverMaxPercent,
    cloudCoverDurationSecs,
    transparencyBelowThreshold,
    transparencyDurationSecs,
  ];

  /// Serialize the configured trigger into the Rust-side
  /// `TriggerType` JSON form. Mirrors the tagged-enum serde format used by
  /// `nightshade_sequencer::TriggerType`. `null` means "any error" (no
  /// type-specific trigger configured), which matches Rust's
  /// `RecoveryConfig::trigger: Option<TriggerType>` semantics.
  ///
  /// Returns either a `Map<String, dynamic>` (struct variants) or a `String`
  /// (unit variants) — serde's externally-tagged default encodes those forms
  /// as `{"VariantName": {...}}` and `"VariantName"` respectively. Callers
  /// pass the result through `jsonEncode` so both shapes round-trip.
  dynamic toRustTriggerConfig() {
    final type = triggerType;
    if (type == null) return null;
    switch (type) {
      case TriggerType.hfrDegraded:
        return {
          'HfrDegraded': {
            'threshold_percent': hfrThresholdPercent,
            'absolute_threshold': triggerThreshold ?? 0.0,
            'consecutive_frames': hfrConsecutiveFrames,
          },
        };
      case TriggerType.meridianFlip:
        // MeridianFlip carries a full MeridianFlipConfig payload. RecoveryNode
        // doesn't model that yet; default to the Rust-side serde defaults by
        // passing an empty object so the deserializer fills in the defaults.
        return {
          'MeridianFlip': {'config': <String, dynamic>{}},
        };
      case TriggerType.guidingFailed:
        return {
          'GuidingFailed': {
            'rms_threshold': triggerThreshold ?? 2.0,
            'duration_secs': guidingFailedDurationSecs,
          },
        };
      case TriggerType.altitudeLimit:
        return {
          'AltitudeLimit': {'min_altitude': triggerThreshold ?? 30.0},
        };
      case TriggerType.weatherUnsafe:
        return 'WeatherUnsafe';
      case TriggerType.temperatureShift:
        return {
          'TemperatureShift': {'degrees': triggerThreshold ?? 2.0},
        };
      case TriggerType.filterChange:
        return 'FilterChange';
      case TriggerType.dawnApproaching:
        return {
          'DawnApproaching': {'minutes_before': triggerThreshold ?? 30.0},
        };
      case TriggerType.humidityThreshold:
        return {
          'HumidityThreshold': {'max_percent': triggerThreshold ?? 85.0},
        };
      case TriggerType.focusDrift:
        return {
          'FocusDrift': {
            'window_size': focusDriftWindowSize,
            'min_increasing_count': focusDriftMinIncreasingCount,
            'min_total_increase': focusDriftMinTotalIncrease,
          },
        };
      case TriggerType.mountTrackingLost:
        return 'MountTrackingLost';
      case TriggerType.domeShutterNotOpen:
        return 'DomeShutterNotOpen';
      case TriggerType.guideStarLost:
        return 'GuideStarLost';
      case TriggerType.autofocusInterval:
        return {
          'AutofocusInterval': {'every_n_frames': triggerEveryNFrames},
        };
      case TriggerType.ditherInterval:
        return {
          'DitherInterval': {'every_n_frames': triggerEveryNFrames},
        };
      case TriggerType.driftLimit:
        return {
          'DriftLimit': {'max_pixels': triggerThreshold ?? 30.0},
        };
      // Cloud-motion-aware triggers. Field names match
      // the Rust serde-tagged enum form (`#[serde(...)]` external default).
      case TriggerType.cloudArrivingIn:
        return {
          'CloudArrivingIn': {
            'minutes_before': cloudMinutesBefore,
            'coverage_threshold': cloudCoverageThresholdPercent,
          },
        };
      case TriggerType.cloudOpeningIn:
        return {
          'CloudOpeningIn': {
            'minutes_before': cloudMinutesBefore,
            'minimum_duration_secs': cloudOpeningMinDurationSecs,
          },
        };
      case TriggerType.cloudCoverThreshold:
        return {
          'CloudCoverThreshold': {
            'max_percent': cloudCoverMaxPercent,
            'duration_secs': cloudCoverDurationSecs,
          },
        };
      // Science — transparency-adaptive trigger. Field names
      // match the Rust serde-tagged enum variant.
      case TriggerType.transparencyDropped:
        return {
          'TransparencyDropped': {
            'below_threshold': transparencyBelowThreshold,
            'duration_secs': transparencyDurationSecs,
          },
        };
    }
  }
}
