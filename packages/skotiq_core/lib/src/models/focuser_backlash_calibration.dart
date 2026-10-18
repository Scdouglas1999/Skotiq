import 'dart:convert';

import '../database/daos/settings_dao.dart';
import 'autofocus_progress.dart';
import 'imaging/imaging_models.dart'
    show AutofocusSettings, FilterAutofocusConfig;

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

/// The operator-tunable settings for a backlash calibration run.
///
/// One of these drives both halves of the feature: the dialog edits it, the
/// settings store persists it as a JSON blob, and
/// [focuserBacklashCalibrationConfigJson] folds it into the config native's
/// `BacklashCalibrationConfig` deserializes. The wire keys in [toJson] are
/// the struct's snake_case field names, so the persisted blob and the wire
/// payload share one vocabulary — a stored blob is simply a saved copy of
/// the fields that will be sent.
///
/// Values are seeded from the autofocus settings the operator has already
/// tuned for their rig (see [FocuserBacklashCalibrationSettings.seededFromAutofocus]),
/// not from native's defaults, because the autofocus sweep and the backlash
/// scans are sampling the same drawtube with the same camera.
class FocuserBacklashCalibrationSettings {
  const FocuserBacklashCalibrationSettings({
    required this.stepSize,
    required this.stepsOut,
    required this.clearanceSteps,
    required this.exposureDurationSecs,
    required this.exposuresPerPoint,
    required this.binning,
    this.gain,
    this.offset,
    required this.minStarCount,
    required this.rSquaredThreshold,
    required this.outerCropRatio,
    required this.innerCropRatio,
    required this.useBrightestNStars,
    required this.focuserSettleTimeMs,
    this.method = _defaultMethodWireName,
    required this.outlierRejectionSigma,
    required this.maxDurationSecs,
  });

  /// Sample spacing in focuser steps. Finer than a typical autofocus sweep
  /// step is healthy: the pair of fitted vertices can only be resolved to
  /// about half the spacing, and that resolution floors the measurement.
  final int stepSize;

  /// Points sampled either side of the centre per scan, so a scan has
  /// `2 * stepsOut + 1` points. Native requires 3–50.
  final int stepsOut;

  /// The run-up every point is approached with — the distance overshot
  /// before reversing onto the point, which is what loads the drive train
  /// onto one face of the dead band. Must exceed [stepSize].
  final int clearanceSteps;

  /// Exposure per frame, in seconds.
  final double exposureDurationSecs;

  /// Frames median-combined into each sampled point.
  final int exposuresPerPoint;

  /// 1, 2, 3 or 4 — serialized as the native `Binning` variant.
  final int binning;

  /// Camera gain for the run, or null to leave the camera's configured
  /// value — the same convention autofocus uses.
  final int? gain;

  /// Camera offset for the run, or null to leave the camera's configured
  /// value.
  final int? offset;

  /// Minimum detected stars for a frame to be usable.
  final int minStarCount;

  /// Fit quality floor below which a scan is refused rather than reported.
  final double rSquaredThreshold;

  /// Outer edge of the detection crop, as a fraction of the frame.
  final double outerCropRatio;

  /// Inner edge of the detection crop, as a fraction of the frame.
  final double innerCropRatio;

  /// Detection is limited to the N brightest stars.
  final int useBrightestNStars;

  /// Pause after each focuser move before exposing, in milliseconds.
  final int focuserSettleTimeMs;

  /// Native `AutofocusMethod` wire name — one of `VCurve`, `Quadratic`,
  /// `Hyperbolic`. Not offered in the dialog; it round-trips so a stored
  /// blob stays faithful.
  final String method;

  /// Sigma for the fit's outlier rejection pass.
  final double outlierRejectionSigma;

  /// Wall-clock ceiling for the whole run, in seconds.
  final double maxDurationSecs;

  /// The method the seeded settings start from. Native deliberately defaults
  /// this measurement to a parabola — a narrow scan either side of focus has
  /// none of the wide, deeply defocused wings a V-curve fit exists for — and
  /// the autofocus screen's curve-fitting option is a different enum for the
  /// wide sweep, so it is not mapped across.
  static const String _defaultMethodWireName = 'Quadratic';

  /// The wire names native's `Binning` enum serializes, in `binning` order.
  static const _binningWireNames = {1: 'One', 2: 'Two', 3: 'Three', 4: 'Four'};

  /// The wire names native's `AutofocusMethod` enum accepts.
  static const methodWireNames = {'VCurve', 'Quadratic', 'Hyperbolic'};

