import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/src/providers/framing_image_cache_provider.dart';
import 'package:skotiq_core/src/providers/framing_provider.dart';
import 'package:skotiq_core/src/services/framing_image_cache_service.dart';

class _DelayedCacheService extends FramingImageCacheService {
  _DelayedCacheService({
    required super.supportDirProvider,
    required this.delayedRa,
  });

  final double delayedRa;
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<File?> loadCachedSurveyImage({
    required double raHours,
    required double decDegrees,
    required SurveySource source,
    String extension = 'jpg',
  }) async {
    if (raHours == delayedRa) {
      if (!started.isCompleted) started.complete();
      await release.future;
    }
    return super.loadCachedSurveyImage(
      raHours: raHours,
      decDegrees: decDegrees,
      source: source,
      extension: extension,
    );
  }
}

class _NoPersistFramingNotifier extends FramingNotifier {
  _NoPersistFramingNotifier(super.ref);

  @override
  Future<void> persistLastFramedTarget(FramingTarget target) async {}
}

Uint8List _jpeg(int width, int height, int red) {
  final bitmap = img.Image(width: width, height: height);
  img.fill(bitmap, color: img.ColorRgb8(red, 20, 40));
  return Uint8List.fromList(img.encodeJpg(bitmap));
}

Future<void> _prime(
  FramingImageCacheService service, {
  required double ra,
  required int width,
  required int height,
}) async {
  final saved = await service.saveSurveyImage(
    bytes: _jpeg(width, height, width),
    raHours: ra,
    decDegrees: 10,
    source: SurveySource.dss2Red,
  );
  final metaFile = File('${saved.filePath}.meta.json');
  final meta = Map<String, Object?>.from(
    jsonDecode(await metaFile.readAsString()) as Map,
  );
  meta['fovWidthDeg'] = 2.0;
  meta['fovHeightDeg'] = 1.0;
  await metaFile.writeAsString(jsonEncode(meta), flush: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the official CDS mirror preserves the cutout before NASA fallback',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'framing_cds_mirror_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final requested = <Uri>[];
      final container = ProviderContainer(
        overrides: [
          framingImageCacheServiceProvider.overrideWithValue(
            FramingImageCacheService(supportDirProvider: () async => tempDir),
          ),
          framingProvider.overrideWith(_NoPersistFramingNotifier.new),
          framingSurveyHttpClientFactoryProvider.overrideWithValue(
            () => MockClient((request) async {
              requested.add(request.url);
              return request.url.host == 'alaskybis.cds.unistra.fr'
                  ? http.Response.bytes(_jpeg(32, 24, 100), 200)
                  : http.Response('Unavailable', 503);
            }),
          ),
        ],
      );
      addTearDown(container.dispose);
      final finished = Completer<void>();
      container.listen(framingProvider, (_, next) {
        if (!next.isLoadingImage &&
            (next.surveyImage != null || next.imageError != null) &&
            !finished.isCompleted) {
          finished.complete();
        }
      });
      container
          .read(framingProvider.notifier)
          .setTargetCoordinates(1.6117, 15.7836, name: 'M74');
      await finished.future.timeout(const Duration(seconds: 4));
      expect(requested.map((u) => u.host), [
        'alasky.cds.unistra.fr',
        'alaskybis.cds.unistra.fr',
      ]);
      expect(requested[1].query, requested[0].query);
      expect(requested[1].path, requested[0].path);
      expect(container.read(framingProvider).surveyImage, isNotNull);
      expect(container.read(framingProvider).plateScale!.imagePixelWidth, 32);
    },
  );

  test(
    'slow primary does not hold up a ready full-resolution fallback',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'framing_slow_primary_',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final primary = Completer<http.Response>();
      final requested = <Uri>[];
      final container = ProviderContainer(
        overrides: [
          framingImageCacheServiceProvider.overrideWithValue(
            FramingImageCacheService(supportDirProvider: () async => tempDir),
          ),
          framingProvider.overrideWith(_NoPersistFramingNotifier.new),
          framingSurveyHttpClientFactoryProvider.overrideWithValue(
            () => MockClient((request) {
              requested.add(request.url);
              if (request.url.host.endsWith('.cds.unistra.fr')) {
                return primary.future;
              }
              return Future.value(http.Response.bytes(_jpeg(32, 24, 100), 200));
            }),
          ),
        ],
      );
      addTearDown(container.dispose);
      final loaded = Completer<bool>();
      container.listen(framingProvider, (_, next) {
        if (next.surveyImage != null &&
            !next.isLoadingImage &&
            !loaded.isCompleted) {
          loaded.complete(true);
        }
      });
      container
          .read(framingProvider.notifier)
          .setTargetCoordinates(1.6117, 15.7836, name: 'M74');
      final loadedBeforePrimary = await Future.any([
        loaded.future,
        Future.delayed(const Duration(seconds: 4), () => false),
      ]);
      primary.complete(http.Response('Unavailable', 503));
      await loaded.future.timeout(const Duration(seconds: 5));
      expect(
        loadedBeforePrimary,
        isTrue,
        reason:
            'A dead primary must not impose its 30-second timeout before fallback',
      );
      final primaryQuery = requested.first.queryParameters;
      final fallbackQuery = requested.last.queryParameters;
      expect(
        fallbackQuery['Pixels'],
        '${primaryQuery['width']},${primaryQuery['height']}',
      );
      expect(fallbackQuery['Size']!.split(',').first, primaryQuery['fov']);
      expect(container.read(framingProvider).plateScale!.imagePixelWidth, 32);
    },
  );

  test(
    'slow old-target cache result cannot replace the latest survey image',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'framing_request_authority_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final cache = _DelayedCacheService(
        supportDirProvider: () async => tempDir,
        delayedRa: 1,
      );
      await _prime(cache, ra: 1, width: 24, height: 16);
      await _prime(cache, ra: 2, width: 64, height: 32);
      final container = ProviderContainer(
        overrides: [
          framingImageCacheServiceProvider.overrideWithValue(cache),
          framingProvider.overrideWith(_NoPersistFramingNotifier.new),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(framingProvider.notifier);

      notifier.setTargetCoordinates(1, 10, name: 'Old target');
      await cache.started.future;
      notifier.setTargetCoordinates(2, 10, name: 'Latest target');

      for (var attempt = 0; attempt < 100; attempt++) {
        final state = container.read(framingProvider);
        if (!state.isLoadingImage && state.surveyImage?.width == 64) break;
        await Future<void>.delayed(Duration.zero);
      }
      expect(container.read(framingProvider).surveyImage?.width, 64);

      cache.release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final state = container.read(framingProvider);
      expect(state.target?.name, 'Latest target');
      expect(state.surveyImage?.width, 64);
    },
  );
}
