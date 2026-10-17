// Pins the sky-view background slot.
//
// The planetarium is a leaf package: it draws a star chart and knows nothing
// about survey imagery. But a star chart at an imaging field is nearly empty
// (the HYG catalogue carries ~3 stars per square degree), so the sky view
// exposes a *slot* a host can composite real imagery into, beneath the stars.
//
// Two things have to hold for that slot to be worth anything, and both are
// easy to break silently:
//
//   1. The sky painter fills the whole canvas with an opaque gradient before
//      it draws anything. Unless it is told not to, whatever the host put
//      underneath is simply invisible — and nothing about the rendered output
//      would look broken, it would just look like the feature does not work.
//   2. The suppression must be *opt-in and per-painter*. Every other consumer
//      of the painter — the minimap, thumbnails, the render goldens — still
//      wants its background, and a sky view with imagery mounted next to one
//      without must not affect it.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/celestial_object.dart';
import 'package:skotiq_planetarium/src/providers/deep_star_providers.dart';
import 'package:skotiq_planetarium/src/providers/planetarium_providers.dart';
import 'package:skotiq_planetarium/src/rendering/render_quality.dart';
import 'package:skotiq_planetarium/src/rendering/sky_renderer.dart';
import 'package:skotiq_planetarium/src/widgets/interactive_sky_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const size = Size(400, 300);

  SkyCanvasPainter buildPainter({bool paintsOpaqueBackground = true}) =>
      SkyCanvasPainter(
        paintsOpaqueBackground: paintsOpaqueBackground,
        viewState: const SkyViewState(
          centerRA: 5,
          centerDec: 20,
          fieldOfView: 20,
        ),
        config: const SkyRenderConfig(
          showStars: false,
          showConstellationLines: false,
          showConstellationLabels: false,
          showDSOs: false,
          showDSOLabels: false,
          showHorizon: false,
          showCardinalDirections: false,
          showMountPosition: false,
          showSun: false,
          showMoon: false,
          showPlanets: false,
          showGroundPlane: false,
        ),
        qualityConfig: const RenderQualityConfig.minimal(),
        stars: const [],
        dsos: const [],
        constellations: const [],
        observationTime: DateTime.utc(2026, 3, 14, 22),
        latitude: 40,
        longitude: -75,
      );

  /// Rects covering (near enough) the whole canvas — the background fill.
  List<Rect> fullCanvasRects(_RectRecordingCanvas canvas) => canvas.rects
      .where(
        (r) => r.width >= size.width - 0.5 && r.height >= size.height - 0.5,
      )
      .toList();

  group('opaque background suppression', () {
    test('the painter fills the canvas by default', () {
      final canvas = _RectRecordingCanvas();
      final painter = buildPainter();

      expect(painter.paintsOpaqueBackground, isTrue);
      painter.paint(canvas, size);

      expect(
        fullCanvasRects(canvas),
        isNotEmpty,
        reason: 'the twilight gradient must still cover the canvas normally',
      );
    });

    test('a suppressed painter leaves the canvas untouched', () {
      final canvas = _RectRecordingCanvas();
      final painter = buildPainter(paintsOpaqueBackground: false);

      expect(painter.paintsOpaqueBackground, isFalse);
      painter.paint(canvas, size);

      expect(
        fullCanvasRects(canvas),
        isEmpty,
        reason: 'a suppressed painter must not paint over the layer beneath it',
      );
    });

    test('suppression is per painter, not global', () {
      // A sky view with imagery must not switch off the minimap's background.
      final suppressed = buildPainter(paintsOpaqueBackground: false);
      final untouched = buildPainter();

      expect(suppressed.paintsOpaqueBackground, isFalse);
      expect(untouched.paintsOpaqueBackground, isTrue);

      final canvas = _RectRecordingCanvas();
      untouched.paint(canvas, size);
      expect(fullCanvasRects(canvas), isNotEmpty);
    });
  });

  group('InteractiveSkyView background slot', () {
    // The provider graph starts real timers (the observation clock, the
    // spatial-index warm-up), so each test tears the tree down and disposes the
    // container inline before it returns — `addTearDown` runs too late for
    // flutter_test's pending-timer invariant.
    Future<ProviderContainer> pumpSkyView(
      WidgetTester tester, {
      SkyBackgroundLayer? backgroundLayer,
      ProviderContainer? reuse,
    }) async {
      final container =
          reuse ??
          ProviderContainer(
            overrides: [
              combinedStarsProvider.overrideWithValue(
                const AsyncValue.data(<Star>[]),
              ),
              fovFilteredDsosProvider.overrideWithValue(
                const AsyncValue.data(<DeepSkyObject>[]),
              ),
            ],
          );
      // The sky is drawn from the observer's site; without one the view renders
      // its no-site state instead.
      container
          .read(observerLocationProvider.notifier)
          .setLocation(latitude: 40.0, longitude: -74.0);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: InteractiveSkyView(backgroundLayer: backgroundLayer),
            ),
          ),
        ),
      );
      await tester.pump();
      return container;
    }

    Future<void> teardown(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    }

    testWidgets('no slot supplied: nothing extra is mounted', (tester) async {
      final container = await pumpSkyView(tester);
      expect(find.byKey(const ValueKey('bg')), findsNothing);
      await teardown(tester, container);
    });

    testWidgets('the slot child is mounted beneath the star layers', (
      tester,
    ) async {
      final container = await pumpSkyView(
        tester,
        backgroundLayer: const SkyBackgroundLayer(
          child: ColoredBox(key: ValueKey('bg'), color: Color(0xFF123456)),
          occludesSkyGradient: true,
        ),
      );

      final background = find.byKey(const ValueKey('bg'));
      expect(background, findsOneWidget);

      // It must be the FIRST child of the sky view's stack: imagery drawn over
      // the star field would hide the stars, which is the opposite of the
      // point.
      final stack = tester.widget<Stack>(
        find
            .descendant(
              of: find.byType(InteractiveSkyView),
              matching: find.byType(Stack),
            )
            .first,
      );
      expect(stack.children.first.key, const ValueKey('bg'));
      await teardown(tester, container);
    });

    testWidgets('flipping occludesSkyGradient repaints the base layer', (
      tester,
    ) async {
      // The guarantee: when the layer beneath becomes opaque, the base layer
      // must stop painting its gradient on the very next frame. If it did not,
      // the gradient would keep covering freshly-arrived imagery. This is
      // carried by the painter's `paintsOpaqueBackground` FIELD, so
      // shouldRepaint sees it — assert the repaint, not the mechanism.
      final container = await pumpSkyView(
        tester,
        backgroundLayer: const SkyBackgroundLayer(
          child: ColoredBox(key: ValueKey('bg'), color: Color(0xFF123456)),
        ),
      );
      final before = _basePainter(tester);
      expect(before.paintsOpaqueBackground, isTrue);

      await pumpSkyView(
        tester,
        reuse: container,
        backgroundLayer: const SkyBackgroundLayer(
          child: ColoredBox(key: ValueKey('bg'), color: Color(0xFF123456)),
          occludesSkyGradient: true,
        ),
      );
      final after = _basePainter(tester);

      expect(after.paintsOpaqueBackground, isFalse);
      expect(
        after.shouldRepaint(before),
        isTrue,
        reason: 'the flip must invalidate the base layer',
      );
      await teardown(tester, container);
    });
  });
}