  /// Seed a run's settings from the autofocus configuration — the values the
  /// operator already tuned for this focuser and camera. [activeFilter] is
  /// the per-filter autofocus override for the currently selected filter,
  /// when there is one; autofocus applies it to exactly the fields it is
  /// read from here (exposure, binning, gain, offset).
  factory FocuserBacklashCalibrationSettings.seededFromAutofocus(
    AutofocusSettings autofocus, {
    FilterAutofocusConfig? activeFilter,
  }) {
    final stepSize = autofocus.stepSize;
    return FocuserBacklashCalibrationSettings(
      stepSize: stepSize,
      // The autofocus sweep's "steps out from centre" is the same quantity
      // this field sets. Native needs 3–50; a tuned autofocus value can only
      // fall outside that through a corrupted store, so clamp rather than
      // seed a config native would refuse.
      stepsOut: autofocus.initialOffsetSteps.clamp(3, 50),
      // Autofocus has no run-up concept — the validator only requires it
      // exceed the step size. The run-up sets the scan's reversal budget,
      // `(clearance - step) * points`, the widest dead band the run can
      // expose; 3x the step size keeps the seeded run compact while leaving
      // a budget of `2 * step * points`, several times the worst backlash
      // measured on the owner's rig. Operators with a coarser drive train
      // raise it.
      clearanceSteps: stepSize * 3,
      exposureDurationSecs:
          activeFilter?.afExposureTime ?? autofocus.exposureTime,
      exposuresPerPoint: autofocus.exposuresPerPoint.clamp(1, 20),
      binning: (activeFilter?.binning ?? autofocus.binning).clamp(1, 4),
      // Null means "the camera's configured value", which is exactly what
      // autofocus does when a filter has no override.
      gain: activeFilter?.gain,
      offset: activeFilter?.offset,
      // No autofocus equivalent exists for the detection floor; the value is
      // the one native's shared autofocus defaults carry.
      minStarCount: 10,
      rSquaredThreshold: autofocus.rSquaredThreshold.clamp(0.0, 1.0),
      outerCropRatio: autofocus.outerCropRatio.clamp(0.0, 1.0),
      innerCropRatio: autofocus.innerCropRatio.clamp(0.0, 1.0),
      useBrightestNStars: autofocus.useBrightestNStars,
      focuserSettleTimeMs: autofocus.focuserSettleTimeMs.clamp(0, 10000),
      // See _defaultMethodWireName: a parabola is the honest model for this
      // scan and the seeded settings keep it.
      method: _defaultMethodWireName,
      outlierRejectionSigma: 3.0,
      // Twenty minutes, native's ceiling — two scans at the seeded geometry
      // take a small fraction of that.
      maxDurationSecs: 1200.0,
    );
  }

  /// Resolve the settings a run should use: the operator's persisted choices
  /// when a stored blob parses, otherwise the autofocus-seeded defaults.
  ///
  /// A blob that parses but fails validation is still returned — the dialog
  /// shows the offending values with [problems] rather than silently
  /// discarding what was stored.
  static FocuserBacklashCalibrationSettings resolve(
    String storedJson, {
    required AutofocusSettings autofocus,
    FilterAutofocusConfig? activeFilter,
  }) =>
      tryParse(storedJson) ??
      FocuserBacklashCalibrationSettings.seededFromAutofocus(
        autofocus,
        activeFilter: activeFilter,
      );

  /// The fields as native's `BacklashCalibrationConfig` expects them. The
  /// persisted blob encodes exactly this map, and
  /// [focuserBacklashCalibrationConfigJson] adds the two run-scoped fields
  /// (`center_position`, `app_version`) on top.
  Map<String, Object?> toJson() => {
    'step_size': stepSize,
    'steps_out': stepsOut,
    'clearance_steps': clearanceSteps,
    'exposure_duration': exposureDurationSecs,
    'exposures_per_point': exposuresPerPoint,
    'binning':
        _binningWireNames[binning] ??
        (throw ArgumentError.value(
          binning,
          'binning',
          'must be 1, 2, 3 or 4 to map onto the native Binning enum',
        )),
    'gain': gain,
    'offset': offset,
    'min_star_count': minStarCount,
    'r_squared_threshold': rSquaredThreshold,
    'outer_crop_ratio': outerCropRatio,
    'inner_crop_ratio': innerCropRatio,
    'use_brightest_n_stars': useBrightestNStars,
    'focuser_settle_time_ms': focuserSettleTimeMs,
    'method': method,
    'outlier_rejection_sigma': outlierRejectionSigma,
    'max_duration_secs': maxDurationSecs,
  };

