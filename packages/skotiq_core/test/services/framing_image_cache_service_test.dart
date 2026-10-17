import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/providers/framing_provider.dart'
    show SurveySource;
import 'package:skotiq_core/src/services/framing_image_cache_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late FramingImageCacheService service;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('ns_framing_cache_test_');
    service = FramingImageCacheService(
      supportDirProvider: () async => tempRoot,
    );
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  test('buildFilename is deterministic across instances', () {
    final s1 = FramingImageCacheService();
    final s2 = FramingImageCacheService();
    final name1 = s1.buildFilename(
      raHours: 13.421234567,
      decDegrees: -19.50001,
      source: SurveySource.dss2Red,
    );
    final name2 = s2.buildFilename(
      raHours: 13.421234567,
      decDegrees: -19.50001,
      source: SurveySource.dss2Red,
    );
    expect(name1, equals(name2));
    expect(name1, endsWith('_DSS2R.jpg'));
    // Negative dec gets the 'M' sign prefix in the dec token.
    expect(name1, contains('_M19'));
  });

  test('buildFilename uses sign token for positive vs negative Dec', () {
    final pos = service.buildFilename(
      raHours: 0.0,
      decDegrees: 45.0,
      source: SurveySource.sdss,
    );
    final neg = service.buildFilename(
      raHours: 0.0,
      decDegrees: -45.0,
      source: SurveySource.sdss,
    );
    expect(pos, contains('P45'));
    expect(neg, contains('M45'));
    expect(pos, isNot(equals(neg)));
  });

  test('saveSurveyImage persists bytes to disk under framing_cache/', () async {
    final bytes = Uint8List.fromList(List<int>.generate(256, (i) => i % 256));
    final entry = await service.saveSurveyImage(
      bytes: bytes,
      raHours: 5.5,
      decDegrees: -22.0,
      source: SurveySource.dss2Red,
      targetName: 'M42',
    );

    final file = File(entry.filePath);
    expect(await file.exists(), isTrue);
    expect(await file.readAsBytes(), equals(bytes));
    expect(entry.sizeBytes, equals(bytes.length));

    // Cache dir lives under the support root.
    expect(entry.filePath, contains('framing_cache'));

    // Sidecar metadata is written.
    final meta = File('${entry.filePath}.meta.json');
    expect(await meta.exists(), isTrue);
    final metaJson =
        jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
    expect(metaJson['targetName'], equals('M42'));
    expect(metaJson['surveyCode'], equals('DSS2R'));
    expect(metaJson['sizeBytes'], equals(bytes.length));
  });

  test(
    'cached image survives a fresh service instance (restart sim)',
    () async {
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      await service.saveSurveyImage(
        bytes: bytes,
        raHours: 12.0,
        decDegrees: 30.0,
        source: SurveySource.sdss,
      );

      // Simulate app restart: brand new service pointing at the same support
      // directory.
      final reborn = FramingImageCacheService(
        supportDirProvider: () async => tempRoot,
      );
      final found = await reborn.loadCachedSurveyImage(
        raHours: 12.0,
        decDegrees: 30.0,
        source: SurveySource.sdss,
      );
      expect(found, isNotNull);
      expect(await found!.readAsBytes(), equals(bytes));
    },
  );

  test('saveSurveyImage rejects zero-byte payloads', () async {
    expect(
      () => service.saveSurveyImage(
        bytes: Uint8List(0),
        raHours: 0.0,
        decDegrees: 0.0,
        source: SurveySource.dss2Red,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('removeCachedSurveyImage deletes image + sidecar', () async {
    final bytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
    final entry = await service.saveSurveyImage(
      bytes: bytes,
      raHours: 1.5,
      decDegrees: 60.0,
      source: SurveySource.wise12,
    );

    expect(await File(entry.filePath).exists(), isTrue);
    expect(await File('${entry.filePath}.meta.json').exists(), isTrue);

    final removed = await service.removeCachedSurveyImage(
      raHours: 1.5,
      decDegrees: 60.0,
      source: SurveySource.wise12,
    );

    expect(removed, isTrue);
    expect(await File(entry.filePath).exists(), isFalse);
    expect(await File('${entry.filePath}.meta.json').exists(), isFalse);
  });

  test(
    'listCachedImages enumerates only image files, skipping sidecars',
    () async {
      await service.saveSurveyImage(
        bytes: Uint8List.fromList([1, 2, 3]),
        raHours: 1.0,
        decDegrees: 10.0,
        source: SurveySource.dss2Red,
      );
      await service.saveSurveyImage(
        bytes: Uint8List.fromList([4, 5, 6, 7]),
        raHours: 2.0,
        decDegrees: 20.0,
        source: SurveySource.dss2Blue,
      );

      final list = await service.listCachedImages();
      expect(list.length, equals(2));
      expect(list.every((e) => !e.filePath.endsWith('.meta.json')), isTrue);
    },
  );
}
