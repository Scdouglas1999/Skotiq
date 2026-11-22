import 'imaging_models.dart' show AutofocusSettings;

/// One operator-run autofocus: the camera and focuser it drives and the sweep
/// and measurement settings it runs with.
///
/// The backends take it whole (`DeviceBackend.autofocusStart`): the FFI
/// backend maps it to the bridge's `AutofocusConfigApi`, the network backend
/// sends [toWireJson] as the body of `POST /api/focuser/autofocus/start`, and
/// the host's handler reads it back with [AutofocusRequest.fromWireJson].
class AutofocusRequest {
  const AutofocusRequest({
    required this.deviceId,
    required this.cameraId,
    required this.exposureTime,
    required this.stepSize,
    required this.stepsOut,
    required this.method,
    required this.binning,
    required this.gain,
    required this.offset,
    required this.curveFitting,
    required this.numberOfAttempts,
    required this.exposuresPerPoint,
    required this.rSquaredThreshold,
    required this.outerCropRatio,
    required this.innerCropRatio,
    required this.useBrightestNStars,
    required this.focuserSettleTimeMs,
    required this.backlashCompMethod,
    required this.backlashIn,
    required this.backlashOut,
    required this.measuredBacklashIn,
    required this.failureHfrToleranceRatio,
  });

  /// The request a `POST /api/focuser/autofocus/start` body stands for.
  ///
  /// The body is published (OpenAPI, the web dashboard), so a field it leaves
  /// out takes the value this route has always given it, which is not always
  /// the operator's setting: an API caller who omits `backlashIn` gets no
  /// compensation rather than another focuser's figure. Numbers may arrive as
  /// numeric strings and integers as whole doubles; an empty string reads as
  /// absent. Throws [AutofocusRequestFieldError] naming the first field it
  /// cannot accept.
  factory AutofocusRequest.fromWireJson(Map<String, dynamic> json) {
    final reader = _WireReader(json);
    final deviceId = reader.requiredString('deviceId');
    final cameraId = reader.requiredString('cameraId');
    final exposureTime = reader.requiredDouble(
      'exposureTime',
      exposureTimeRange,
    );
    final stepSize = reader.requiredInt('stepSize', stepSizeRange);
    final stepsOut = reader.requiredInt('stepsOut', stepsOutRange);
    final method = reader.optionalString('method') ?? 'VCurve';
    final binning = reader.optionalInt('binning', binningRange) ?? 1;
    final gain = reader.optionalInt('gain', (min: 0, max: null));
    final offset = reader.optionalInt('offset', (min: 0, max: null));
    final curveFitting = reader.optionalString('curveFitting') ?? 'Hyperbolic';
    final numberOfAttempts =
        reader.optionalInt('numberOfAttempts', numberOfAttemptsRange) ?? 1;
    final exposuresPerPoint =
        reader.optionalInt('exposuresPerPoint', exposuresPerPointRange) ?? 1;
    final rSquaredThreshold =
        reader.optionalDouble('rSquaredThreshold', ratioRange) ?? 0.7;
    final outerCropRatio =
        reader.optionalDouble('outerCropRatio', ratioRange) ?? 1.0;
    final innerCropRatio =
        reader.optionalDouble('innerCropRatio', ratioRange) ?? 0.0;
    if (!cropRatiosValid(outer: outerCropRatio, inner: innerCropRatio)) {
      throw const AutofocusRequestFieldError(
        field: 'innerCropRatio/outerCropRatio',
        expected: '0 <= inner < outer <= 1',
        message: 'Crop ratios must satisfy 0 <= inner < outer <= 1',
      );
    }
    return AutofocusRequest(
      deviceId: deviceId,
      cameraId: cameraId,
      exposureTime: exposureTime,
      stepSize: stepSize,
      stepsOut: stepsOut,
      method: method,
      binning: binning,
      gain: gain,
      offset: offset,
      curveFitting: curveFitting,
      numberOfAttempts: numberOfAttempts,
      exposuresPerPoint: exposuresPerPoint,
      rSquaredThreshold: rSquaredThreshold,
      outerCropRatio: outerCropRatio,
      innerCropRatio: innerCropRatio,
      useBrightestNStars:
          reader.optionalInt('useBrightestNStars', useBrightestNStarsRange) ??
          10,
      focuserSettleTimeMs:
          reader.optionalInt('focuserSettleTimeMs', focuserSettleTimeMsRange) ??
          500,
      backlashCompMethod:
          reader.optionalString('backlashCompMethod') ?? 'Overshoot',
      backlashIn: reader.optionalInt('backlashIn', backlashRange) ?? 0,
      backlashOut: reader.optionalInt('backlashOut', backlashRange) ?? 0,
      failureHfrToleranceRatio:
          reader.optionalDouble(
            'failureHfrToleranceRatio',
            failureHfrToleranceRatioRange,
          ) ??
          const AutofocusSettings().failureHfrToleranceRatio,
      measuredBacklashIn: reader.optionalInt(
        'measuredBacklashIn',
        backlashRange,
      ),
    );
  }

