import 'package:equatable/equatable.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart'
    show wireInt, wireDouble, wireMap, wireOptDouble, wireOptInt;

/// What a running step reports about itself, as the sequencer's
/// `ProgressDetail` sends it: the variant's name and its fields.
///
/// The steps the app draws a panel or a mark for have a class here; any other
/// kind is kept as [UnknownInstructionProgressDetail]. The field names are
/// pinned against the native side by
/// `test/fixtures/progress_detail_kinds.json`, which both sides' tests read.
sealed class InstructionProgressDetail extends Equatable {
  const InstructionProgressDetail();

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
        case 'MeridianFlipRetry':
          return MeridianFlipRetryProgressDetail(
            failedAttempt: wireInt(json, 'failed_attempt'),
            maxAttempts: wireInt(json, 'max_attempts'),
            retryInSecs: wireDouble(json, 'retry_in_secs'),
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
  List<Object?> get props => [failedAttempt, maxAttempts, retryInSecs];
}

class UnknownInstructionProgressDetail extends InstructionProgressDetail {
  final String kind;
  final Map<String, Object?> rawJson;

  const UnknownInstructionProgressDetail({
    required this.kind,
    required this.rawJson,
  });

  @override
  List<Object?> get props => [kind, rawJson];
}
