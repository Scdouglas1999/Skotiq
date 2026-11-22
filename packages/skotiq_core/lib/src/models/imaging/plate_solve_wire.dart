import 'dart:typed_data';

import 'package:skotiq_bridge/skotiq_bridge.dart' show PlateSolveResult;

/// The JSON form of a plate solve, used by the headless REST result
/// (`POST /api/plate-solve` jobs, documented in `docs/api/data-models.md`) and
/// by the plate-solve runtime channel.
///
/// A value the solve did not measure (a coordinate-only solve) is NaN in
/// [PlateSolveResult] and `null` here, since JSON has no NaN. A key that is
/// missing is a producer that does not send it, such as a solve with no
/// distortion model: its CD terms and SIP orders read as 0 and its SIP
/// coefficient lists as empty.
Map<String, Object?> plateSolveResultToJson(PlateSolveResult solve) => {
  'success': solve.success,
  'ra': _finite(solve.ra),
  'dec': _finite(solve.dec),
  'pixelScale': _finite(solve.pixelScale),
  'rotation': _finite(solve.rotation),
  'fieldWidth': _finite(solve.fieldWidth),
  'fieldHeight': _finite(solve.fieldHeight),
  'solveTimeSecs': _finite(solve.solveTimeSecs),
  'error': solve.error,
  'cd11': _finite(solve.cd11),
  'cd12': _finite(solve.cd12),
  'cd21': _finite(solve.cd21),
  'cd22': _finite(solve.cd22),
  'sipAOrder': solve.sipAOrder,
  'sipBOrder': solve.sipBOrder,
  'sipApOrder': solve.sipApOrder,
  'sipBpOrder': solve.sipBpOrder,
  'sipACoeffs': _coeffs(solve.sipACoeffs),
  'sipBCoeffs': _coeffs(solve.sipBCoeffs),
  'sipApCoeffs': _coeffs(solve.sipApCoeffs),
  'sipBpCoeffs': _coeffs(solve.sipBpCoeffs),
};

/// The solve [json] describes. Throws [FormatException] when the sky
/// position or a measurement key is missing or not a number.
PlateSolveResult plateSolveResultFromJson(Map<String, dynamic> json) {
  double required(String key) {
    final value = json[key];
    if (value is num) return value.toDouble();
    throw FormatException('Plate solve has no number "$key"');
  }

  double measurement(String key) =>
      json.containsKey(key) && json[key] == null ? double.nan : required(key);

  double term(String key) {
    if (!json.containsKey(key)) return 0;
    final value = json[key];
    return value is num ? value.toDouble() : double.nan;
  }

  int order(String key) => (json[key] as num?)?.toInt() ?? 0;

  Float64List coeffs(String key) {
    final raw = json[key];
    if (raw == null) return Float64List(0);
    if (raw is! List) {
      throw FormatException('Plate solve "$key" is not a list');
    }
    return Float64List.fromList([
      for (final v in raw)
        if (v == null)
          double.nan
        else if (v is num)
          v.toDouble()
        else
          throw FormatException('Plate solve "$key" holds a non-number'),
    ]);
  }

  final error = json['error'];
  return PlateSolveResult(
    success: json['success'] == true,
    ra: required('ra'),
    dec: required('dec'),
    pixelScale: measurement('pixelScale'),
    rotation: measurement('rotation'),
    fieldWidth: measurement('fieldWidth'),
    fieldHeight: measurement('fieldHeight'),
    solveTimeSecs: measurement('solveTimeSecs'),
    error: error is String ? error : null,
    cd11: term('cd11'),
    cd12: term('cd12'),
    cd21: term('cd21'),
    cd22: term('cd22'),
    sipAOrder: order('sipAOrder'),
    sipBOrder: order('sipBOrder'),
    sipApOrder: order('sipApOrder'),
    sipBpOrder: order('sipBpOrder'),
    sipACoeffs: coeffs('sipACoeffs'),
    sipBCoeffs: coeffs('sipBCoeffs'),
    sipApCoeffs: coeffs('sipApCoeffs'),
    sipBpCoeffs: coeffs('sipBpCoeffs'),
  );
}

double? _finite(double value) => value.isFinite ? value : null;

List<double?> _coeffs(Float64List values) => [
  for (final v in values) _finite(v),
];
