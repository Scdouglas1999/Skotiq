import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/astronomy/planetary_positions.dart';
import 'package:skotiq_planetarium/src/celestial_object.dart';
import 'package:skotiq_planetarium/src/coordinate_system.dart';
import 'package:skotiq_planetarium/src/rendering/render_quality.dart';
import 'package:skotiq_planetarium/src/rendering/sky_renderer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'SkyCanvasPainter renders nonblank pixels across quality tiers',
    () async {
      const canvasSize = Size(320, 240);
      const center = CelestialCoordinate(ra: 5, dec: 0);
      const config = SkyRenderConfig(
        showCoordinateGrid: true,
        showAltAzGrid: true,
        showEquatorialGrid: true,
        showEcliptic: true,
        showGalacticPlane: true,
        showMeridian: true,
      );
      const qualityTiers = [
        RenderQualityConfig.minimal(),
        RenderQualityConfig.balanced(),
        RenderQualityConfig.quality(),
      ];

      for (final quality in qualityTiers) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        final painter = SkyCanvasPainter(
          viewState: const SkyViewState(centerRA: 5, centerDec: 0),
          config: config,
          qualityConfig: quality,
          stars: const [
            Star(
              id: 'render-smoke-star',
              name: 'Render Smoke Star',
              coordinates: center,
              magnitude: 0.5,
              spectralType: 'A0',
            ),
          ],
          dsos: const [
            DeepSkyObject(
              id: 'render-smoke-dso',
              name: 'Render Smoke Galaxy',
              coordinates: CelestialCoordinate(ra: 5.1, dec: 0.1),
              type: DsoType.galaxy,
              magnitude: 6,
              sizeArcMin: 10,
            ),
          ],
          constellations: const [],
          observationTime: DateTime.utc(2026, 1, 1),
          latitude: 40,
          longitude: -75,
          selectedObject: center,
          mountPosition: center,
          mountStatus: MountRenderStatus.tracking,
          sunPosition: const (75, 0),
          moonPosition: const (76, 1, 60),
          planets: const [
            PlanetData(
              name: 'Jupiter',
              ra: 5.2,
              dec: -0.2,
              magnitude: -2,
              color: 0xFFFFD180,
            ),
          ],
        );

        painter.paint(canvas, canvasSize);
        final picture = recorder.endRecording();
        final image = await picture.toImage(
          canvasSize.width.toInt(),
          canvasSize.height.toInt(),
        );
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );

        expect(bytes, isNotNull, reason: '${quality.quality} raster was null');
        var opaquePixels = 0;
        for (var i = 3; i < bytes!.lengthInBytes; i += 4) {
          if (bytes.getUint8(i) != 0) {
            opaquePixels++;
          }
        }
        expect(
          opaquePixels,
          greaterThan(canvasSize.width * canvasSize.height ~/ 2),
          reason: '${quality.quality} raster was unexpectedly blank',
        );

        image.dispose();
        picture.dispose();
      }
    },
  );
}