/// The sky view's background-owning [SkyCanvasPainter].
///
/// That is the `base` layer when the animated overlay is mounted, or the single
/// `full`-scope painter when the view has collapsed to one layer (nothing on
/// the overlay is animating). The overlay scope never paints the background.
SkyCanvasPainter _basePainter(WidgetTester tester) {
  final painters = tester
      .widgetList<CustomPaint>(
        find.descendant(
          of: find.byType(InteractiveSkyView),
          matching: find.byType(CustomPaint),
        ),
      )
      .map((p) => p.painter)
      .whereType<SkyCanvasPainter>()
      .where((p) => p.renderScope != SkyRenderScope.overlay)
      .toList();
  expect(painters, isNotEmpty, reason: 'no base sky painter mounted');
  return painters.first;
}

/// A [Canvas] stand-in that records the rectangles drawn on it, so a test can
/// assert whether the painter filled the whole canvas with its background.
///
/// Everything other than the draw calls we care about is swallowed by
/// [noSuchMethod] — the painter issues a great many canvas operations and this
/// test is only interested in the full-canvas fill.
class _RectRecordingCanvas implements Canvas {
  final List<Rect> rects = <Rect>[];

  @override
  void drawRect(Rect rect, Paint paint) => rects.add(rect);

  @override
  void drawPaint(Paint paint) =>
      rects.add(const Rect.fromLTWH(0, 0, double.maxFinite, double.maxFinite));

  @override
  int getSaveCount() => 1;

  @override
  Rect getLocalClipBounds() => Rect.largest;

  @override
  Rect getDestinationClipBounds() => Rect.largest;

  @override
  Float64List getTransform() => Matrix4.identity().storage;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
