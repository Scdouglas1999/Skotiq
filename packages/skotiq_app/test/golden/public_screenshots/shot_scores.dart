// The native scorer's night scores for the screenshots' night, replayed from
// a recording: `flutter test` has no native library to score with.
import 'dart:convert';
import 'dart:io';

import 'package:skotiq_bridge/skotiq_bridge.dart'
    show
        ApiFloorSample,
        ApiNightScore,
        ApiNightSky,
        ApiNightTarget,
        ApiSchedulerTarget,
        ApiScoringWeights,
        ApiTargetScoreNow;
import 'package:skotiq_core/backend.dart' show TargetScoring, TargetScoringWire;

import '../surface_golden_harness.dart';

/// Answers the night scoring request the screenshots make with the scores the
/// native scorer gave for it, matched by catalog position (see
/// `test/fixtures/README.md`). A request that differs from the recorded one
/// (another night, site, moon, floor, weights or catalog) throws: the
/// recording no longer describes it.
class RecordedNightScoring implements TargetScoring {
  RecordedNightScoring._(this._request, this._targetCount, this._scores);

  factory RecordedNightScoring.load() {
    final file = File(
      '${SurfaceGoldenHarness.repoRoot().path}/'
      'packages/skotiq_app/test/fixtures/night_scores.json.gz',
    );
    final json = jsonDecode(utf8.decode(gzip.decode(file.readAsBytesSync())))
        as Map<String, dynamic>;
    return RecordedNightScoring._(
      json['request'] as Map<String, dynamic>,
      json['targetCount'] as int,
      {
        for (final s in (json['scores'] as List).cast<Map<String, dynamic>>())
          _position(s['raDeg'] as num, s['decDeg'] as num): s,
      },
    );
  }

  /// Why the last request was refused. The planner shows a refused plan as
  /// "Failed to generate plan", so a shot reads this to say why.
  String? refusal;

  final Map<String, dynamic> _request;
  final int _targetCount;
  final Map<(double, double), Map<String, dynamic>> _scores;

  static (double, double) _position(num ra, num dec) =>
      (ra.toDouble(), dec.toDouble());

  @override
  Future<List<ApiNightScore>> scoreTargetsForNight({
    required ApiNightSky sky,
    required List<ApiNightTarget> targets,
    required ApiScoringWeights weights,
  }) async {
    final request = TargetScoringWire.nightRequest(
      sky: sky,
      targets: const [],
      weights: weights,
    )..removeWhere((key, _) => const {'ids', 'raDeg', 'decDeg'}.contains(key));
    final drift = _differences(_request, request, '');
    if (targets.length != _targetCount) {
      drift.add('targets: recorded $_targetCount, asked ${targets.length}');
    }
    if (drift.isNotEmpty) {
      refusal = 'The recorded night scores are for another request '
          '(${drift.join('; ')}). Run the screenshots with '
          'TZ=America/New_York, or record the scores again as '
          'test/fixtures/README.md describes.';
      throw StateError(refusal!);
    }
    return TargetScoringWire.readNightResponse([
      for (final t in targets)
        if (_scores[_position(t.raDeg, t.decDeg)] case final s?)
          {...s, 'targetId': t.id},
    ]);
  }

  @override
  Future<List<ApiTargetScoreNow>> rankSchedulerTargets({
    required double latitudeDeg,
    required double longitudeDeg,
    required int nowUnixMs,
    required List<ApiSchedulerTarget> targets,
    required ApiScoringWeights weights,
    required List<ApiFloorSample> floor,
  }) =>
      throw StateError(
        'No TargetScheduler ranking is recorded for the screenshots.',
      );
}

/// Where [asked] differs from [recorded]; numbers agree within 1e-9 so a
/// last-digit difference in the moon's position is not drift.
List<String> _differences(Object? recorded, Object? asked, String path) {
  if (recorded is num && asked is num) {
    return (recorded - asked).abs() <= 1e-9
        ? []
        : ['$path: recorded $recorded, asked $asked'];
  }
  if (recorded is Map && asked is Map) {
    return [
      for (final key in {...recorded.keys, ...asked.keys})
        ..._differences(recorded[key], asked[key], '$path.$key'),
    ];
  }
  if (recorded is List && asked is List) {
    if (recorded.length != asked.length) {
      return [
        '$path: recorded ${recorded.length} entries, '
            'asked ${asked.length}'
      ];
    }
    return [
      for (var i = 0; i < recorded.length; i++)
        ..._differences(recorded[i], asked[i], '$path[$i]'),
    ];
  }
  return recorded == asked ? [] : ['$path: recorded $recorded, asked $asked'];
}
