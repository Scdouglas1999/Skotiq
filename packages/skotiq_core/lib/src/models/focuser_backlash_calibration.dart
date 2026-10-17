import 'dart:convert';

import '../database/daos/settings_dao.dart';
import 'autofocus_progress.dart';

/// Which face of the gear train a scan's points were reached from.
///
/// The whole measurement is the difference between these two: approach every
/// position from below and the drawtube sits on one face of the dead band,
/// approach it from above and it sits on the other.
enum FocuserBacklashApproach {
  fromBelow('from_below', 'from below'),
  fromAbove('from_above', 'from above');

  const FocuserBacklashApproach(this.wireValue, this.label);

  /// The value native serialises.
  final String wireValue;

  /// Wording for an operator-facing sentence.
  final String label;

  static FocuserBacklashApproach? fromWire(Object? value) {
    for (final approach in values) {
      if (approach.wireValue == value) return approach;
    }
    return null;
  }
}

/// How much a measurement is worth, given the evidence behind it. Native
/// decides this and supplies its grounds in plain language; Dart only carries
/// it.
enum FocuserBacklashConfidence {
  high('high'),
  moderate('moderate'),
  low('low');

  const FocuserBacklashConfidence(this.wireValue);

  final String wireValue;

  static FocuserBacklashConfidence? fromWire(Object? value) {
    for (final confidence in values) {
      if (confidence.wireValue == value) return confidence;
    }
    return null;
  }
}

/// The three ways a calibration run can end with an answer.
///
/// [noMeasurableBacklash] is an answer, not a failure: plenty of focusers have
/// no dead band worth compensating, and reporting that is the honest result.
enum FocuserBacklashOutcomeKind {
  measured('measured'),
  noMeasurableBacklash('no_measurable_backlash'),
  refused('refused');

  const FocuserBacklashOutcomeKind(this.wireValue);

  final String wireValue;

  static FocuserBacklashOutcomeKind? fromWire(Object? value) {
    for (final kind in values) {
      if (kind.wireValue == value) return kind;
    }
    return null;
  }
}

/// One direction's scan: the points the fit used, and what the fit made of
/// them.
class FocuserBacklashScan {
  const FocuserBacklashScan({
    required this.approach,
    required this.points,
    required this.optimumPosition,
    required this.rSquared,
  });

  final FocuserBacklashApproach approach;

  /// The points that reached the fit — post outlier rejection, so this is the
  /// evidence for [optimumPosition] rather than everything that was exposed.
  final List<VCurvePoint> points;

  /// Fitted vertex, in commanded focuser steps.
  final int optimumPosition;

  final double rSquared;

  static FocuserBacklashScan? _fromJson(Object? json) {
    if (json is! Map) return null;
    final approach = FocuserBacklashApproach.fromWire(json['approach']);
    final optimum = json['optimum_position'];
    final rSquared = json['r_squared'];
    final rawPoints = json['points'];
    if (approach == null ||
        optimum is! int ||
        rSquared is! num ||
        rawPoints is! List) {
      return null;
    }
    final points = <VCurvePoint>[];
    for (final raw in rawPoints) {
      if (raw is! Map) return null;
      final position = raw['position'];
      final hfr = raw['hfr'];
      if (position is! int || hfr is! num) return null;
      points.add(VCurvePoint(position: position, hfr: hfr.toDouble()));
    }
    return FocuserBacklashScan(
      approach: approach,
      points: points,
      optimumPosition: optimum,
      rSquared: rSquared.toDouble(),
    );
  }
}

/// Why a calibration produced no figure.
///
/// [message] and [remedy] are written by the side that knows what went wrong
/// and are displayed verbatim. Rewording them in Dart would put two different
/// explanations of the same refusal in the product.
class FocuserBacklashRefusal {
  const FocuserBacklashRefusal({
    required this.code,
    required this.message,
    required this.remedy,
  });

  /// Machine-stable identifier, e.g. `poor_fit`. Matched by tests and logs
  /// rather than by the prose.
  final String code;

  /// What went wrong, in the operator's terms.
  final String message;

  /// What to do about it.
  final String remedy;
}

/// A completed measurement with all its evidence.
///
/// [steps] is 0 when the two vertices landed closer together than the scans
/// could resolve. Nothing clamps that up to a positive number: a figure that
/// was not measured would move somebody's drawtube for no reason.
///
/// Backlash varies along the travel — 105 steps near position 6600 and 83 near
/// 2500 on the same ZWO EAF — so [measuredAtPosition] and
/// [temperatureCelsius] travel with the figure and it is never shown bare.
class FocuserBacklashCalibration {
  const FocuserBacklashCalibration({
    required this.steps,
    required this.vertexDifference,
    required this.measurable,
    required this.resolutionLimitSteps,
    required this.below,
    required this.above,
    required this.measuredAtPosition,
    required this.clearanceSteps,
    required this.reversalBudgetSteps,
    required this.reversalBudgetAtVertexSteps,
    required this.confidence,
    required this.confidenceReason,
    required this.takenAt,
    required this.temperatureCelsius,
    required this.appVersion,
    required this.focuserDeviceId,
  });

