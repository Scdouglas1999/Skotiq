// The deep-sky layer renders.
//
// Its failure mode is silent and total: stars, constellation lines, planets,
// the Moon, the grid and every label draw correctly while not one deep-sky
// glyph or label appears, at any zoom or sky position, even though the
// catalogue query hands the painter dozens of objects including M42 and M31,
// all inside the magnitude gate.
//
// The DSO pass draws its glyphs as a single batched `drawRawAtlas` call. The
// per-object tint alpha, and the matching label colour's alpha, are BOTH
// multiplied by the pop-in phase the host hands the painter, so a phase of 0
// erases the whole layer — glyphs and labels together, which reads as two
// faults.
//
// A DSO pop-in `AnimationController` constructed without a `value` rests at
// `lowerBound`, i.e. 0.0, and is only ever driven by `forward(from: 0)` when an
// *animated* zoom reveals fainter DSOs, so from launch it sits at 0 and the
// layer is invisible.
//
// The tests below therefore check the rendered pixels on both sides of that
// seam: the painter draws a DSO when told to, AND the sky view as the app
// actually builds it draws one at rest.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/celestial_object.dart';
import 'package:skotiq_planetarium/src/coordinate_system.dart';
import 'package:skotiq_planetarium/src/providers/deep_star_providers.dart';
import 'package:skotiq_planetarium/src/providers/planetarium_providers.dart';
import 'package:skotiq_planetarium/src/rendering/render_quality.dart';
import 'package:skotiq_planetarium/src/rendering/sky_renderer.dart';
import 'package:skotiq_planetarium/src/widgets/interactive_sky_view.dart';

const _size = Size(400, 300);

/// A bright, large deep-sky object sitting exactly on the default view centre
/// (RA 0h, Dec 0) so it projects to the middle of the canvas. Deliberately
/// unnamed beyond its designation, so its label stays short and the ink stays
/// close to the object.
const _centreDso = DeepSkyObject(
  id: 'test-dso',
  name: 'NGC 0000',
  coordinates: CelestialCoordinate(ra: 0, dec: 0),
  type: DsoType.emissionNebula,
  magnitude: 4.0,
  sizeArcMin: 120,
);

/// Everything except the deep-sky layer switched off, so anything that shows
/// up in the difference between two renders is the DSO pass.
const _dsoOnlyConfig = SkyRenderConfig(
  showStars: false,
  showConstellationLines: false,
  showConstellationLabels: false,
  showHorizon: false,
  showCardinalDirections: false,
  showMountPosition: false,
  showSun: false,
  showMoon: false,
  showPlanets: false,
  showGroundPlane: false,
);

Future<ByteData> _rasterise(SkyCanvasPainter painter) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), _size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    _size.width.toInt(),
    _size.height.toInt(),
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  picture.dispose();
  return bytes!;
}

/// Pixels that differ between [a] and [b]: the count within [radius] of [at],
/// the count outside twice that radius, and the count anywhere on the canvas.
({int near, int far, int total}) _differences(
  ByteData a,
  ByteData b, {
  required Offset at,
  required double radius,
}) {
  final width = _size.width.toInt();
  final height = _size.height.toInt();
  var near = 0;
  var far = 0;
  var total = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      if (a.getUint32(i) == b.getUint32(i)) continue;
      total++;
      final d = (Offset(x + 0.5, y + 0.5) - at).distance;
      if (d <= radius) {
        near++;
      } else if (d > radius * 2) {
        far++;
      }
    }
  }
  return (near: near, far: far, total: total);
}

