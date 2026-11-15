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

    test('a row this release cannot read is left out, not the session', () async {
      final oldShape = <String, Object?>{
        'image_id': 8,
        'file_path': '/legacy/frame.fit',
        'file_format': 'fit',
        'frame_type': 'darkflat',
        'exposure_duration': 2,
        'bin_x': 1,
        'bin_y': 1,
        'captured_at': 1700000000,
      };
      final unreadable = <Map<String, Object?>>[
        oldShape,
        _currentRow(id: 2, frameType: 'science'),
        _currentRow(id: 3, fileFormat: 'bmp'),
        _currentRow(id: 4)..['gain'] = -5,
        _currentRow(id: 5)..['binX'] = 0,
        _currentRow(id: 6)..['hfr'] = -0.1,
        _currentRow(id: 9)..['id'] = 4.5,
      ];
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/sessions/4/images',
          body: jsonEncode({
            'images': [...unreadable, _currentRow(id: 7)],
          }),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      final images = await backend.getSessionImages(4);

      expect(images.map((image) => image.id), ['7']);
    });

    test('a duplicate image id still refuses the list', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/sessions/4/images',
          body: jsonEncode({
            'images': [_currentRow(), _currentRow()],
          }),
        );
      final backend = _backend(fake);
      addTearDown(backend.dispose);
      await expectLater(backend.getSessionImages(4), throwsFormatException);
    });

    test('rejects non-positive session identifiers before transport', () async {
      final fake = FakeNetworkClient();
      final backend = _backend(fake);
      addTearDown(backend.dispose);

      await expectLater(backend.getSessionImages(0), throwsArgumentError);
      expect(fake.requests, isEmpty);
    });
  });
}
