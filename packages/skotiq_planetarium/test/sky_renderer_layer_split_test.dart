import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/celestial_object.dart';
import 'package:skotiq_planetarium/src/coordinate_system.dart';
import 'package:skotiq_planetarium/src/rendering/render_quality.dart';
import 'package:skotiq_planetarium/src/rendering/sky_renderer.dart';

/// Verifies the base/overlay render-scope split that keeps a static view cheap:
/// the base layer must NOT repaint on twinkle/selection ticks, while the
/// overlay layer must repaint on those ticks. Both must repaint on a real pose
/// change.
void main() {
  const center = CelestialCoordinate(ra: 5, dec: 0);

  // A bright star (mag < 1.5, the overlay's twinkle pass) and a fainter star
  // (the base's medium pass) so both layers have something to draw.
  const stars = <Star>[
    Star(
      id: 'bright',
      name: 'Bright',
      coordinates: center,
      magnitude: 0.2,
      spectralType: 'A0',
    ),
    Star(
      id: 'medium',
      name: 'Medium',
      coordinates: CelestialCoordinate(ra: 5.05, dec: 0.05),
      magnitude: 2.5,
      spectralType: 'G0',
    ),
  ];

  SkyCanvasPainter makePainter({
    required SkyRenderScope scope,
    SkyViewState viewState = const SkyViewState(centerRA: 5, centerDec: 0),
    double? twinkle,
    double? selectionPulse,
  }) {
    return SkyCanvasPainter(
      renderScope: scope,
      viewState: viewState,
      config: const SkyRenderConfig(),
      qualityConfig: const RenderQualityConfig.quality(),
      stars: stars,
      dsos: const [],
      constellations: const [],
      observationTime: DateTime.utc(2026, 1, 1, 22, 30),
      latitude: 40,
      longitude: -75,
      selectedObject: center,
      animationPhase: twinkle,
      selectionAnimationPhase: selectionPulse,
    );
  }

  test('base layer does NOT repaint for a twinkle-phase change', () {
    final a = makePainter(scope: SkyRenderScope.base, twinkle: 0.0);
    final b = makePainter(scope: SkyRenderScope.base, twinkle: 0.5);
    expect(b.shouldRepaint(a), isFalse);
  });

  test('base layer does NOT repaint for a selection-pulse change', () {
    final a = makePainter(scope: SkyRenderScope.base, selectionPulse: 0.0);
    final b = makePainter(scope: SkyRenderScope.base, selectionPulse: 0.5);
    expect(b.shouldRepaint(a), isFalse);
  });

  test('base layer repaints for a pose change', () {
    final a = makePainter(scope: SkyRenderScope.base);
    final b = makePainter(
      scope: SkyRenderScope.base,
      viewState: const SkyViewState(centerRA: 6, centerDec: 0),
    );
    expect(b.shouldRepaint(a), isTrue);
  });

  test('overlay layer repaints for a twinkle-phase change', () {
    // Quantized to 20 steps/cycle, so 0.0 -> 0.5 crosses several buckets.
    final a = makePainter(scope: SkyRenderScope.overlay, twinkle: 0.0);
    final b = makePainter(scope: SkyRenderScope.overlay, twinkle: 0.5);
    expect(b.shouldRepaint(a), isTrue);
  });

  test('overlay layer repaints for a selection-pulse change', () {
    final a = makePainter(scope: SkyRenderScope.overlay, selectionPulse: 0.0);
    final b = makePainter(scope: SkyRenderScope.overlay, selectionPulse: 0.5);
    expect(b.shouldRepaint(a), isTrue);
  });

  test(
    'overlay layer repaints for a pose change (bright stars move on pan)',
    () {
      final a = makePainter(scope: SkyRenderScope.overlay, twinkle: 0.0);
      final b = makePainter(
        scope: SkyRenderScope.overlay,
        viewState: const SkyViewState(centerRA: 6, centerDec: 0),
        twinkle: 0.0,
      );
      expect(b.shouldRepaint(a), isTrue);
    },
  );

  test('overlay layer does NOT repaint for a sub-quantum twinkle change', () {
    // Two phases inside the same 1/20 bucket must not trigger a repaint.
    final a = makePainter(scope: SkyRenderScope.overlay, twinkle: 0.01);
    final b = makePainter(scope: SkyRenderScope.overlay, twinkle: 0.02);
    expect(b.shouldRepaint(a), isFalse);
  });
}
