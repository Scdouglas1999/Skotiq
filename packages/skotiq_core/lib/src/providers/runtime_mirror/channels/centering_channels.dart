import '../../../services/centering_service.dart';
import '../runtime_mirror_channel.dart';

/// Progress of a centering run (state, attempt, offset). Centering is a loop
/// in the process whose operator started it, so a run started on a client is
/// reported to the host and one started on the host reaches every client.
class CenteringStatusChannel extends RuntimeMirrorChannel<CenteringStatus> {
  const CenteringStatusChannel();

  @override
  String get key => 'centeringStatus';

  @override
  get source => centeringStatusProvider;

  @override
  Duration get minInterval => const Duration(milliseconds: 250);

  @override
  bool get clientReports => true;

  @override
  Map<String, dynamic>? encode(CenteringStatus value) => {
    'state': value.state.name,
    'currentIteration': value.currentIteration,
    'maxIterations': value.maxIterations,
    'offsetArcsec': finiteOrNull(value.currentOffsetArcsec),
    'offsetArcmin': finiteOrNull(value.currentOffsetArcmin),
    if (value.message != null) 'message': value.message,
    'iterations': [for (final i in value.iterationHistory) _encodeIteration(i)],
    if (value.lastImagePath != null) 'lastImagePath': value.lastImagePath,
    'solvedRa': finiteOrNull(value.solvedRa),
    'solvedDec': finiteOrNull(value.solvedDec),
  };

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    context.read(centeringStatusProvider.notifier).state = value == null
        ? CenteringStatus.idle()
        : CenteringStatus(
            state: CenteringState.values.firstWhere(
              (s) => s.name == value['state'],
              orElse: () => CenteringState.idle,
            ),
            currentIteration: requireInt(value, 'currentIteration'),
            maxIterations: requireInt(value, 'maxIterations'),
            currentOffsetArcsec: jsonDouble(value['offsetArcsec']),
            currentOffsetArcmin: jsonDouble(value['offsetArcmin']),
            message: jsonString(value['message']),
            iterationHistory: _decodeIterations(value['iterations']),
            lastImagePath: jsonString(value['lastImagePath']),
            solvedRa: jsonDouble(value['solvedRa']),
            solvedDec: jsonDouble(value['solvedDec']),
          );
  }
}

/// The outcome of the last centering run, which the Solve tab's recent-solves
/// list and the centering dialog show.
class CenteringResultChannel extends RuntimeMirrorChannel<CenteringResult?> {
  const CenteringResultChannel();

  @override
  String get key => 'centeringResult';

  @override
  get source => lastCenteringResultProvider;

  @override
  bool get clientReports => true;

  @override
  Map<String, dynamic>? encode(CenteringResult? value) {
    if (value == null) return null;
    return {
      'success': value.success,
      'finalOffsetArcsec': finiteOrNull(value.finalOffsetArcsec),
      'iterations': value.iterations,
      if (value.errorMessage != null) 'error': value.errorMessage,
      'history': [for (final i in value.iterationHistory) _encodeIteration(i)],
    };
  }

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    context.read(lastCenteringResultProvider.notifier).state = value == null
        ? null
        : CenteringResult(
            success: value['success'] == true,
            finalOffsetArcsec: jsonDouble(value['finalOffsetArcsec']),
            iterations: requireInt(value, 'iterations'),
            errorMessage: jsonString(value['error']),
            iterationHistory: _decodeIterations(value['history']),
          );
  }
}

Map<String, dynamic> _encodeIteration(CenteringIteration i) => {
  'n': i.iterationNumber,
  'solvedRa': finiteOrNull(i.solvedRa),
  'solvedDec': finiteOrNull(i.solvedDec),
  'targetRa': finiteOrNull(i.targetRa),
  'targetDec': finiteOrNull(i.targetDec),
  'offsetArcsec': finiteOrNull(i.offsetArcsec),
  'offsetArcmin': finiteOrNull(i.offsetArcmin),
  'solved': i.plateSolveSuccess,
  if (i.errorMessage != null) 'error': i.errorMessage,
  'at': i.timestamp.toUtc().millisecondsSinceEpoch,
};

List<CenteringIteration> _decodeIterations(Object? raw) => [
  if (raw is List)
    for (final item in raw.whereType<Map>())
      CenteringIteration(
        iterationNumber: requireInt(item, 'n'),
        solvedRa: jsonDouble(item['solvedRa']),
        solvedDec: jsonDouble(item['solvedDec']),
        targetRa: jsonDouble(item['targetRa']),
        targetDec: jsonDouble(item['targetDec']),
        offsetArcsec: jsonDouble(item['offsetArcsec']),
        offsetArcmin: jsonDouble(item['offsetArcmin']),
        plateSolveSuccess: item['solved'] == true,
        errorMessage: jsonString(item['error']),
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          requireInt(item, 'at'),
          isUtc: true,
        ),
      ),
];
