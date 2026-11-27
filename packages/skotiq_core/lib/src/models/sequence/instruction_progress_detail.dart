import 'package:equatable/equatable.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart'
    show
        wireBool,
        wireInt,
        wireDouble,
        wireMap,
        wireOptDouble,
        wireOptInt,
        wireOptString,
        wireString;

import '../meridian_flip_event.dart';
import 'adaptive_exposure_event.dart' show AdaptiveExposureReason;

/// What a running step reports about itself, as the sequencer's
/// `ProgressDetail` sends it: the variant's name and its fields.
///
/// The steps the app draws a panel or a mark for have a class here; any other
/// kind is kept as [UnknownInstructionProgressDetail]. The field names are
/// pinned against the native side by
/// `test_fixtures/wire_words/progress_detail_kinds.json`, which both sides' tests read.
/// The kind of a step's free text, which has no fields of its own.
const String kGenericProgressDetailKind = 'Generic';

/// The kind the bridge sends a meridian flip's step reports under; not a
/// native `ProgressDetail` but a `MeridianFlipEvent` (see
/// [MeridianFlipStepProgressDetail]).
const String kMeridianFlipProgressDetailKind = 'MeridianFlip';

sealed class InstructionProgressDetail extends Equatable {
  const InstructionProgressDetail();

  /// The kind and fields as the sequencer sends them, which
  /// [InstructionProgressDetail.fromStructuredData] reads back.
  ({String detailKind, Map<String, Object?> detailJson}) get wire;

  /// Whether this report is a reading of the step (frames, a sweep point, a
  /// temperature) rather than words about what holds it.
  bool get isReading => true;

  factory InstructionProgressDetail.fromStructuredData({
    required String detailKind,
    required Object? detailJson,
  }) {
    final json = wireMap(detailJson);
    try {
      switch (detailKind) {
        case 'Exposure':
          return ExposureInstructionProgressDetail(
            frame: wireInt(json, 'frame'),
            total: wireInt(json, 'total'),
            durationSecs: wireDouble(json, 'duration_secs'),
          );
        case 'Center':
          return CenterInstructionProgressDetail(
            attempt: wireInt(json, 'attempt'),
            maxAttempts: wireInt(json, 'max_attempts'),
            lastSeparationArcsec: wireOptDouble(json, 'last_separation_arcsec'),
            solvedRaHours: wireOptDouble(json, 'solved_ra_hours'),
            solvedDecDegrees: wireOptDouble(json, 'solved_dec_degrees'),
          );
        case 'Autofocus':
          return AutofocusInstructionProgressDetail(
            step: wireInt(json, 'step'),
            totalSteps: wireInt(json, 'total_steps'),
            currentHfr: wireOptDouble(json, 'current_hfr'),
            starCount: wireOptInt(json, 'star_count'),
          );
        case 'Thermal':
          return ThermalInstructionProgressDetail(
            currentTempC: wireOptDouble(json, 'current_temp_c'),
            targetTempC: wireOptDouble(json, 'target_temp_c'),
            coolerPowerPercent: wireOptDouble(json, 'cooler_power_percent'),
          );
        case 'Filter':
          return FilterInstructionProgressDetail(
            name: wireString(json, 'name'),
            position: wireOptInt(json, 'position'),
          );
        case 'SmartExposure':
          return SmartExposureInstructionProgressDetail(
            currentFilter: wireString(json, 'current_filter'),
            planIndex: wireInt(json, 'plan_index'),
            totalPlans: wireInt(json, 'total_plans'),
            frameInPlan: wireInt(json, 'frame_in_plan'),
            totalFrames: wireInt(json, 'total_frames'),
          );
        case kMeridianFlipProgressDetailKind:
          final event = MeridianFlipEvent.fromWire(json);
          if (event != null) {
            return MeridianFlipStepProgressDetail(event: event, rawJson: json);
          }
        case 'MeridianFlipRetry':
          return MeridianFlipRetryProgressDetail(
            failedAttempt: wireInt(json, 'failed_attempt'),
            maxAttempts: wireInt(json, 'max_attempts'),
            retryInSecs: wireDouble(json, 'retry_in_secs'),
          );
        case 'TargetWaiting':
          return TargetWaitingProgressDetail(
            target: wireString(json, 'target'),
            condition: wireString(json, 'condition'),
            altitudeDeg: wireOptDouble(json, 'altitude_deg'),
            floorDeg: wireOptDouble(json, 'floor_deg'),
          );
        case 'FlipHold':
          return FlipHoldProgressDetail(
            exposureSecs: wireDouble(json, 'exposure_secs'),
            firesInSecs: wireDouble(json, 'fires_in_secs'),
            hourAngleHours: wireDouble(json, 'hour_angle_hours'),
            thresholdMin: wireDouble(json, 'threshold_min'),
          );
        case 'ExposureAdjusted':
          return ExposureAdjustedProgressDetail(
            adaptedSecs: wireDouble(json, 'adapted_secs'),
            nominalSecs: wireDouble(json, 'nominal_secs'),
            skyBrightnessMag: wireOptDouble(json, 'sky_brightness_mag'),
            filter: wireOptString(json, 'filter'),
            reasonWire: wireString(json, 'reason'),
            unchanged: wireBool(json, 'unchanged'),
          );
      }
    } on FormatException {
      // A known kind without one of its counts is read as an unknown one.
    }
    return UnknownInstructionProgressDetail(kind: detailKind, rawJson: json);
  }
}

