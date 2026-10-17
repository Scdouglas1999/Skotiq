import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/framing_image_cache_provider.dart';
import 'package:skotiq_core/src/providers/framing_provider.dart';
import 'package:skotiq_core/src/services/framing_image_cache_service.dart';

Uint8List _encodeJpeg(int width, int height) {
  final bitmap = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      bitmap.setPixelRgba(x, y, (x * 4) % 256, (y * 4) % 256, 64, 255);
    }
  }
  return Uint8List.fromList(img.encodeJpg(bitmap, quality: 95));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FramingNotifier.pan re-fetch on margin overflow', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('framing_pan_refetch_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    /// Builds a container with an offline-primed cache for [raHours]/[decDegrees]
    /// at the given FOV, loads it so [FramingState.plateScale] is populated, and
    /// returns the notifier ready to be panned.
    Future<(ProviderContainer, FramingNotifier)> primedNotifier({
      required double raHours,
      required double decDegrees,
      required double fovWidthDeg,
      required double fovHeightDeg,
      required int imageWidth,
      required int imageHeight,
    }) async {
      final cacheService = FramingImageCacheService(
        supportDirProvider: () async => tempDir,
      );
      final saved = await cacheService.saveSurveyImage(
        bytes: _encodeJpeg(imageWidth, imageHeight),
        raHours: raHours,
        decDegrees: decDegrees,
        source: SurveySource.dss2Red,
      );
      final metaFile = File('${saved.filePath}.meta.json');
      final meta = Map<String, Object?>.from(
        jsonDecode(await metaFile.readAsString()) as Map,
      );
      meta['fovWidthDeg'] = fovWidthDeg;
      meta['fovHeightDeg'] = fovHeightDeg;
      await metaFile.writeAsString(jsonEncode(meta), flush: true);

      // The real databaseProvider opens the shared on-disk file (with its
      // open-time integrity check) — under a parallel full-suite run two
      // test processes collide on it and sqlite reports 'database is
      // locked'. Nothing here needs durable rows.
      final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          framingImageCacheServiceProvider.overrideWithValue(cacheService),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await database.close();
      });

      final notifier = container.read(framingProvider.notifier);
      notifier.setTargetCoordinates(raHours, decDegrees, name: 'Primed');
      await notifier.loadSurveyImage();

      final state = container.read(framingProvider);
      expect(
        state.plateScale,
        isNotNull,
        reason: 'precondition: plate scale must be loaded before panning',
      );
      return (container, notifier);
    }

    test(
      'a small pan stays a display transform (no re-fetch / no recenter)',
      () async {
        const raHours = 5.0;
        const decDegrees = 0.0;
        const fovWidthDeg = 4.0;
        const imageWidth = 100;
        const imageHeight = 100;

        final (container, notifier) = await primedNotifier(
          raHours: raHours,
          decDegrees: decDegrees,
          fovWidthDeg: fovWidthDeg,
          fovHeightDeg: 4.0,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
        );

        // The cutout (100px wide / 4deg) is drawn fit-to-canvas onto a 100x100
        // canvas at zoom 1.0, so px-per-degree = 100/4 = 25 and 10px of pan ==
        // 0.4 deg, well under the 35% * 4deg = 1.4 deg threshold.
        notifier.pan(10, 0, canvasSize: const Size(100, 100));

        final state = container.read(framingProvider);
        expect(
          state.target!.raHours,
          raHours,
          reason: 'small pan must not recenter the target',
        );
        expect(state.target!.decDegrees, decDegrees);
        expect(state.panX, 10);
      },
    );

    test(
      'panning past the 35% margin recenters the target and resets pan',
      () async {
        const raHours = 5.0;
        const decDegrees = 0.0;
        const fovWidthDeg = 4.0;
        const imageWidth = 100;
        const imageHeight = 100;

        final (container, notifier) = await primedNotifier(
          raHours: raHours,
          decDegrees: decDegrees,
          fovWidthDeg: fovWidthDeg,
          fovHeightDeg: 4.0,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
        );

        // Drawn fit-to-canvas at 25 px/deg (100px / 4deg), 50px pan == 2.0 deg >
        // 1.4 deg threshold.
        notifier.pan(50, 0, canvasSize: const Size(100, 100));

        final state = container.read(framingProvider);
        // Target moved in RA and pan was reset to zero (a fresh cutout is loading).
        expect(state.panX, 0);
        expect(state.panY, 0);
        expect(state.target!.raHours, isNot(closeTo(raHours, 1e-9)));
        // At dec=0, cos(dec)=1, so RA offset == 2.0deg / 15 = 0.1333... hours,
        // applied with the screen convention (drag right reveals west => RA down).
        expect(state.target!.raHours, closeTo(raHours - (2.0 / 15.0), 1e-6));
      },
    );

    test('RA recenter step shrinks near the pole (cos(dec) scaling)', () async {
      // Same on-screen pan at two declinations: the absolute RA step must be
      // larger far from the pole and smaller near it (1/cos(dec) scaling).
      const fovWidthDeg = 4.0;
      const imageWidth = 100;
      const imageHeight = 100;

      Future<double> measureRaStep(double dec) async {
        final (container, notifier) = await primedNotifier(
          raHours: 5.0,
          decDegrees: dec,
          fovWidthDeg: fovWidthDeg,
          fovHeightDeg: 4.0,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
        );
        final before = container.read(framingProvider).target!.raHours;
        // 2.0 deg displacement (25 px/deg on a 100x100 canvas), over threshold.
        notifier.pan(50, 0, canvasSize: const Size(100, 100));
        final after = container.read(framingProvider).target!.raHours;
        return (after - before).abs();
      }

      final stepLowDec = await measureRaStep(0.0); // cos = 1
      final stepHighDec = await measureRaStep(60.0); // cos = 0.5

      // Near the pole the same pan must produce a LARGER RA-hour step, because
      // RA hours are scaled by 1/cos(dec): at dec=60, 1/cos = 2x the hour step
      // of dec=0 for the same angular displacement on the sky.
      expect(stepHighDec, greaterThan(stepLowDec));
      expect(
        stepHighDec,
        closeTo(stepLowDec / math.cos(60 * math.pi / 180), 1e-4),
      );
    });

    test('threshold uses the DRAWN canvas width, not the native image pixel '
        'width (small cutout on a large canvas does not over-trigger)', () async {
      // A canvas-independent fallback that divides the pan by the native image
      // pixel width over-counts pan by ~(drawnWidth / nativeWidth) for a tiny
      // cached cutout drawn large, and re-centers almost immediately. Here a
      // 100px-wide cutout (4deg FOV) is drawn fit-to-canvas onto a 960x720
      // canvas, so it renders 720px wide => 180 px/deg. A 50px pan is therefore
      // 0.278deg — far under the 35% * 4deg = 1.4deg threshold — even though
      // the SAME 50px on the native 100px image would read as 2.0deg.
      const raHours = 5.0;
      const decDegrees = 0.0;
      const fovWidthDeg = 4.0;

      final (container, notifier) = await primedNotifier(
        raHours: raHours,
        decDegrees: decDegrees,
        fovWidthDeg: fovWidthDeg,
        fovHeightDeg: 4.0,
        imageWidth: 100,
        imageHeight: 100,
      );

      notifier.pan(50, 0, canvasSize: const Size(960, 720));

      final state = container.read(framingProvider);
      expect(
        state.panX,
        50,
        reason:
            'pan must accumulate as a display transform; drawn-width '
            'mapping keeps 50px well under the re-fetch threshold',
      );
      expect(
        state.target!.raHours,
        raHours,
        reason:
            'no recenter: drawn px-per-degree (720/4=180) means 50px is '
            'only 0.28deg, not the 2.0deg the native-pixel math wrongly gave',
      );
    });

    test('threshold scales with zoom (a zoomed-in view re-centers on a smaller '
        'pan)', () async {
      // At higher zoom the cutout is drawn larger, so each on-screen pixel maps
      // to fewer sky degrees; the same pan distance therefore moves the sky
      // *less*, and the re-fetch needs a larger pan. Conversely the px-per-
      // degree grows with zoom. Verify the canvas-aware branch honors zoom by
      // confirming a pan that crosses the threshold at zoom 1.0 stays under it
      // once zoomed in.
      const raHours = 5.0;
      const fovWidthDeg = 4.0;

      final (container, notifier) = await primedNotifier(
        raHours: raHours,
        decDegrees: 0.0,
        fovWidthDeg: fovWidthDeg,
        fovHeightDeg: 4.0,
        imageWidth: 100,
        imageHeight: 100,
      );
      notifier.setZoom(2.0);

      // 50px at zoom 2.0 on a 100x100 canvas: drawn width = 100*2 = 200px =>
      // 50 px/deg, so 50px == 1.0deg, under the 1.4deg threshold (it WOULD have
      // crossed at zoom 1.0, where 50px == 2.0deg).
      notifier.pan(50, 0, canvasSize: const Size(100, 100));

      final state = container.read(framingProvider);
      expect(
        state.target!.raHours,
        raHours,
        reason: 'zoomed in, 50px is only 1.0deg and must not recenter',
      );
      expect(state.panX, 50);
    });
  });
}