  /// The values an operator-run autofocus accepts. The REST route refuses a
  /// body outside them and the in-app run refuses settings outside them.
  static const exposureTimeRange = (min: 0.1, max: 300.0);
  static const stepSizeRange = (min: 1, max: 10000);
  static const stepsOutRange = (min: 1, max: 50);
  static const binningRange = (min: 1, max: 4);
  static const numberOfAttemptsRange = (min: 1, max: 10);
  static const exposuresPerPointRange = (min: 1, max: 20);

  /// For the R² threshold and both crop ratios.
  static const ratioRange = (min: 0.0, max: 1.0);
  static const useBrightestNStarsRange = (min: 0, max: 500);
  static const focuserSettleTimeMsRange = (min: 0, max: 10000);

  /// For both backlash figures and a measured one.
  static const backlashRange = (min: 0, max: 10000);
  static const failureHfrToleranceRatioRange = (min: 0.0, max: 100.0);

  /// The crop ratios mark out a ring of the frame: `0 <= inner < outer <= 1`.
  static bool cropRatiosValid({required double outer, required double inner}) =>
      outer.isFinite &&
      inner.isFinite &&
      outer > 0 &&
      outer <= 1 &&
      inner >= 0 &&
      inner < outer;

  /// The focuser.
  final String deviceId;
  final String cameraId;
  final double exposureTime;
  final int stepSize;
  final int stepsOut;

  /// The star metric the operator chose (`Star HFR`, ...). The native sweep
  /// measures HFR whatever this says; [curveFitting] picks the fit.
  final String method;
  final int binning;
  final int? gain;
  final int? offset;

  /// The curve-fitting label from the Autofocus settings (`Hyperbolic`,
  /// `Parabolic`, `Trend Lines`).
  final String curveFitting;
  final int numberOfAttempts;
  final int exposuresPerPoint;
  final double rSquaredThreshold;
  final double outerCropRatio;
  final double innerCropRatio;
  final int useBrightestNStars;
  final int focuserSettleTimeMs;
  final String backlashCompMethod;
  final int backlashIn;
  final int backlashOut;

  /// Backlash this app measured on [deviceId], from its stored calibration,
  /// or null when it has never been calibrated. Never overrides
  /// [backlashIn]: a figure the operator typed outranks a measured one.
  final int? measuredBacklashIn;

  /// The operator's `afFailureHfrToleranceRatio`: how far above the
  /// reference HFR a failed autofocus may leave the frames and still be
  /// called usable, and the sweep's landing tolerance.
  final double failureHfrToleranceRatio;