class ExposureInstructionProgressDetail extends InstructionProgressDetail {
  final int frame;
  final int total;
  final double durationSecs;

  const ExposureInstructionProgressDetail({
    required this.frame,
    required this.total,
    required this.durationSecs,
  });

  @override
  ({String detailKind, Map<String, Object?> detailJson}) get wire => (
    detailKind: 'Exposure',
    detailJson: {'frame': frame, 'total': total, 'duration_secs': durationSecs},
  );

  @override
  List<Object?> get props => [frame, total, durationSecs];
}

/// A Center step. [attempt] is 0 on the step's opening and closing reports;
/// a closing report carries the final [lastSeparationArcsec].
class CenterInstructionProgressDetail extends InstructionProgressDetail {
  final int attempt;
  final int maxAttempts;
  final double? lastSeparationArcsec;

  /// Where the attempt's frame solved, on the report of the solve.
  final double? solvedRaHours;
  final double? solvedDecDegrees;

  const CenterInstructionProgressDetail({
    required this.attempt,
    required this.maxAttempts,
    this.lastSeparationArcsec,
    this.solvedRaHours,
    this.solvedDecDegrees,
  });

  @override
  ({String detailKind, Map<String, Object?> detailJson}) get wire => (
    detailKind: 'Center',
    detailJson: {
      'attempt': attempt,
      'max_attempts': maxAttempts,
      'last_separation_arcsec': lastSeparationArcsec,
      'solved_ra_hours': solvedRaHours,
      'solved_dec_degrees': solvedDecDegrees,
    },
  );

  @override
  List<Object?> get props => [
    attempt,
    maxAttempts,
    lastSeparationArcsec,
    solvedRaHours,
    solvedDecDegrees,
  ];
}

/// An autofocus sweep at its latest measured point. [step] counts from 1.
class AutofocusInstructionProgressDetail extends InstructionProgressDetail {
  final int step;
  final int totalSteps;
  final double? currentHfr;
  final int? starCount;

  const AutofocusInstructionProgressDetail({
    required this.step,
    required this.totalSteps,
    this.currentHfr,
    this.starCount,
  });

  @override
  ({String detailKind, Map<String, Object?> detailJson}) get wire => (
    detailKind: 'Autofocus',
    detailJson: {
      'step': step,
      'total_steps': totalSteps,
      'current_hfr': currentHfr,
      'star_count': starCount,
    },
  );

  @override
  List<Object?> get props => [step, totalSteps, currentHfr, starCount];
}

/// A cool or warm step. A field is null on a report that did not read it.
class ThermalInstructionProgressDetail extends InstructionProgressDetail {
  final double? currentTempC;
  final double? targetTempC;
  final double? coolerPowerPercent;

  const ThermalInstructionProgressDetail({
    this.currentTempC,
    this.targetTempC,
    this.coolerPowerPercent,
  });

  @override
  ({String detailKind, Map<String, Object?> detailJson}) get wire => (
    detailKind: 'Thermal',
    detailJson: {
      'current_temp_c': currentTempC,
      'target_temp_c': targetTempC,
      'cooler_power_percent': coolerPowerPercent,
    },
  );

  @override
  List<Object?> get props => [currentTempC, targetTempC, coolerPowerPercent];
}

/// A meridian flip attempt failed and the next one is scheduled.
class MeridianFlipRetryProgressDetail extends InstructionProgressDetail {
  final int failedAttempt;
  final int maxAttempts;
  final double retryInSecs;

  const MeridianFlipRetryProgressDetail({
    required this.failedAttempt,
    required this.maxAttempts,
    required this.retryInSecs,
  });

  @override
  ({String detailKind, Map<String, Object?> detailJson}) get wire => (
    detailKind: 'MeridianFlipRetry',
    detailJson: {
      'failed_attempt': failedAttempt,
      'max_attempts': maxAttempts,
      'retry_in_secs': retryInSecs,
    },
  );

  @override
  List<Object?> get props => [failedAttempt, maxAttempts, retryInSecs];
}

/// A target waiting to start: for [condition], or, when [altitudeDeg] and
/// [floorDeg] are set, to clear the site's altitude floor in its direction.
class TargetWaitingProgressDetail extends InstructionProgressDetail {
  final String target;
  final String condition;
  final double? altitudeDeg;
  final double? floorDeg;

  const TargetWaitingProgressDetail({
    required this.target,
    required this.condition,
    this.altitudeDeg,
    this.floorDeg,
  });

  @override
  ({String detailKind, Map<String, Object?> detailJson}) get wire => (
    detailKind: 'TargetWaiting',
    detailJson: {
      'target': target,
      'condition': condition,
      'altitude_deg': altitudeDeg,
      'floor_deg': floorDeg,
    },
  );