  FocuserBacklashCalibrationSettings copyWith({
    int? stepSize,
    int? stepsOut,
    int? clearanceSteps,
    double? exposureDurationSecs,
    int? exposuresPerPoint,
    int? binning,
    Object? gain = _unset,
    Object? offset = _unset,
    int? minStarCount,
    double? rSquaredThreshold,
    double? outerCropRatio,
    double? innerCropRatio,
    int? useBrightestNStars,
    int? focuserSettleTimeMs,
    String? method,
    double? outlierRejectionSigma,
    double? maxDurationSecs,
  }) => FocuserBacklashCalibrationSettings(
    stepSize: stepSize ?? this.stepSize,
    stepsOut: stepsOut ?? this.stepsOut,
    clearanceSteps: clearanceSteps ?? this.clearanceSteps,
    exposureDurationSecs: exposureDurationSecs ?? this.exposureDurationSecs,
    exposuresPerPoint: exposuresPerPoint ?? this.exposuresPerPoint,
    binning: binning ?? this.binning,
    gain: identical(gain, _unset) ? this.gain : gain as int?,
    offset: identical(offset, _unset) ? this.offset : offset as int?,
    minStarCount: minStarCount ?? this.minStarCount,
    rSquaredThreshold: rSquaredThreshold ?? this.rSquaredThreshold,
    outerCropRatio: outerCropRatio ?? this.outerCropRatio,
    innerCropRatio: innerCropRatio ?? this.innerCropRatio,
    useBrightestNStars: useBrightestNStars ?? this.useBrightestNStars,
    focuserSettleTimeMs: focuserSettleTimeMs ?? this.focuserSettleTimeMs,
    method: method ?? this.method,
    outlierRejectionSigma: outlierRejectionSigma ?? this.outlierRejectionSigma,
    maxDurationSecs: maxDurationSecs ?? this.maxDurationSecs,
  );

  /// Parse the persisted blob. Null on anything that does not decode to a
  /// complete settings map — a corrupt or truncated store falls back to the
  /// autofocus-seeded defaults rather than stranding the dialog.
  static FocuserBacklashCalibrationSettings? tryParse(String json) {
    Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    return tryParseMap(decoded);
  }

  /// Structural parse: every required field present with the right type.
  /// Enum fields are checked against their variant names here because the
  /// wire can only carry valid variants — that is a deserialization concern,
  /// not a [problems] rule. Value ranges are deliberately NOT checked; they
  /// are the validator's job, and a stored-but-invalid config is shown with
  /// its errors rather than discarded.
  static FocuserBacklashCalibrationSettings? tryParseMap(
    Map<dynamic, dynamic> json,
  ) {
    num? number(String key) => switch (json[key]) {
      final num v => v,
      _ => null,
    };

    final stepSize = number('step_size');
    final stepsOut = number('steps_out');
    final clearanceSteps = number('clearance_steps');
    final exposureDuration = number('exposure_duration');
    final exposuresPerPoint = number('exposures_per_point');
    final gain = json['gain'];
    final offset = json['offset'];
    final minStarCount = number('min_star_count');
    final rSquared = number('r_squared_threshold');
    final outerCrop = number('outer_crop_ratio');
    final innerCrop = number('inner_crop_ratio');
    final brightestN = number('use_brightest_n_stars');
    final settle = number('focuser_settle_time_ms');
    final sigma = number('outlier_rejection_sigma');
    final maxDuration = number('max_duration_secs');
    final method = json['method'];
    if (stepSize == null ||
        stepsOut == null ||
        clearanceSteps == null ||
        exposureDuration == null ||
        exposuresPerPoint == null ||
        (gain != null && gain is! num) ||
        (offset != null && offset is! num) ||
        minStarCount == null ||
        rSquared == null ||
        outerCrop == null ||
        innerCrop == null ||
        brightestN == null ||
        settle == null ||
        sigma == null ||
        maxDuration == null) {
      return null;
    }
    final binning = switch (json['binning']) {
      'One' => 1,
      'Two' => 2,
      'Three' => 3,
      'Four' => 4,
      _ => null,
    };
    if (binning == null) return null;
    // A missing method is a blob written before the field existed — take the
    // seeded value. A present but unknown one cannot cross the wire at all.
    if (method != null &&
        (method is! String || !methodWireNames.contains(method))) {
      return null;
    }
    return FocuserBacklashCalibrationSettings(
      stepSize: stepSize.toInt(),
      stepsOut: stepsOut.toInt(),
      clearanceSteps: clearanceSteps.toInt(),
      exposureDurationSecs: exposureDuration.toDouble(),
      exposuresPerPoint: exposuresPerPoint.toInt(),
      binning: binning,
      gain: (gain as num?)?.toInt(),
      offset: (offset as num?)?.toInt(),
      minStarCount: minStarCount.toInt(),
      rSquaredThreshold: rSquared.toDouble(),
      outerCropRatio: outerCrop.toDouble(),
      innerCropRatio: innerCrop.toDouble(),
      useBrightestNStars: brightestN.toInt(),
      focuserSettleTimeMs: settle.toInt(),
      method: (method as String?) ?? _defaultMethodWireName,
      outlierRejectionSigma: sigma.toDouble(),
      maxDurationSecs: maxDuration.toDouble(),
    );
  }