  /// Backlash to apply, in focuser steps. 0 when [measurable] is false.
  final int steps;

  /// The raw signed difference between the two vertices, before the
  /// resolution test. Kept because it is the measurement; [steps] is the
  /// conclusion drawn from it.
  final int vertexDifference;

  /// False when the difference was inside [resolutionLimitSteps], i.e. "no
  /// backlash larger than that was detectable".
  final bool measurable;

  /// The smallest difference these two scans could have told apart.
  final double resolutionLimitSteps;

  final FocuserBacklashScan below;
  final FocuserBacklashScan above;

  /// Where in the travel this was measured — the from-below optimum, which is
  /// true optical focus.
  final int measuredAtPosition;

  /// The run-up each scan point was approached with.
  final int clearanceSteps;

  /// How far the scan reversed the drive train in total, and so a hard ceiling
  /// on any figure it could produce: a measured dead band wider than this did
  /// not come from a dead band.
  final int reversalBudgetSteps;

  /// The reversal accumulated by the middle of the scan, where the points that
  /// set the vertex are. A result above this may be a floor rather than the
  /// value.
  final int reversalBudgetAtVertexSteps;

  final FocuserBacklashConfidence confidence;

  /// Plain-language grounds for [confidence], for the operator to read.
  final String confidenceReason;

  /// When the measurement was taken, in UTC.
  final DateTime takenAt;

  /// Focuser temperature at the time, when the driver reported one.
  final double? temperatureCelsius;

  /// The build that took the measurement, so a figure can be traced to it.
  final String appVersion;

  /// The focuser this belongs to. A figure measured on one drive train says
  /// nothing about another, so nothing is read back without it.
  final String focuserDeviceId;

  /// The subset worth persisting: the figure, the conditions it was taken in,
  /// and the grounds for trusting it. The per-point scan data stays in the
  /// run's result, where the UI draws it — it is evidence for one run, not
  /// state the app carries forward.
  FocuserBacklashCalibrationRecord toRecord() =>
      FocuserBacklashCalibrationRecord(
        steps: steps,
        measurable: measurable,
        resolutionLimitSteps: resolutionLimitSteps,
        measuredAtPosition: measuredAtPosition,
        temperatureCelsius: temperatureCelsius,
        measuredAt: takenAt,
        confidence: confidence,
        confidenceReason: confidenceReason,
        appVersion: appVersion,
      );

  static FocuserBacklashCalibration? _fromJson(Object? json) {
    if (json is! Map) return null;
    final steps = json['steps'];
    final vertexDifference = json['vertex_difference'];
    final measurable = json['measurable'];
    final resolutionLimit = json['resolution_limit_steps'];
    final measuredAtPosition = json['measured_at_position'];
    final clearanceSteps = json['clearance_steps'];
    final reversalBudget = json['reversal_budget_steps'];
    final reversalBudgetAtVertex = json['reversal_budget_at_vertex_steps'];
    final confidence = FocuserBacklashConfidence.fromWire(json['confidence']);
    final confidenceReason = json['confidence_reason'];
    final below = FocuserBacklashScan._fromJson(json['below']);
    final above = FocuserBacklashScan._fromJson(json['above']);
    final context = json['context'];
    if (steps is! int ||
        vertexDifference is! int ||
        measurable is! bool ||
        resolutionLimit is! num ||
        measuredAtPosition is! int ||
        clearanceSteps is! int ||
        reversalBudget is! int ||
        reversalBudgetAtVertex is! int ||
        confidence == null ||
        confidenceReason is! String ||
        below == null ||
        above == null ||
        context is! Map) {
      return null;
    }
    final focuserDeviceId = context['focuser_device_id'];
    final takenAtRaw = context['taken_at'];
    final appVersion = context['app_version'];
    final temperature = context['temperature_celsius'];
    if (focuserDeviceId is! String ||
        takenAtRaw is! String ||
        appVersion is! String ||
        (temperature != null && temperature is! num)) {
      return null;
    }
    final takenAt = DateTime.tryParse(takenAtRaw);
    if (takenAt == null) return null;
    return FocuserBacklashCalibration(
      steps: steps,
      vertexDifference: vertexDifference,
      measurable: measurable,
      resolutionLimitSteps: resolutionLimit.toDouble(),
      below: below,
      above: above,
      measuredAtPosition: measuredAtPosition,
      clearanceSteps: clearanceSteps,
      reversalBudgetSteps: reversalBudget,
      reversalBudgetAtVertexSteps: reversalBudgetAtVertex,
      confidence: confidence,
      confidenceReason: confidenceReason,
      takenAt: takenAt.toUtc(),
      temperatureCelsius: (temperature as num?)?.toDouble(),
      appVersion: appVersion,
      focuserDeviceId: focuserDeviceId,
    );
  }
}

/// How a calibration run ended.
class FocuserBacklashResult {
  const FocuserBacklashResult({
    required this.kind,
    this.calibration,
    this.refusal,
  });

  final FocuserBacklashOutcomeKind kind;

  /// Null only for [FocuserBacklashOutcomeKind.refused].
  final FocuserBacklashCalibration? calibration;

