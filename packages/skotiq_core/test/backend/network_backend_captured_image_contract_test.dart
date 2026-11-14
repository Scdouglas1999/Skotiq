import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';

import '../fakes/fakes.dart';

NetworkBackend _backend(FakeNetworkClient fake) => NetworkBackend(
  serverHost: 'example.invalid',
  httpClient: fake,
  autoConnectWebSocket: false,
);

Map<String, Object?> _currentRow({
  int id = 7,
  String frameType = 'snapshot',
  String fileFormat = 'fits',
}) => {
  'id': id,
  'filePath': '/data/frame-$id.fits',
  'fileName': 'frame-$id.fits',
  'fileFormat': fileFormat,
  'frameType': frameType,
  'exposureDuration': 30.5,
  'gain': 100,
  'offset': 20,
  'binX': 2,
  'binY': 2,
  'filter': 'Ha',
  'hfr': 2.1,
  'starCount': 42,
  'capturedAt': 1700000000123,
};

void main() {
  group('NetworkBackend captured-image wire contract', () {
    test('parses the current Drift camelCase host schema', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/sessions/4/images',
          body: jsonEncode({
            'images': [_currentRow()],
          }),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      final images = await backend.getSessionImages(4);

      expect(images, hasLength(1));
      expect(images.single.id, '7');
      expect(images.single.filePath, '/data/frame-7.fits');
      expect(images.single.capturedAt.millisecondsSinceEpoch, 1700000000123);
      expect(images.single.settings.exposureTime, 30.5);
      expect(images.single.settings.frameType, FrameType.snapshot);
      expect(images.single.settings.binning, '2x2');
      expect(images.single.stats?.hfr, 2.1);
      expect(images.single.stats?.starCount, 42);
      expect(images.single.format, ImageFileFormat.fits);
    });

    test('refuses an image row in the old snake_case shape', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/sessions/4/images',
          body: jsonEncode({
            'images': [
              {
                'image_id': 8,
                'file_path': '/legacy/frame.fit',
                'file_format': 'fit',
                'frame_type': 'darkflat',
                'exposure_duration': 2,
                'bin_x': 1,
                'bin_y': 1,
                'captured_at': 1700000000,
              },
            ],
          }),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      await expectLater(backend.getSessionImages(4), throwsFormatException);
    });

    test('rejects duplicate and unknown-enum rows atomically', () async {
      final cases = <List<Map<String, Object?>>>[
        [_currentRow(), _currentRow()],
        [_currentRow(frameType: 'science')],
        [_currentRow(fileFormat: 'bmp')],
      ];

      for (final rows in cases) {
        final fake = FakeNetworkClient()
          ..setResponse(
            '/api/sessions/4/images',
            body: jsonEncode({'images': rows}),
          );
        final backend = _backend(fake);
        addTearDown(backend.dispose);
        await expectLater(backend.getSessionImages(4), throwsFormatException);
      }
    });

    test(
      'rejects fractional identifiers and invalid numeric domains',
      () async {
        final fractionalId = _currentRow()..['id'] = 4.5;
        final negativeHfr = _currentRow()..['hfr'] = -0.1;
        final zeroBinning = _currentRow()..['binX'] = 0;

        for (final row in [fractionalId, negativeHfr, zeroBinning]) {
          final fake = FakeNetworkClient()
            ..setResponse(
              '/api/sessions/4/images',
              body: jsonEncode({
                'images': [row],
              }),
            );
          final backend = _backend(fake);
          addTearDown(backend.dispose);
          await expectLater(backend.getSessionImages(4), throwsFormatException);
        }
      },
    );

    test('rejects non-positive session identifiers before transport', () async {
      final fake = FakeNetworkClient();
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      await expectLater(backend.getSessionImages(0), throwsArgumentError);
      expect(fake.requests, isEmpty);
    });
  });
}
