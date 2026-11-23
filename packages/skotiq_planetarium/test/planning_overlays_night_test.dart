import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_planetarium/src/rendering/render_quality.dart';
import 'package:skotiq_planetarium/src/rendering/sky_renderer.dart';

/// Records the lines the painter draws and ignores everything else.
class _LineRecorder implements Canvas {
  final lines = <(Offset, Offset, Color)>[];

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) =>
      lines.add((p1, p2, paint.color));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// After local midnight the target's altitude track still describes the
/// night under way: its "now" marker and its transit tick are drawn, and
/// the twilight gauge's now tick sits inside the night.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const transitTick = 0xFFFFB74D;
  final nowMarker = Colors.white.withValues(alpha: 0.55).toARGB32();
  final gaugeTick = Colors.white.withValues(alpha: 0.85).toARGB32();

  List<(Offset, Offset, Color)> trackLinesAt(DateTime observationTime) {
    // A site whose solar time is the computer's clock time, so the instant is
    // 01:00 there too in any time zone the test runs in.
    final longitude = observationTime.timeZoneOffset.inMinutes / 4.0;
    const target = CelestialCoordinate(ra: 2, dec: 60);
    final painter = SkyCanvasPainter(
      renderScope: SkyRenderScope.overlay,
      viewState: const SkyViewState(centerRA: 2, centerDec: 60),
      config: const SkyRenderConfig(showPlanningOverlays: true),
      qualityConfig: const RenderQualityConfig.balanced(),
      stars: const [],
      dsos: const [],
      constellations: const [],
      observationTime: observationTime,
      latitude: 40,
      longitude: longitude,
      selectedObject: target,
    );
    final canvas = _LineRecorder();
    painter.paint(canvas, const Size(800, 600));
    return canvas.lines;
  }

  bool isNowMarker((Offset, Offset, Color) line) =>
      line.$1.dx == line.$2.dx && line.$3.toARGB32() == nowMarker;

  test(
    'at 01:00 the track shows now and the transit of the night under way',
    () {
      final lines = trackLinesAt(DateTime(2026, 1, 2, 1));
      expect(
        lines.where(isNowMarker),
        hasLength(1),
        reason: 'the now marker falls inside the night shown',
      );
      expect(
        lines.where((l) => l.$3.toARGB32() == transitTick),
        hasLength(1),
        reason: 'the transit tick falls inside the night shown',
      );
      // The twilight gauge spans x 16..166 from the site's solar noon to the
      // next; 01:00 is 13 hours in, not pinned to the gauge's left edge.
      final gaugeNow = lines.singleWhere((l) => l.$3.toARGB32() == gaugeTick);
      expect(gaugeNow.$1.dx, closeTo(16 + 150 * 13 / 24, 2));
    },
  );

  test('the evening before midnight shows the same marks', () {
    final lines = trackLinesAt(DateTime(2026, 1, 1, 22));
    expect(lines.where(isNowMarker), hasLength(1));
    expect(lines.where((l) => l.$3.toARGB32() == transitTick), hasLength(1));
  });
}
