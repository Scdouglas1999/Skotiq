import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/coordinate_system.dart';
import 'package:skotiq_planetarium/src/rendering/render_quality.dart';
import 'package:skotiq_planetarium/src/rendering/sky_renderer.dart';

/// Smoke tests for the on-sky planning overlays (altitude track, meridian-flip
/// marker, twilight indicator). They live on the animated overlay layer, so we
/// exercise [SkyRenderScope.overlay] with the feature enabled and assert it
/// rasterises without throwing and shouldRepaint behaves as the lifecycle
/// documents.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const canvasSize = Size(360, 280);
  const selected = CelestialCoordinate(ra: 5.5, dec: 12);

  // Const so the two painters in each shouldRepaint test share the SAME config
  // instance (the lifecycle compares config by identity).
  const overlaysOnConfig = SkyRenderConfig(showPlanningOverlays: true);
  const overlaysOffConfig = SkyRenderConfig(showPlanningOverlays: false);

  SkyCanvasPainter buildPainter({
    required SkyRenderScope scope,
    required bool showPlanningOverlays,
    DateTime? observationTime,
  }) {
    return SkyCanvasPainter(
      renderScope: scope,
      viewState: const SkyViewState(centerRA: 5.5, centerDec: 12),
      config: showPlanningOverlays ? overlaysOnConfig : overlaysOffConfig,
      qualityConfig: const RenderQualityConfig.balanced(),
      stars: const [],
      dsos: const [],
      constellations: const [],
      observationTime: observationTime ?? DateTime(2026, 1, 1, 22),
      latitude: 40,
      longitude: -75,
      selectedObject: selected,
    );
  }

  test(
    'overlay layer with planning overlays rasterises without throwing',
    () async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final painter = buildPainter(
        scope: SkyRenderScope.overlay,
        showPlanningOverlays: true,
      );

      painter.paint(canvas, canvasSize);
      final picture = recorder.endRecording();
      final image = await picture.toImage(
        canvasSize.width.toInt(),
        canvasSize.height.toInt(),
      );
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);

      expect(bytes, isNotNull);
      // The overlay layer is otherwise empty here (no stars/selection pulse), so
      // any opaque pixels prove the planning overlays actually drew something.
      var opaquePixels = 0;
      for (var i = 3; i < bytes!.lengthInBytes; i += 4) {
        if (bytes.getUint8(i) != 0) opaquePixels++;
      }
      expect(
        opaquePixels,
        greaterThan(0),
        reason: 'planning overlays drew nothing',
      );

      image.dispose();
      picture.dispose();
    },
  );

  test(
    'overlay repaints when the observation minute advances and overlays on',
    () {
      final old = buildPainter(
        scope: SkyRenderScope.overlay,
        showPlanningOverlays: true,
        observationTime: DateTime(2026, 1, 1, 22, 0),
      );
      final next = buildPainter(
        scope: SkyRenderScope.overlay,
        showPlanningOverlays: true,
        observationTime: DateTime(2026, 1, 1, 22, 1),
      );
      expect(next.shouldRepaint(old), isTrue);
    },
  );

  test('overlay does NOT repaint on minute change when overlays are off', () {
    final old = buildPainter(
      scope: SkyRenderScope.overlay,
      showPlanningOverlays: false,
      observationTime: DateTime(2026, 1, 1, 22, 0),
    );
    final next = buildPainter(
      scope: SkyRenderScope.overlay,
      showPlanningOverlays: false,
      observationTime: DateTime(2026, 1, 1, 22, 1),
    );
    // No selection pulse / twinkle phase here, and config is identical, so the
    // overlay should stay idle on a bare minute tick.
    expect(next.shouldRepaint(old), isFalse);
  });
}
