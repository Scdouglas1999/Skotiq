import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../fakes/fake_network_client.dart';

Map<String, dynamic> tile(int image, int row, double value) => {
  'id': row,
  'capturedImageId': image,
  'sessionId': 9,
  'timestamp': 1793075534000 + image,
  'layerType': 'background',
  'tileRow': 0,
  'tileCol': 0,
  'sampleCount': 21170,
  'value': value,
  'p05': 28144.0,
  'p50': 29136.0,
  'p95': 30160.0,
  'auxValue': 593.04,
};
Map<String, dynamic> bundle(
  List<Map<String, dynamic>> tiles,
  Map<String, String> versions,
) => {
  for (final key in [
    'photometry',
    'calibrations',
    'transparency',
    'psfTiles',
    'frameQuality',
    'residuals',
    'movingObjects',
    'lineRatios',
  ])
    key: [],
  'tileMetrics': tiles,
  'spatialVersions': {'psfTiles': {}, 'residuals': {}, 'tileMetrics': versions},
};

void main() {
  test(
    'client retains unchanged maps and replaces or removes changed frames',
    () async {
      final fake = FakeNetworkClient();
      final backend = NetworkBackend(
        serverHost: 'localhost',
        serverPort: 8099,
        httpClient: fake,
        autoConnectWebSocket: false,
      );
      addTearDown(backend.dispose);
      void respond(Map<String, dynamic> data, {String method = 'POST'}) =>
          fake.setResponse(
            '/api/science/session/9/bundle',
            method: method,
            body: jsonEncode(data),
          );
      respond(
        bundle([tile(1, 1, 10), tile(2, 2, 20)], {'1': '1:1', '2': '1:2'}),
        method: 'GET',
      );
      final first = await backend.getScienceSessionBundle(9);
      expect(first.tileMetrics, hasLength(2));
      respond(bundle([], {'1': '1:1', '2': '1:2'}));
      final unchanged = await backend.getScienceSessionBundle(9);
      expect(identical(first.tileMetrics, unchanged.tileMetrics), isTrue);
      respond(bundle([tile(3, 3, 30)], {'1': '1:1', '2': '1:2', '3': '1:3'}));
      expect(
        (await backend.getScienceSessionBundle(9)).tileMetrics,
        hasLength(3),
      );
      respond(bundle([tile(1, 4, 70)], {'1': '1:4', '3': '1:3'}));
      final reprocessed = await backend.getScienceSessionBundle(9);
      expect(reprocessed.tileMetrics.map((r) => r.capturedImageId).toSet(), {
        1,
        3,
      });
      expect(
        reprocessed.tileMetrics.firstWhere((r) => r.capturedImageId == 1).value,
        70,
      );
      respond(bundle([], {}));
      expect((await backend.getScienceSessionBundle(9)).tileMetrics, isEmpty);
    },
  );
}
