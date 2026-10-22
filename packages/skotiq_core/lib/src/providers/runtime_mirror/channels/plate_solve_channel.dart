import 'dart:typed_data';

import '../../../backend/skotiq_backend.dart' show PlateSolveResult;
import '../../../services/plate_solve_service.dart';
import '../runtime_mirror_channel.dart';

/// The host's plate-solve state: whether a solve is running and the last
/// result, which the Tonight Solve tab, the frame stage and the recent-solves
/// list read.
///
/// Host to client only. A solve a client starts already runs on the host
/// (`POST /api/plate-solve` goes through the host's [PlateSolveService]), so the
/// host's own state records it without a report.
class PlateSolveChannel extends RuntimeMirrorChannel<PlateSolveState> {
  const PlateSolveChannel();

  @override
  String get key => 'plateSolve';

  @override
  get source => plateSolveStateProvider;

  @override
  Map<String, dynamic>? encode(PlateSolveState value) {
    final result = value.lastResult;
    if (!value.isSolving && result == null) return null;
    return {
      'isSolving': value.isSolving,
      if (value.currentImage != null) 'currentImage': value.currentImage,
      if (result != null) 'result': encodePlateSolveResult(result),
    };
  }

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    final controller = context.read(plateSolveStateProvider.notifier);
    if (value == null) {
      controller.state = const PlateSolveState();
      return;
    }
    final current = controller.state;
    final raw = value['result'];
    final decoded = raw is Map
        ? decodePlateSolveResult(Map<String, dynamic>.from(raw))
        : null;
    // The same outcome keeps the object already held, so listeners that key on
    // identity (the recent-solves list) do not record one solve twice when the
    // client's own result and the host's broadcast of it both arrive.
    final lastResult =
        decoded != null &&
            current.lastResult != null &&
            samePlateSolveOutcome(current.lastResult!, decoded)
        ? current.lastResult
        : decoded ?? current.lastResult;
    controller.state = PlateSolveState(
      isSolving: value['isSolving'] == true,
      lastResult: lastResult,
      currentImage: jsonString(value['currentImage']) ?? current.currentImage,
    );
  }
}

List<double?> _coeffs(Float64List values) => [
  for (final v in values) finiteOrNull(v),
];

Float64List _decodeCoeffs(Object? raw) {
  if (raw is! List) throw const FormatException('Solve has no coefficients');
  return Float64List.fromList([
    for (final v in raw)
      if (v is num)
        v.toDouble()
      else
        throw const FormatException('Solve coefficient is not a number'),
  ]);
}

Map<String, dynamic> encodePlateSolveResult(PlateSolveResult r) => {
  'success': r.success,
  'ra': finiteOrNull(r.ra),
  'dec': finiteOrNull(r.dec),
  'pixelScale': finiteOrNull(r.pixelScale),
  'rotation': finiteOrNull(r.rotation),
  'fieldWidth': finiteOrNull(r.fieldWidth),
  'fieldHeight': finiteOrNull(r.fieldHeight),
  'solveTimeSecs': finiteOrNull(r.solveTimeSecs),
  if (r.error != null) 'error': r.error,
  'cd': [
    finiteOrNull(r.cd11),
    finiteOrNull(r.cd12),
    finiteOrNull(r.cd21),
    finiteOrNull(r.cd22),
  ],
  'sipAOrder': r.sipAOrder,
  'sipBOrder': r.sipBOrder,
  'sipApOrder': r.sipApOrder,
  'sipBpOrder': r.sipBpOrder,
  'sipA': _coeffs(r.sipACoeffs),
  'sipB': _coeffs(r.sipBCoeffs),
  'sipAp': _coeffs(r.sipApCoeffs),
  'sipBp': _coeffs(r.sipBpCoeffs),
};

PlateSolveResult decodePlateSolveResult(Map<String, dynamic> json) {
  final cd = json['cd'];
  double cdAt(int i) => cd is List && cd.length > i && cd[i] is num
      ? (cd[i] as num).toDouble()
      : 0;
  return PlateSolveResult(
    success: json['success'] == true,
    ra: requireDouble(json, 'ra'),
    dec: requireDouble(json, 'dec'),
    pixelScale: requireDouble(json, 'pixelScale'),
    rotation: requireDouble(json, 'rotation'),
    fieldWidth: requireDouble(json, 'fieldWidth'),
    fieldHeight: requireDouble(json, 'fieldHeight'),
    solveTimeSecs: requireDouble(json, 'solveTimeSecs'),
    error: jsonString(json['error']),
    cd11: cdAt(0),
    cd12: cdAt(1),
    cd21: cdAt(2),
    cd22: cdAt(3),
    sipAOrder: requireInt(json, 'sipAOrder'),
    sipBOrder: requireInt(json, 'sipBOrder'),
    sipApOrder: requireInt(json, 'sipApOrder'),
    sipBpOrder: requireInt(json, 'sipBpOrder'),
    sipACoeffs: _decodeCoeffs(json['sipA']),
    sipBCoeffs: _decodeCoeffs(json['sipB']),
    sipApCoeffs: _decodeCoeffs(json['sipAp']),
    sipBpCoeffs: _decodeCoeffs(json['sipBp']),
  );
}
