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

List<double> _coeffs(Float64List values) => [
  for (final v in values) finiteOrNull(v) ?? 0.0,
];

Float64List _decodeCoeffs(Object? raw) => Float64List.fromList([
  if (raw is List)
    for (final v in raw) v is num ? v.toDouble() : 0.0,
]);

Map<String, dynamic> encodePlateSolveResult(PlateSolveResult r) => {
  'success': r.success,
  'ra': finiteOrNull(r.ra) ?? 0.0,
  'dec': finiteOrNull(r.dec) ?? 0.0,
  'pixelScale': finiteOrNull(r.pixelScale) ?? 0.0,
  'rotation': finiteOrNull(r.rotation) ?? 0.0,
  'fieldWidth': finiteOrNull(r.fieldWidth) ?? 0.0,
  'fieldHeight': finiteOrNull(r.fieldHeight) ?? 0.0,
  'solveTimeSecs': finiteOrNull(r.solveTimeSecs) ?? 0.0,
  if (r.error != null) 'error': r.error,
  'cd': [
    finiteOrNull(r.cd11) ?? 0.0,
    finiteOrNull(r.cd12) ?? 0.0,
    finiteOrNull(r.cd21) ?? 0.0,
    finiteOrNull(r.cd22) ?? 0.0,
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
    ra: jsonDouble(json['ra']) ?? 0,
    dec: jsonDouble(json['dec']) ?? 0,
    pixelScale: jsonDouble(json['pixelScale']) ?? 0,
    rotation: jsonDouble(json['rotation']) ?? 0,
    fieldWidth: jsonDouble(json['fieldWidth']) ?? 0,
    fieldHeight: jsonDouble(json['fieldHeight']) ?? 0,
    solveTimeSecs: jsonDouble(json['solveTimeSecs']) ?? 0,
    error: jsonString(json['error']),
    cd11: cdAt(0),
    cd12: cdAt(1),
    cd21: cdAt(2),
    cd22: cdAt(3),
    sipAOrder: jsonInt(json['sipAOrder']) ?? 0,
    sipBOrder: jsonInt(json['sipBOrder']) ?? 0,
    sipApOrder: jsonInt(json['sipApOrder']) ?? 0,
    sipBpOrder: jsonInt(json['sipBpOrder']) ?? 0,
    sipACoeffs: _decodeCoeffs(json['sipA']),
    sipBCoeffs: _decodeCoeffs(json['sipB']),
    sipApCoeffs: _decodeCoeffs(json['sipAp']),
    sipBpCoeffs: _decodeCoeffs(json['sipBp']),
  );
}