  @override
  bool get isReading => false;

  @override
  List<Object?> get props => [target, condition, altitudeDeg, floorDeg];
}

/// The next exposure is held for a meridian flip that would cut it short.
/// [firesInSecs] is negative for a flip that is already due.
class FlipHoldProgressDetail extends InstructionProgressDetail {
  final double exposureSecs;
  final double firesInSecs;
  final double hourAngleHours;
  final double thresholdMin;

  const FlipHoldProgressDetail({
    required this.exposureSecs,
    required this.firesInSecs,
    required this.hourAngleHours,
    required this.thresholdMin,
  });

  @override
  ({String detailKind, Map<String, Object?> detailJson}) get wire => (
    detailKind: 'FlipHold',
    detailJson: {
      'exposure_secs': exposureSecs,
      'fires_in_secs': firesInSecs,
      'hour_angle_hours': hourAngleHours,
      'threshold_min': thresholdMin,
    },
  );

  @override
  bool get isReading => false;

  @override
  List<Object?> get props => [
    exposureSecs,
    firesInSecs,
    hourAngleHours,
    thresholdMin,
  ];
}

/// The adaptive exposure decision a burst starts with.
class ExposureAdjustedProgressDetail extends InstructionProgressDetail {
  final double adaptedSecs;
  final double nominalSecs;
  final double? skyBrightnessMag;
  final String? filter;

  /// The reason's wire word, kept as sent.
  final String reasonWire;

  /// The burst is taken at its planned length.
  final bool unchanged;

  const ExposureAdjustedProgressDetail({
    required this.adaptedSecs,
    required this.nominalSecs,
    this.skyBrightnessMag,
    this.filter,
    required this.reasonWire,
    required this.unchanged,
  });

  AdaptiveExposureReason get reason =>
      AdaptiveExposureReason.fromWire(reasonWire);

  @override
  ({String detailKind, Map<String, Object?> detailJson}) get wire => (
    detailKind: 'ExposureAdjusted',
    detailJson: {
      'adapted_secs': adaptedSecs,
      'nominal_secs': nominalSecs,
      'sky_brightness_mag': skyBrightnessMag,
      'filter': filter,
      'reason': reasonWire,
      'unchanged': unchanged,
    },
  );

  @override
  List<Object?> get props => [
    adaptedSecs,
    nominalSecs,
    skyBrightnessMag,
    filter,
    reasonWire,
    unchanged,
  ];
}

/// The filter the wheel is on, once a step has put it there.
class FilterInstructionProgressDetail extends InstructionProgressDetail {
  final String name;
  final int? position;

  const FilterInstructionProgressDetail({required this.name, this.position});

  @override
  ({String detailKind, Map<String, Object?> detailJson}) get wire =>
      (detailKind: 'Filter', detailJson: {'name': name, 'position': position});

  @override
  List<Object?> get props => [name, position];
}

/// A Smart Exposure step. [planIndex] counts from 0; [frameInPlan] is the
/// frames done of [totalFrames] for [currentFilter].
class SmartExposureInstructionProgressDetail extends InstructionProgressDetail {
  final String currentFilter;
  final int planIndex;
  final int totalPlans;
  final int frameInPlan;
  final int totalFrames;

  const SmartExposureInstructionProgressDetail({
    required this.currentFilter,
    required this.planIndex,
    required this.totalPlans,
    required this.frameInPlan,
    required this.totalFrames,
  });

  @override
  ({String detailKind, Map<String, Object?> detailJson}) get wire => (
    detailKind: 'SmartExposure',
    detailJson: {
      'current_filter': currentFilter,
      'plan_index': planIndex,
      'total_plans': totalPlans,
      'frame_in_plan': frameInPlan,
      'total_frames': totalFrames,
    },
  );

  @override
  List<Object?> get props => [
    currentFilter,
    planIndex,
    totalPlans,
    frameInPlan,
    totalFrames,
  ];
}

/// A step of a running meridian flip.
class MeridianFlipStepProgressDetail extends InstructionProgressDetail {
  final MeridianFlipEvent event;

  /// The event as the native side tagged it, sent back unchanged.
  final Map<String, Object?> rawJson;

  const MeridianFlipStepProgressDetail({
    required this.event,
    required this.rawJson,
  });

  @override
  ({String detailKind, Map<String, Object?> detailJson}) get wire =>
      (detailKind: kMeridianFlipProgressDetailKind, detailJson: rawJson);

  @override
  List<Object?> get props => [event];
}

class UnknownInstructionProgressDetail extends InstructionProgressDetail {
  final String kind;
  final Map<String, Object?> rawJson;

  const UnknownInstructionProgressDetail({
    required this.kind,
    required this.rawJson,
  });

  @override
  ({String detailKind, Map<String, Object?> detailJson}) get wire =>
      (detailKind: kind, detailJson: rawJson);

  @override
  bool get isReading => kind != kGenericProgressDetailKind;

  @override
  List<Object?> get props => [kind, rawJson];
}