  /// Non-null only for [FocuserBacklashOutcomeKind.refused].
  final FocuserBacklashRefusal? refusal;

  /// Whether a figure large enough to compensate came out of this run. False
  /// for a refusal and false for an honest "no measurable backlash".
  bool get hasFigure => kind == FocuserBacklashOutcomeKind.measured;

  /// Parse the outcome JSON `apiRunFocuserBacklashCalibration` returns.
  /// Returns null on anything that is not a complete outcome, so a partial or
  /// corrupt payload can never be shown as a result.
  static FocuserBacklashResult? tryParse(String json) {
    Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return null;
    }
    return fromJson(decoded);
  }

  static FocuserBacklashResult? fromJson(Object? decoded) {
    if (decoded is! Map) return null;
    final kind = FocuserBacklashOutcomeKind.fromWire(decoded['outcome']);
    if (kind == null) return null;
    if (kind == FocuserBacklashOutcomeKind.refused) {
      final refusal = decoded['refusal'];
      final message = decoded['message'];
      final remedy = decoded['remedy'];
      if (refusal is! Map || message is! String || remedy is! String) {
        return null;
      }
      final code = refusal['code'];
      if (code is! String) return null;
      return FocuserBacklashResult(
        kind: kind,
        refusal: FocuserBacklashRefusal(
          code: code,
          message: message,
          remedy: remedy,
        ),
      );
    }
    final calibration = FocuserBacklashCalibration._fromJson(
      decoded['calibration'],
    );
    if (calibration == null) return null;
    return FocuserBacklashResult(kind: kind, calibration: calibration);
  }
}

/// What a calibration run will cost, worked out by the code that will do it.
class FocuserBacklashCalibrationPlan {
  const FocuserBacklashCalibrationPlan({
    required this.pointsPerScan,
    required this.totalExposures,
    required this.scanLowPosition,
    required this.scanHighPosition,
    required this.travelLowPosition,
    required this.travelHighPosition,
    required this.estimatedDuration,
    required this.reversalBudgetSteps,
    required this.reversalBudgetAtVertexSteps,
  });

  final int pointsPerScan;
  final int totalExposures;

  /// The range the scans sample.
  final int scanLowPosition;
  final int scanHighPosition;

  /// The furthest the focuser will actually be commanded, which includes the
  /// run-up either side of the scan. This is the number that matters to an
  /// operator worried about hitting a travel limit.
  final int travelLowPosition;
  final int travelHighPosition;

  /// An estimate, and the UI says so: native assumes a fixed focuser move time
  /// and frame overhead per point rather than timing the rig.
  final Duration estimatedDuration;

  /// How far this run will reverse the drive train in total, and so the widest
  /// backlash it could possibly expose.
  final int reversalBudgetSteps;

  /// The reversal accumulated by the middle of the scan, where the vertex is
  /// set. A measurement above this may be a floor rather than a value.
  final int reversalBudgetAtVertexSteps;

  static FocuserBacklashCalibrationPlan? tryParse(String json) {
    Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final pointsPerScan = decoded['points_per_scan'];
    final totalExposures = decoded['total_exposures'];
    final scanLow = decoded['scan_low_position'];
    final scanHigh = decoded['scan_high_position'];
    final travelLow = decoded['travel_low_position'];
    final travelHigh = decoded['travel_high_position'];
    final durationSecs = decoded['estimated_duration_secs'];
    final reversalBudget = decoded['reversal_budget_steps'];
    final reversalBudgetAtVertex = decoded['reversal_budget_at_vertex_steps'];
    if (pointsPerScan is! int ||
        totalExposures is! int ||
        scanLow is! int ||
        scanHigh is! int ||
        travelLow is! int ||
        travelHigh is! int ||
        durationSecs is! num ||
        !durationSecs.toDouble().isFinite ||
        reversalBudget is! int ||
        reversalBudgetAtVertex is! int) {
      return null;
    }
    return FocuserBacklashCalibrationPlan(
      pointsPerScan: pointsPerScan,
      totalExposures: totalExposures,
      scanLowPosition: scanLow,
      scanHighPosition: scanHigh,
      travelLowPosition: travelLow,
      travelHighPosition: travelHigh,
      estimatedDuration: Duration(
        milliseconds: (durationSecs.toDouble() * 1000).round(),
      ),
      reversalBudgetSteps: reversalBudget,
      reversalBudgetAtVertexSteps: reversalBudgetAtVertex,
    );
  }
}

/// The config JSON a calibration run or plan is requested with.
///
/// Only the two values Dart has any business setting are sent: where to scan,
/// and which build is doing the measuring. Step size, run-up, exposure, fit
/// thresholds and the rest are left to the native defaults, which are derived
/// from the mechanics of the measurement and documented where they live.
/// Restating them here would give the product two answers to one question.
///
/// A null [centerPosition] means "wherever the focuser is now", which is the
/// operator's rough focus and the only place the measurement is worth taking.
String focuserBacklashCalibrationConfigJson({
  int? centerPosition,
  required String appVersion,
}) =>
    jsonEncode({'center_position': centerPosition, 'app_version': appVersion});
