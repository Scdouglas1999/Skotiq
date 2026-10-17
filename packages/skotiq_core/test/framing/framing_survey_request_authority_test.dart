import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
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
