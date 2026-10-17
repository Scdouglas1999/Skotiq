import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/providers/framing_image_cache_provider.dart';
import 'package:skotiq_core/src/providers/framing_provider.dart'
    show SurveySource;
import 'package:skotiq_core/src/services/framing_image_cache_service.dart';
import '../harness/in_memory_database.dart';

void main() {
  group('framingImageCacheServiceProvider', () {
    test('exposes a FramingImageCacheService instance', () {
      final container = ProviderContainer(
        overrides: [inMemoryDatabaseOverride()],
      );
      addTearDown(container.dispose);

      final service = container.read(framingImageCacheServiceProvider);
      expect(service, isA<FramingImageCacheService>());
    });

    test('returns the same instance across reads (single DI handle)', () {
      final container = ProviderContainer(
        overrides: [inMemoryDatabaseOverride()],
      );
      addTearDown(container.dispose);

      final first = container.read(framingImageCacheServiceProvider);
      final second = container.read(framingImageCacheServiceProvider);
      expect(identical(first, second), isTrue);
    });
  });

  group('cachedSurveyImageFileProvider', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('framing_cache_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    /// Builds a container whose cache service writes/reads under [tempDir],
    /// so the test never touches the real application-support directory.
    ProviderContainer containerWithTempCache() {
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          framingImageCacheServiceProvider.overrideWithValue(
            FramingImageCacheService(supportDirProvider: () async => tempDir),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('returns null for an absent cache entry', () async {
      final container = containerWithTempCache();

      final file = await container.read(
        cachedSurveyImageFileProvider((
          raHours: 5.5,
          decDegrees: -5.4,
          source: SurveySource.dss2Red,
        )).future,
      );

      expect(file, isNull);
    });

    test('returns the cached file after the service persists it', () async {
      final container = containerWithTempCache();
      final service = container.read(framingImageCacheServiceProvider);

      const key = (
        raHours: 13.42,
        decDegrees: 47.18,
        source: SurveySource.sdss,
      );

      final saved = await service.saveSurveyImage(
        bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
        raHours: key.raHours,
        decDegrees: key.decDegrees,
        source: key.source,
      );

      final file = await container.read(
        cachedSurveyImageFileProvider(key).future,
      );

      expect(file, isNotNull);
      expect(file!.path, saved.filePath);
      expect(await file.exists(), isTrue);
    });

    test('distinguishes entries by survey source', () async {
      final container = containerWithTempCache();
      final service = container.read(framingImageCacheServiceProvider);

      const raHours = 0.7;
      const decDegrees = 41.27;

      await service.saveSurveyImage(
        bytes: Uint8List.fromList(<int>[9, 9, 9]),
        raHours: raHours,
        decDegrees: decDegrees,
        source: SurveySource.dss2Blue,
      );

      final hit = await container.read(
        cachedSurveyImageFileProvider((
          raHours: raHours,
          decDegrees: decDegrees,
          source: SurveySource.dss2Blue,
        )).future,
      );
      final miss = await container.read(
        cachedSurveyImageFileProvider((
          raHours: raHours,
          decDegrees: decDegrees,
          source: SurveySource.wise12,
        )).future,
      );

      expect(hit, isNotNull);
      expect(miss, isNull);
    });
  });
}