  /// The body of `POST /api/focuser/autofocus/start`.
  Map<String, Object> toWireJson() => {
    'deviceId': deviceId,
    'cameraId': cameraId,
    'exposureTime': exposureTime,
    'stepSize': stepSize,
    'stepsOut': stepsOut,
    'method': method,
    'binning': binning,
    if (gain case final gain?) 'gain': gain,
    if (offset case final offset?) 'offset': offset,
    'curveFitting': curveFitting,
    'numberOfAttempts': numberOfAttempts,
    'exposuresPerPoint': exposuresPerPoint,
    'rSquaredThreshold': rSquaredThreshold,
    'outerCropRatio': outerCropRatio,
    'innerCropRatio': innerCropRatio,
    'useBrightestNStars': useBrightestNStars,
    'focuserSettleTimeMs': focuserSettleTimeMs,
    'backlashCompMethod': backlashCompMethod,
    'backlashIn': backlashIn,
    'backlashOut': backlashOut,
    if (measuredBacklashIn case final measured?) 'measuredBacklashIn': measured,
    'failureHfrToleranceRatio': failureHfrToleranceRatio,
  };
}

/// A `POST /api/focuser/autofocus/start` body field that
/// [AutofocusRequest.fromWireJson] cannot accept. [expected] names the kind of
/// value the field takes; [message] says what was wrong with the one sent,
/// when that is more than its absence or its kind.
class AutofocusRequestFieldError implements Exception {
  const AutofocusRequestFieldError({
    required this.field,
    required this.expected,
    this.message,
  });

  final String field;
  final String expected;
  final String? message;

  @override
  String toString() =>
      'AutofocusRequestFieldError(field=$field, expected=$expected'
      '${message == null ? '' : ', $message'})';
}

typedef _Range<T extends num> = ({T min, T? max});

/// Reads body fields the way the headless API's request validation does.
class _WireReader {
  _WireReader(this.json);

  final Map<String, dynamic> json;

  String requiredString(String field) {
    final value = json[field];
    if (value is! String) {
      throw AutofocusRequestFieldError(field: field, expected: 'string');
    }
    if (value.isEmpty) {
      throw AutofocusRequestFieldError(
        field: field,
        expected: 'string',
        message: 'Value must not be empty',
      );
    }
    return value;
  }

  String? optionalString(String field) {
    final value = json[field];
    if (value == null) return null;
    if (value is! String) {
      throw AutofocusRequestFieldError(field: field, expected: 'string');
    }
    return value.isEmpty ? null : value;
  }

  int requiredInt(String field, _Range<int> range) {
    final value = json[field];
    final parsed = switch (value) {
      final int whole => whole,
      final double number
          when number.isFinite && number == number.toInt().toDouble() =>
        number.toInt(),
      final String text => int.tryParse(text),
      _ => null,
    };
    if (parsed == null) {
      throw AutofocusRequestFieldError(field: field, expected: 'integer');
    }
    _checkRange(
      field,
      parsed.toDouble(),
      range.min.toDouble(),
      range.max?.toDouble(),
    );
    return parsed;
  }

  int? optionalInt(String field, _Range<int> range) =>
      json[field] == null ? null : requiredInt(field, range);

  double requiredDouble(String field, _Range<double> range) {
    final value = json[field];
    final parsed = switch (value) {
      final num number => number.toDouble(),
      final String text => double.tryParse(text),
      _ => null,
    };
    if (parsed == null) {
      throw AutofocusRequestFieldError(field: field, expected: 'number');
    }
    if (!parsed.isFinite) {
      throw AutofocusRequestFieldError(
        field: field,
        expected: 'number',
        message: 'Value must be finite',
      );
    }
    _checkRange(field, parsed, range.min, range.max);
    return parsed;
  }

  double? optionalDouble(String field, _Range<double> range) =>
      json[field] == null ? null : requiredDouble(field, range);

  static void _checkRange(String field, double value, double min, double? max) {
    if (value < min) {
      throw AutofocusRequestFieldError(
        field: field,
        expected: 'number',
        message: 'Value must be >= $min',
      );
    }
    if (max != null && value > max) {
      throw AutofocusRequestFieldError(
        field: field,
        expected: 'number',
        message: 'Value must be <= $max',
      );
    }
  }
}
