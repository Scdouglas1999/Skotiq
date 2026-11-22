// The host sends a live stack's stats in one JSON form, over the stacking
// routes and inside its liveStack runtime channel. A linked client reads that
// form the same way whichever path brought it.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';

import '../../fakes/fakes.dart';

Map<String, Object?> _complete() => const LiveStackingStats(
  stackedFrameCount: 3,
  totalFramesAttempted: 5,
  rejectedAlignmentFailures: 1,
  avgMatchedPairs: 12.5,
  avgAlignmentResidual: 0.42,
  totalSigmaRejectedPixels: 128,
  totalIntegrationSecs: 900,
  filter: 'L',
  otherFilterFrames: 2,
  lastOtherFilter: 'R',
).toJson();

/// What a decoder made of a stats object: its JSON form, or 'refused'.
typedef _Outcome = Object?;

const _refused = 'refused';

final _rows = <(String, Map<String, Object?>, _Outcome)>[
  ('a complete object', _complete(), _complete()),
  (
    'whole-valued doubles for counts',
    {..._complete(), 'stackedFrameCount': 3.0},
    _complete(),
  ),
  (
    'an integer average',
    {..._complete(), 'avgMatchedPairs': 12},
    {..._complete(), 'avgMatchedPairs': 12.0},
  ),
  (
    'no filter fields (an unfiltered stack)',
    {..._complete()}
      ..remove('filter')
      ..remove('lastOtherFilter'),
    {..._complete(), 'filter': null, 'lastOtherFilter': null},
  ),
  (
    'a blank filter name',
    {..._complete(), 'filter': '  ', 'lastOtherFilter': ''},
    {..._complete(), 'filter': null, 'lastOtherFilter': null},
  ),
  (
    'no otherFilterFrames',
    {..._complete()}..remove('otherFilterFrames'),
    {..._complete(), 'otherFilterFrames': 0},
  ),
  (
    'a negative otherFilterFrames',
    {..._complete(), 'otherFilterFrames': -1},
    {..._complete(), 'otherFilterFrames': 0},
  ),
  (
    'no totalIntegrationSecs',
    {..._complete()}..remove('totalIntegrationSecs'),
    {..._complete(), 'totalIntegrationSecs': 0.0},
  ),
  (
    'a negative totalIntegrationSecs',
    {..._complete(), 'totalIntegrationSecs': -5},
    {..._complete(), 'totalIntegrationSecs': 0.0},
  ),
  (
    'a missing count',
    {..._complete()}..remove('stackedFrameCount'),
    _refused,
  ),
  (
    'a count as text',
    {..._complete(), 'totalFramesAttempted': 'five'},
    _refused,
  ),
  (
    'a fractional count',
    {..._complete(), 'rejectedAlignmentFailures': 1.5},
    _refused,
  ),
  (
    'a negative count',
    {..._complete(), 'totalSigmaRejectedPixels': -1},
    _refused,
  ),
  (
    'a missing average',
    {..._complete()}..remove('avgMatchedPairs'),
    _refused,
  ),
  (
    'a negative average',
    {..._complete(), 'avgAlignmentResidual': -0.1},
    _refused,
  ),
];

_Outcome _decodeChannel(Map<String, Object?> stats) {
  try {
    return LiveStackSlotSummary.fromJson(
      jsonDecode(
            jsonEncode({
              'filterKey': 'L',
              'stats': stats,
              'width': 2,
              'height': 2,
              'channels': 1,
              'revision': 1,
            }),
          )
          as Map<String, dynamic>,
    ).stats.toJson();
  } on FormatException {
    return _refused;
  }
}

Future<_Outcome> _decodeRest(Map<String, Object?> stats) async {
  final backend = NetworkBackend(
    serverHost: 'example.invalid',
    serverPort: 8080,
    webSocketPort: 8080,
    httpClient: FakeNetworkClient()
      ..setResponse(
        '/api/stacking/stats',
        body: jsonEncode({'stats': stats}),
      ),
    autoConnectWebSocket: false,
  );
  addTearDown(backend.dispose);
  try {
    return (await backend.stackingGetStats()).toJson();
  } on FormatException {
    return _refused;
  }
}

void main() {
  for (final (name, stats, expected) in _rows) {
    test('$name: the stacking routes read it as expected', () async {
      expect(await _decodeRest(stats), expected);
    });
    test('$name: the liveStack channel reads it as the routes do', () {
      expect(_decodeChannel(stats), expected);
    });
  }
}