SkyCanvasPainter _painter({
  required List<DeepSkyObject> dsos,
  double? dsoPopinAnimationPhase,
}) => SkyCanvasPainter(
  viewState: const SkyViewState(centerRA: 0, centerDec: 0, fieldOfView: 20),
  config: _dsoOnlyConfig,
  qualityConfig: const RenderQualityConfig.balanced(),
  stars: const [],
  dsos: dsos,
  constellations: const [],
  observationTime: DateTime.utc(2026, 3, 21, 2),
  latitude: 40,
  longitude: -75,
  dsoPopinAnimationPhase: dsoPopinAnimationPhase,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final canvasCentre = Offset(_size.width / 2, _size.height / 2);

  group('SkyCanvasPainter deep-sky pass', () {
    test('a bright DSO paints ink at its projected position', () async {
      final withDso = await _rasterise(_painter(dsos: const [_centreDso]));
      final without = await _rasterise(_painter(dsos: const []));

      final diff = _differences(withDso, without, at: canvasCentre, radius: 60);

      // The glyph is centred on the object and its label sits just off to the
      // right, so the ink has to land on the object, not merely somewhere.
      expect(
        diff.near,
        greaterThan(200),
        reason: 'no deep-sky ink where the object projects to (diff: $diff)',
      );
      expect(
        diff.far,
        isZero,
        reason: 'the deep-sky pass marked pixels nowhere near the object',
      );
    });

    test('a finished pop-in draws the layer, a starting one fades it in', () {
      // The pop-in phase multiplies BOTH the glyph tint alpha and the label
      // alpha, which is what let a mis-seeded controller erase the layer. Pin
      // the mechanism so the two ends of the animation stay distinguishable.
      Future<int> inkFor(double? phase) async {
        final withDso = await _rasterise(
          _painter(dsos: const [_centreDso], dsoPopinAnimationPhase: phase),
        );
        final without = await _rasterise(
          _painter(dsos: const [], dsoPopinAnimationPhase: phase),
        );
        return _differences(
          withDso,
          without,
          at: canvasCentre,
          radius: 60,
        ).total;
      }

      expect(inkFor(0.0), completion(0));
      expect(inkFor(1.0), completion(greaterThan(200)));
      expect(inkFor(null), completion(greaterThan(200)));
    });
  });

  group('InteractiveSkyView deep-sky layer at rest', () {
    // The provider graph starts real timers, so each test tears the tree down
    // and disposes the container inline before it returns.
    Future<ProviderContainer> pumpSkyView(
      WidgetTester tester,
      List<DeepSkyObject> dsos,
    ) async {
      final container = ProviderContainer(
        overrides: [
          combinedStarsProvider.overrideWithValue(
            const AsyncValue.data(<Star>[]),
          ),
          fovFilteredDsosProvider.overrideWithValue(AsyncValue.data(dsos)),
        ],
      );
      // The sky is drawn from the observer's site; without one the view renders
      // its no-site state instead.
      container
          .read(observerLocationProvider.notifier)
          .setLocation(latitude: 40.0, longitude: -74.0);
      // Aim at the test object explicitly. The view no longer opens on RA 0h /
      // Dec 0 — that default pointed the map below the horizon and now homes on
      // the zenith — so the pose has to be stated rather than assumed.
      container.read(skyViewStateProvider.notifier).setCenter(0, 0);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: _size.width,
                height: _size.height,
                child: const InteractiveSkyView(),
              ),
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

    testWidgets('a freshly mounted sky view renders its DSOs', (tester) async {
      // The view has never been zoomed, so no pop-in has ever run — exactly the
      // state the app launches in. The DSO layer must draw anyway.
      final withDso = await pumpSkyView(tester, const [_centreDso]);
      final dsoPainter = _baseDsoPainter(tester);
      await teardown(tester, withDso);

      final empty = await pumpSkyView(tester, const []);
      final blankPainter = _baseDsoPainter(tester);
      await teardown(tester, empty);

      // Rasterising goes through the real event loop (`Picture.toImage`), which
      // the widget tester's fake async zone does not pump.
      late ByteData painted;
      late ByteData blank;
      await tester.runAsync(() async {
        painted = await _rasterise(dsoPainter);
        blank = await _rasterise(blankPainter);
      });

      final diff = _differences(
        painted,
        blank,
        at: Offset(_size.width / 2, _size.height / 2),
        radius: 120,
      );
      expect(
        diff.near,
        greaterThan(200),
        reason: 'the sky view drew no deep-sky objects at rest (diff: $diff)',
      );
    });
  });
}

/// The sky view's base-scope painter, re-pointed at the deep-sky-only config so
/// the raster isolates the DSO layer while keeping the pop-in phase, quality
/// tier and pose the live widget actually built.
SkyCanvasPainter _baseDsoPainter(WidgetTester tester) {
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
  final live = painters.first;
  return SkyCanvasPainter(
    renderScope: live.renderScope,
    viewState: live.viewState,
    config: _dsoOnlyConfig,
    qualityConfig: live.qualityConfig,
    stars: const [],
    dsos: live.dsos,
    constellations: const [],
    observationTime: live.observationTime,
    latitude: live.latitude,
    longitude: live.longitude,
    dsoPopinAnimationPhase: live.dsoPopinAnimationPhase,
  );
}