  /// The same rules native's `validate_backlash_calibration_config` enforces,
  /// in the same order, so the dialog can name the problem before a run is
  /// attempted. The messages are native's own wording — one vocabulary for
  /// the rule on both sides of the bridge.
  List<String> get problems {
    final issues = <String>[];
    if (!exposureDurationSecs.isFinite || exposureDurationSecs <= 0) {
      issues.add('Exposure duration must be finite and positive');
    }
    if (!maxDurationSecs.isFinite || maxDurationSecs <= 0) {
      issues.add('Maximum duration must be finite and positive');
    }
    if (stepSize <= 0) {
      issues.add('Step size must be positive');
    }
    if (stepsOut < 3 || stepsOut > 50) {
      issues.add(
        'Points either side of centre must be between 3 and 50 — fewer '
        'than 3 cannot describe a focus curve',
      );
    }
    if (clearanceSteps <= 0) {
      issues.add(
        'Run-up must be positive: with no run-up both scans approach every '
        'point the same way and there is no backlash to see',
      );
    }
    if (clearanceSteps <= stepSize) {
      issues.add(
        'Run-up ($clearanceSteps steps) must exceed the step size '
        '($stepSize steps), or moving to the next point already undoes '
        'the approach',
      );
    }
    if (exposuresPerPoint < 1 || exposuresPerPoint > 20) {
      issues.add('Exposures per point must be between 1 and 20');
    }
    if (!rSquaredThreshold.isFinite ||
        rSquaredThreshold < 0 ||
        rSquaredThreshold > 1) {
      issues.add('R² threshold must be between 0 and 1');
    }
    if (!outerCropRatio.isFinite ||
        !innerCropRatio.isFinite ||
        outerCropRatio <= 0 ||
        outerCropRatio > 1 ||
        innerCropRatio < 0 ||
        innerCropRatio >= outerCropRatio) {
      issues.add('Crop ratios must satisfy 0 <= inner < outer <= 1');
    }
    if (focuserSettleTimeMs > 10000) {
      issues.add('Focuser settle time cannot exceed 10000 ms');
    }
    if ((gain ?? 0) < 0 || (offset ?? 0) < 0) {
      issues.add('Gain and offset cannot be negative');
    }
    return issues;
  }

  bool get isValid => problems.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is FocuserBacklashCalibrationSettings &&
      stepSize == other.stepSize &&
      stepsOut == other.stepsOut &&
      clearanceSteps == other.clearanceSteps &&
      exposureDurationSecs == other.exposureDurationSecs &&
      exposuresPerPoint == other.exposuresPerPoint &&
      binning == other.binning &&
      gain == other.gain &&
      offset == other.offset &&
      minStarCount == other.minStarCount &&
      rSquaredThreshold == other.rSquaredThreshold &&
      outerCropRatio == other.outerCropRatio &&
      innerCropRatio == other.innerCropRatio &&
      useBrightestNStars == other.useBrightestNStars &&
      focuserSettleTimeMs == other.focuserSettleTimeMs &&
      method == other.method &&
      outlierRejectionSigma == other.outlierRejectionSigma &&
      maxDurationSecs == other.maxDurationSecs;

  @override
  int get hashCode => Object.hashAll([
    stepSize,
    stepsOut,
    clearanceSteps,
    exposureDurationSecs,
    exposuresPerPoint,
    binning,
    gain,
    offset,
    minStarCount,
    rSquaredThreshold,
    outerCropRatio,
    innerCropRatio,
    useBrightestNStars,
    focuserSettleTimeMs,
    method,
    outlierRejectionSigma,
    maxDurationSecs,
  ]);
}

/// Sentinel distinguishing "leave the field" from "set it to null" for the
/// nullable camera fields — the same device `AppSettingsState.copyWith` uses.
const Object _unset = Object();

/// The config JSON a calibration run or plan is requested with.
///
/// Every field of [settings] is sent under the snake_case key native's
/// `BacklashCalibrationConfig` expects, so the plan the dialog quotes and
/// the run it starts are the same configuration rather than two different
/// blends of native defaults.
///
/// A null [centerPosition] means "wherever the focuser is now", which is the
/// operator's rough focus and the only place the measurement is worth taking.
String focuserBacklashCalibrationConfigJson({
  required FocuserBacklashCalibrationSettings settings,
  int? centerPosition,
  required String appVersion,
}) => jsonEncode({
  ...settings.toJson(),
  'center_position': centerPosition,
  'app_version': appVersion,
});
