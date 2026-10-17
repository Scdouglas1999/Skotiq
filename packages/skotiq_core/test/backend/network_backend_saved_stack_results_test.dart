import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';

import '../fakes/fakes.dart';

NetworkBackend _backend(FakeNetworkClient fake) => NetworkBackend(
  serverHost: 'example.invalid',
  serverPort: 8080,
  webSocketPort: 8080,
  httpClient: fake,
  autoConnectWebSocket: false,
);

Map<String, Object?> _savedResult({
  Object id = 7,
  Object width = 2,
  Object height = 1,
  Object framesStacked = 5,
  Object framesAttempted = 6,
  Object integrationSecs = 300.0,
  Object avgAlignmentResidual = 0.3,
  Object isColor = true,
  Object channels = 3,
  Object createdAt = '2026-07-14T01:02:03.000Z',
  Object previewAvailable = true,
}) => {
  'id': id,
  'sessionId': 9,
  'targetId': null,
  'targetName': 'M81',
  'width': width,
  'height': height,
  'framesStacked': framesStacked,
  'framesAttempted': framesAttempted,
  'integrationSecs': integrationSecs,
  'avgAlignmentResidual': avgAlignmentResidual,
  'avgHfr': 2.1,
  'filter': 'OSC',
  'isColor': isColor,
  'channels': channels,
  'createdAt': createdAt,
  'previewAvailable': previewAvailable,
};

void main() {
  test('saved result metadata decodes strictly without a host path', () async {
    final fake = FakeNetworkClient()
      ..setResponse(
        '/api/stacking/results/7',
        body: jsonEncode({'result': _savedResult()}),
      );
    final backend = _backend(fake);
    addTearDown(backend.dispose);

    final remote = await backend.stackingGetSavedResult(7);

    expect(remote.previewAvailable, isTrue);
    expect(remote.result.id, 7);
    expect(remote.result.targetName, 'M81');
    expect(remote.result.channels, 3);
    expect(remote.result.isColor, isTrue);
    expect(remote.result.exportedImagePath, isNull);
    expect(remote.result.stats.stackedFrameCount, 5);
  });

  test(
    'saved result list honours the bounded limit and preserves order',
    () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/stacking/results',
          body: jsonEncode({
            'results': [_savedResult(), _savedResult(id: 6)],
          }),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      final results = await backend.stackingGetSavedResults(limit: 2);

      expect(results.map((item) => item.result.id), [7, 6]);
      expect(fake.requests.single.url.queryParameters['limit'], '2');
    },
  );

  test('saved preview accepts only a non-empty PNG or JPEG response', () async {
    final fake = FakeNetworkClient()
      ..setBinaryResponse(
        '/api/stacking/results/7/preview',
        bodyBytes: const [137, 80, 78, 71],
        headers: const {'content-type': 'image/png'},
      );
    final backend = _backend(fake);
    addTearDown(backend.dispose);

    expect(await backend.stackingGetSavedResultPreview(7), [137, 80, 78, 71]);
  });

  test(
    'metadata rejects contradictory color and channel declarations',
    () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/stacking/results/7',
          body: jsonEncode({
            'result': _savedResult(isColor: false, channels: 3),
          }),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      await expectLater(
        backend.stackingGetSavedResult(7),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('metadata rejects impossible frame accounting', () async {
    final fake = FakeNetworkClient()
      ..setResponse(
        '/api/stacking/results/7',
        body: jsonEncode({
          'result': _savedResult(framesStacked: 7, framesAttempted: 6),
        }),
      );
    final backend = _backend(fake);
    addTearDown(backend.dispose);

    await expectLater(
      backend.stackingGetSavedResult(7),
      throwsA(isA<FormatException>()),
    );
  });

  test('saved preview rejects an HTML/error payload returned as 200', () async {
    final fake = FakeNetworkClient()
      ..setBinaryResponse(
        '/api/stacking/results/7/preview',
        bodyBytes: utf8.encode('<html>proxy error</html>'),
        headers: const {'content-type': 'text/html'},
      );
    final backend = _backend(fake);
    addTearDown(backend.dispose);

    await expectLater(
      backend.stackingGetSavedResultPreview(7),
      throwsA(isA<FormatException>()),
    );
  });
}
