import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Cover for the "Trails" mark: the geometry must match the approved
/// reference (`brand-ref/trails_reference.py`) to the digit, the motion must
/// match `motion_reference.html`, and the widget must behave like a good
/// citizen of the package — no ticker for a still mark, no frames scheduled
/// while off screen, no motion at all when the platform asks for none.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('trails geometry — reference port', () {
    // (start, waist, end) per lane, computed by the reference's lane() and
    // printed to 10 decimals.
    const expected = <TrailsLevel, List<List<double>>>{
      TrailsLevel.full: [
        [67.6514408808, 22.2091829527, 50, 58.4, 46.2528686044, 68.1616110227],
        [66.8747461531, 29.1821599998, 50, 54.2, 41.5129510429, 68.9],
        [59.7252171864, 25.9292427953, 50, 50, 39.2753777963, 72.9990265356],
        [58.4870489571, 31.1, 50, 45.8, 32.8975943017, 70.2247666085],
        [52.8, 31.1502577388, 50, 41.6, 39.4838369936, 83.7780260800],
      ],
      TrailsLevel.mid: [
        [66.5482258257, 23.0711090182, 50, 57, 45.3160857555, 69.2020137783],
        [59.7252171864, 25.9292427953, 50, 50, 39.2753777963, 72.9990265356],
        [53.5, 29.9378221735, 50, 43, 40.1410971815, 82.5418994500],
      ],
      TrailsLevel.flat: [
        [64.2484266420, 24.0441504598, 50, 54.6, 43.4702113177, 70.7617941232],
        [55.7872178681, 28.5926989161, 50, 45.4, 39.5990119954, 79.4200988495],
      ],
    };

    test('every lane endpoint matches the reference to 1e-6', () {
      for (final level in TrailsLevel.values) {
        final spec = trailsLevels[level]!;
        for (var i = 0; i < spec.lanes.length; i++) {
          final p = trailsLanePoints(spec.lanes[i]);
          final e = expected[level]![i];
          expect(
            p.start.dx,
            moreOrLessEquals(e[0], epsilon: 1e-6),
            reason: '$level lane $i start.x',
          );
          expect(
            p.start.dy,
            moreOrLessEquals(e[1], epsilon: 1e-6),
            reason: '$level lane $i start.y',
          );
          expect(
            p.waist.dx,
            moreOrLessEquals(e[2], epsilon: 1e-6),
            reason: '$level lane $i waist.x',
          );
          expect(
            p.waist.dy,
            moreOrLessEquals(e[3], epsilon: 1e-6),
            reason: '$level lane $i waist.y',
          );
          expect(
            p.end.dx,
            moreOrLessEquals(e[4], epsilon: 1e-6),
            reason: '$level lane $i end.x',
          );
          expect(
            p.end.dy,
            moreOrLessEquals(e[5], epsilon: 1e-6),
            reason: '$level lane $i end.y',
          );
        }
      }
    });

    test('the waist sits at (50, 50 + offset) on every lane', () {
      // The shared centerline radius is what makes the S seamless: each
      // lane's two arcs join exactly on the x = 50 axis, offset by the lane's
      // own radius offset.
      for (final level in TrailsLevel.values) {
        for (final lane in trailsLevels[level]!.lanes) {
          final p = trailsLanePoints(lane);
          expect(p.waist.dx, moreOrLessEquals(50, epsilon: 1e-9));
          expect(p.waist.dy, moreOrLessEquals(50 + lane.offset, epsilon: 1e-9));
        }
      }
    });

    // Arc lengths per lane, as radius × sweep — the reference emits pure `A`
    // commands with no straight segments, so a faithful Path has exactly
    // these metric lengths.
    const expectedLengths = <TrailsLevel, List<List<double>>>{
      TrailsLevel.full: [
        [90.701271, 21.697933],
        [78.777181, 41.050144],
        [54.733525, 56.199602],
        [41.050144, 79.412481],
        [20.525072, 81.318381],
      ],
      TrailsLevel.mid: [
        [85.032441, 27.122417],
        [54.733525, 56.199602],
        [25.656340, 76.235982],
      ],
      TrailsLevel.flat: [
        [74.665185, 36.749653],
        [35.765287, 69.471086],
      ],
    };

    test('built paths visit start, waist and end in order', () {
      for (final level in TrailsLevel.values) {
        final spec = trailsLevels[level]!;
        for (var i = 0; i < spec.lanes.length; i++) {
          final lane = spec.lanes[i];
          final points = trailsLanePoints(lane);
          final metric = trailsLanePath(lane).computeMetrics().first;
          final (upper, lower) = (
            expectedLengths[level]![i][0],
            expectedLengths[level]![i][1],
          );

          // Flutter approximates arcs with conics, which shortens the
          // measured length by up to ~1% — enough to prove the arcs are
          // real arcs without pretending the approximation is exact.
          expect(
            metric.length,
            moreOrLessEquals(upper + lower, epsilon: (upper + lower) * 0.02),
            reason: '$level lane $i total length',
          );

          // Endpoints are exact: arcToPoint continues to the given point.
          final atStart = metric.getTangentForOffset(0)!;
          final atEnd = metric.getTangentForOffset(metric.length)!;
          for (final (pos, want) in [
            (atStart.position, points.start),
            (atEnd.position, points.end),
          ]) {
            expect(pos.dx, moreOrLessEquals(want.dx, epsilon: 0.02));
            expect(pos.dy, moreOrLessEquals(want.dy, epsilon: 0.02));
          }

          // At the join the two arcs share the waist and a horizontal
          // tangent (bottom of the upper bowl / top of the lower). The
          // conic approximation shifts the measured join point by a few
          // tenths of a unit.
          final atWaist = metric.getTangentForOffset(upper)!;
          expect(
            atWaist.position.dx,
            moreOrLessEquals(points.waist.dx, epsilon: 0.8),
          );
          expect(
            atWaist.position.dy,
            moreOrLessEquals(points.waist.dy, epsilon: 0.8),
          );
          expect(atWaist.vector.dx, moreOrLessEquals(1, epsilon: 0.05));
          expect(atWaist.vector.dy, moreOrLessEquals(0, epsilon: 0.05));
        }
      }
    });

    test('arcs take the reference sweep directions', () {
      // Upper arc runs toward decreasing angle (y-down counterclockwise), so
      // its start tangent is (sin s, −cos s). Lower runs toward increasing
      // angle, so its end tangent is (−sin e, cos e).
      for (final level in TrailsLevel.values) {
        for (final lane in trailsLevels[level]!.lanes) {
          final metric = trailsLanePath(lane).computeMetrics().first;
          final s = lane.upStartDegrees * math.pi / 180;
          final e = lane.loEndDegrees * math.pi / 180;
          final startTangent = metric.getTangentForOffset(0)!.vector;
          final endTangent = metric.getTangentForOffset(metric.length)!.vector;
          expect(startTangent.dx, moreOrLessEquals(math.sin(s), epsilon: 0.02));
          expect(
            startTangent.dy,
            moreOrLessEquals(-math.cos(s), epsilon: 0.02),
          );
          expect(endTangent.dx, moreOrLessEquals(-math.sin(e), epsilon: 0.02));
          expect(endTangent.dy, moreOrLessEquals(math.cos(e), epsilon: 0.02));
        }
      }
    });
  });

  group('level selection', () {
    test('full from 64, mid 24–63, flat below 24', () {
      expect(trailsLevelForSize(200), TrailsLevel.full);
      expect(trailsLevelForSize(64), TrailsLevel.full);
      expect(trailsLevelForSize(63.9), TrailsLevel.mid);
      expect(trailsLevelForSize(24), TrailsLevel.mid);
      expect(trailsLevelForSize(23.9), TrailsLevel.flat);
      expect(trailsLevelForSize(16), TrailsLevel.flat);
      expect(trailsLevelForSize(0), TrailsLevel.flat);
    });
  });

  group('TrailsMotion — reference port', () {
    final spec = trailsLevels[TrailsLevel.full]!;

    test('draw staggers lanes 90 ms apart over 1176 ms each', () {
      expect(TrailsMotion.drawLaneFraction(0, 0), 0);
      expect(TrailsMotion.drawLaneFraction(0, 1176), 1);
      expect(TrailsMotion.drawLaneFraction(4, 360), 0);
      expect(TrailsMotion.drawLaneFraction(4, 1536), 1);
      // Easing is cubic-bezier(.22,.7,.2,1) — quick off the mark: well past
      // linear progress at mid-draw.
      final mid = TrailsMotion.drawLaneFraction(0, 588);
      expect(mid, greaterThan(0.6));
      expect(mid, lessThan(1));
    });

    test('the pole pops after the draw, overshooting to 1.25', () {
      expect(TrailsMotion.drawPole(1092), (0, 0));
      final (scale, opacity) = TrailsMotion.drawPole(1386);
      expect(scale, moreOrLessEquals(1.25, epsilon: 1e-9));
      expect(opacity, moreOrLessEquals(1, epsilon: 1e-9));
      final (settled, _) = TrailsMotion.drawPole(1596);
      expect(settled, moreOrLessEquals(1, epsilon: 1e-9));
      // Mid-overshoot: above rest size, still below the peak.
      final (popping, _) = TrailsMotion.drawPole(1400);
      expect(popping, lessThan(1.25));
    });

    test('draw duration covers lanes plus pole, shorter without a pole', () {
      expect(
        TrailsMotion.drawDuration(trailsLevels[TrailsLevel.full]!),
        const Duration(milliseconds: 1596),
      );
      expect(
        TrailsMotion.drawDuration(trailsLevels[TrailsLevel.flat]!),
        const Duration(milliseconds: 1176 + 90),
      );
    });

    test('loading offsets each lane a phase step behind', () {
      expect(TrailsMotion.loadingDashStart(0, spec, 0), 0);
      expect(
        TrailsMotion.loadingDashStart(1, spec, 0),
        moreOrLessEquals(250 / 2200, epsilon: 1e-9),
      );
      // The dash wraps around the end of the path.
      expect(
        TrailsMotion.loadingDashStart(1, spec, 0.9),
        moreOrLessEquals((0.9 + 250 / 2200) % 1, epsilon: 1e-9),
      );
      // Reduced levels double the step, matching the reference demo.
      expect(
        TrailsMotion.loadingDashStart(1, trailsLevels[TrailsLevel.mid]!, 0),
        moreOrLessEquals(500 / 2200, epsilon: 1e-9),
      );
    });

    test('working glint sweeps once and fades on the keyframe timings', () {
      expect(TrailsMotion.glintOpacity(0), 0);
      expect(
        TrailsMotion.glintOpacity(0.12),
        moreOrLessEquals(0.75, epsilon: 1e-9),
      );
      expect(
        TrailsMotion.glintOpacity(0.5),
        moreOrLessEquals(0.75, epsilon: 1e-9),
      );
      expect(
        TrailsMotion.glintOpacity(0.88),
        moreOrLessEquals(0, epsilon: 1e-9),
      );
      expect(TrailsMotion.glintOpacity(0.95), 0);
      // Offset .1 → -.95 with pathLength 1: the dash starts at 0.9 and sweeps
      // the full path forward.
      expect(TrailsMotion.glintStart(0), moreOrLessEquals(0.9, epsilon: 1e-9));
      expect(
        TrailsMotion.glintStart(0.88),
        moreOrLessEquals(0.95, epsilon: 1e-9),
      );
      expect(TrailsMotion.glintStart(1), moreOrLessEquals(0.95, epsilon: 1e-9));
    });
  });

  group('SkotiqMark widget', () {
    Widget host(
      Widget child, {
      ThemeData? theme,
      bool disableAnimations = false,
    }) {
      return MaterialApp(
        theme: theme ?? SkotiqTheme.dark,
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: disableAnimations),
          child: Scaffold(body: Center(child: child)),
        ),
      );
    }

    TrailsMarkPainter painter(WidgetTester tester) {
      return tester
              .widget<CustomPaint>(
                find.descendant(
                  of: find.byType(SkotiqMark),
                  matching: find.byType(CustomPaint),
                ),
              )
              .painter
          as TrailsMarkPainter;
    }

    AnimationController controller(WidgetTester tester) =>
        (tester.state(find.byType(SkotiqMark, skipOffstage: false)) as dynamic)
                .debugControllerForTesting
            as AnimationController;

    testWidgets('publishes its semantic label, and none without one', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const SkotiqMark(semanticLabel: 'Skotiq mark')),
      );
      expect(find.bySemanticsLabel('Skotiq mark'), findsOneWidget);

      await tester.pumpWidget(host(const SkotiqMark()));
      expect(find.bySemanticsLabel('Skotiq mark'), findsNothing);
    });

    testWidgets('draw calls onDrawComplete exactly once', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        host(
          SkotiqMark(
            motion: SkotiqMarkMotion.draw,
            onDrawComplete: () => calls++,
          ),
        ),
      );
      await tester.pump();
      expect(calls, 0);
      await tester.pump(const Duration(milliseconds: 1600));
      expect(calls, 1);
      // The callback is a hand-off signal, not a per-frame report.
      await tester.pump(const Duration(seconds: 1));
      expect(calls, 1);
    });

    testWidgets('reduced motion draws the still mark and calls back once', (
      tester,
    ) async {
      var calls = 0;
      await tester.pumpWidget(
        host(
          SkotiqMark(
            motion: SkotiqMarkMotion.draw,
            onDrawComplete: () => calls++,
          ),
          disableAnimations: true,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(calls, 1);
      expect(painter(tester).motion, SkotiqMarkMotion.none);
      expect(
        tester.binding.transientCallbackCount,
        0,
        reason: 'reduced motion must not leave a ticker running',
      );
    });

    testWidgets('loading runs only while painted', (tester) async {
      await tester.pumpWidget(
        host(
          const Offstage(
            offstage: true,
            child: SkotiqMark(motion: SkotiqMarkMotion.loading),
          ),
        ),
      );
      // The gate assumes on-screen until a few ticks pass unpainted.
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 32));
      }
      expect(
        controller(tester).isAnimating,
        isFalse,
        reason: 'an off-screen loop must not schedule frames',
      );

      await tester.pumpWidget(
        host(
          const Offstage(
            offstage: false,
            child: SkotiqMark(motion: SkotiqMarkMotion.loading),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 32));
      await tester.pump(const Duration(milliseconds: 32));
      expect(controller(tester).isAnimating, isTrue);
    });

    testWidgets('a loading mark left on screen animates but rebuilds nothing', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const SkotiqMark(motion: SkotiqMarkMotion.loading)),
      );
      await tester.pump();
      expect(controller(tester).isAnimating, isTrue);
      // The painter drives repaints through its listenable; the widget does
      // not rebuild per frame.
      final before = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(SkotiqMark),
          matching: find.byType(CustomPaint),
        ),
      );
      await tester.pump(const Duration(milliseconds: 48));
      final after = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(SkotiqMark),
          matching: find.byType(CustomPaint),
        ),
      );
      expect(identical(before, after), isTrue);
    });

    testWidgets('theme and violet map to red under the red night theme', (
      tester,
    ) async {
      // MaterialApp animates theme changes (~200 ms), and SkotiqColors.lerp
      // keeps the old palette until halfway — pump past the transition so
      // each expectation sees the settled theme.
      await tester.pumpWidget(
        host(const SkotiqMark(), theme: SkotiqTheme.redNight),
      );
      expect(
        painter(tester).laneColors,
        equals(trailsPalettes[SkotiqMarkTone.red]),
      );
      // An explicit violet tone maps the same way — the wavelength
      // constraint outranks a fixed colorway too.
      await tester.pumpWidget(
        host(
          const SkotiqMark(tone: SkotiqMarkTone.violet),
          theme: SkotiqTheme.redNight,
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        painter(tester).laneColors,
        equals(trailsPalettes[SkotiqMarkTone.red]),
      );
      // And the explicit tone keeps its own palette under the dark theme.
      await tester.pumpWidget(
        host(const SkotiqMark(tone: SkotiqMarkTone.violet)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        painter(tester).laneColors,
        equals(trailsPalettes[SkotiqMarkTone.violet]),
      );
      // An explicit red tone renders red everywhere.
      await tester.pumpWidget(
        host(
          const SkotiqMark(tone: SkotiqMarkTone.red),
          theme: SkotiqTheme.dark,
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        painter(tester).laneColors,
        equals(trailsPalettes[SkotiqMarkTone.red]),
      );
    });

    testWidgets('theme derives the lanes from the active accent', (
      tester,
    ) async {
      // Under the default dark theme the ramp comes off the palette's own
      // primary (#A48CF2); the poles and the warm lane are brandWarm.
      await tester.pumpWidget(host(const SkotiqMark()));
      final derived = themeTrailsRamp(
        SkotiqColors.dark.primary,
        brandWarm: SkotiqColors.dark.brandWarm,
        lightGround: false,
      );
      expect(
        painter(tester).laneColors,
        equals([derived[0], derived[1], derived[2], derived[3], derived[4]]),
      );
      expect(painter(tester).poleColor, SkotiqColors.dark.brandWarm);

      // A custom accent recolors the whole mark.
      await tester.pumpWidget(
        host(
          const SkotiqMark(),
          theme: SkotiqTheme.darkWithAccent(const Color(0xFF43B67A)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final green = themeTrailsRamp(
        const Color(0xFF43B67A),
        brandWarm: SkotiqColors.dark.brandWarm,
        lightGround: false,
      );
      expect(painter(tester).laneColors, equals(green));

      // themeAccent overrides the ambient accent — the swatch preview.
      await tester.pumpWidget(
        host(const SkotiqMark(themeAccent: Color(0xFFE0A53E))),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        painter(tester).laneColors,
        equals(
          themeTrailsRamp(
            const Color(0xFFE0A53E),
            brandWarm: SkotiqColors.dark.brandWarm,
            lightGround: false,
          ),
        ),
      );
    });

    testWidgets('theme picks the light stops on a light ground', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const SkotiqMark(), theme: SkotiqTheme.light),
      );
      expect(
        painter(tester).laneColors,
        equals(
          themeTrailsRamp(
            SkotiqColors.light.primary,
            brandWarm: SkotiqColors.light.brandWarm,
            lightGround: true,
          ),
        ),
      );
      expect(painter(tester).poleColor, SkotiqColors.light.brandWarm);

      // The tile is a dark ground even under the light theme — the mark
      // paints its icon look, so it takes the dark recipe.
      await tester.pumpWidget(
        host(const SkotiqMark(tile: true), theme: SkotiqTheme.light),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        painter(tester).laneColors,
        equals(
          themeTrailsRamp(
            SkotiqColors.light.primary,
            brandWarm: SkotiqColors.dark.brandWarm,
            lightGround: false,
          ),
        ),
      );
    });

    testWidgets('mono inherits the ambient icon color', (tester) async {
      const ink = Color(0xFFA1B2C3);
      await tester.pumpWidget(
        host(
          const IconTheme(
            data: IconThemeData(color: ink),
            child: SkotiqMark(tone: SkotiqMarkTone.mono),
          ),
        ),
      );
      expect(painter(tester).laneColors, everyElement(equals(ink)));
      await tester.pumpWidget(
        host(
          const SkotiqMark(tone: SkotiqMarkTone.mono, color: Color(0xFF102030)),
        ),
      );
      expect(
        painter(tester).laneColors,
        everyElement(equals(const Color(0xFF102030))),
      );
    });
  });

  group('SkotiqMark still frames', () {
    // Paint the painter onto a raster image at a known progress value and
    // sample pixels — a still-frame check at known animation times without
    // golden files. Painted at 100 px so viewBox units are pixels.

    final spec = trailsLevels[TrailsLevel.full]!;
    final palette = trailsPalettes[SkotiqMarkTone.violet]!;

    // Where a viewBox point lands after the reference's icon transform:
    // translate(50 50) scale(1.08) translate(-50 -50.5).
    Offset iconSpace(Offset p) =>
        Offset((p.dx - 50) * 1.08 + 50, (p.dy - 50.5) * 1.08 + 50);

    // A point on lane [index] at [fraction] of its path length, in painted
    // pixel coordinates.
    Offset probe(int index, double fraction) {
      final metric = trailsLanePath(spec.lanes[index]).computeMetrics().first;
      return iconSpace(
        metric.getTangentForOffset(fraction * metric.length)!.position,
      );
    }

    Future<ByteData> paintMark({
      SkotiqMarkMotion motion = SkotiqMarkMotion.none,
      double t = 0,
      bool tile = false,
      List<Color>? laneColors,
      Color? poleColor,
    }) {
      final painter = TrailsMarkPainter(
        spec: spec,
        laneColors: laneColors ?? [for (final k in spec.pick) palette[k]],
        poleColor: poleColor ?? palette[3],
        tile: tile,
        tileGround: TrailsGeometry.tileGround,
        motion: motion,
        progress: AlwaysStoppedAnimation(t),
      );
      final recorder = ui.PictureRecorder();
      painter.paint(ui.Canvas(recorder), const Size.square(100));
      final image = recorder.endRecording().toImageSync(100, 100);
      return image.toByteData(format: ui.ImageByteFormat.rawRgba).then((d) {
        image.dispose();
        return d!;
      });
    }

    /// Raw (r, g, b, a) bytes at the nearest pixel to [at].
    ({int r, int g, int b, int a}) px(ByteData data, Offset at) {
      final x = at.dx.round();
      final y = at.dy.round();
      final i = (y * 100 + x) * 4;
      return (
        r: data.getUint8(i),
        g: data.getUint8(i + 1),
        b: data.getUint8(i + 2),
        a: data.getUint8(i + 3),
      );
    }

    testWidgets('draw paints nothing, then partial lanes, then the pole', (
      tester,
    ) async {
      late ByteData frame;
      await tester.runAsync(() async {
        // t = 0: nothing drawn — lanes and pole are still empty.
        frame = await paintMark(motion: SkotiqMarkMotion.draw, t: 0);
        expect(px(frame, probe(0, 0.0)).a, lessThan(90));
        expect(px(frame, probe(4, 0.0)).a, lessThan(90));
        expect(px(frame, iconSpace(TrailsGeometry.poleCenter)).a, lessThan(90));

        // ~560 ms in: lane 0 is mid-draw (start lit, far end not), lane 4
        // has just started, the pole is still hidden.
        frame = await paintMark(motion: SkotiqMarkMotion.draw, t: 0.35);
        expect(px(frame, probe(0, 0.02)).a, greaterThan(200));
        expect(px(frame, probe(0, 0.98)).a, lessThan(90));
        expect(px(frame, probe(4, 0.02)).a, greaterThan(200));
        expect(px(frame, iconSpace(TrailsGeometry.poleCenter)).a, lessThan(90));

        // Complete: every lane lit end to end, pole popped.
        frame = await paintMark(motion: SkotiqMarkMotion.draw, t: 1);
        expect(px(frame, probe(0, 0.98)).a, greaterThan(200));
        expect(
          px(frame, iconSpace(TrailsGeometry.poleCenter)).a,
          greaterThan(200),
        );
      });
    });

    testWidgets('loading dims all lanes and lights one dash per lane', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final frame = await paintMark(motion: SkotiqMarkMotion.loading, t: 0);
        // Lane 0's dash sits at the path start — lit at full alpha.
        expect(px(frame, probe(0, 0.02)).a, greaterThan(200));
        // Well past the dash: only the 16% base shows.
        final dim = px(frame, probe(0, 0.6));
        expect(dim.a, greaterThan(15));
        expect(dim.a, lessThan(90));
        // Lane 1's dash is a phase step ahead — its start is still dim.
        expect(px(frame, probe(1, 0.02)).a, lessThan(90));
        // The pole stays lit through the loading motion.
        expect(
          px(frame, iconSpace(TrailsGeometry.poleCenter)).a,
          greaterThan(200),
        );
      });
    });

    testWidgets('working paints a white glint that fades out', (tester) async {
      await tester.runAsync(() async {
        var frame = await paintMark(motion: SkotiqMarkMotion.working, t: 0.4);
        // The glint's position at t = 0.4 on lane 0: a light pixel —
        // white at up to 75% over the lane color.
        final glintAt = px(
          frame,
          probe(0, TrailsMotion.glintStart(0.4) + 0.02),
        );
        expect(glintAt.r, greaterThan(180));
        expect(glintAt.g, greaterThan(150));
        expect(glintAt.b, greaterThan(180));
        // A different stretch of the same lane keeps the lane's color.
        final plain = px(frame, probe(0, 0.5));
        expect(plain.r, lessThan(150));

        // After the sweep window the glint is gone entirely.
        frame = await paintMark(motion: SkotiqMarkMotion.working, t: 0.95);
        expect(px(frame, probe(0, 0.0)).a, greaterThan(200));
      });
    });

    testWidgets('the tile grounds the mark', (tester) async {
      await tester.runAsync(() async {
        var frame = await paintMark(tile: true);
        // Mid-left edge: inside the rounding, clear of every lane.
        expect(px(frame, const Offset(4, 50)), (
          r: 0x0E,
          g: 0x0C,
          b: 0x16,
          a: 0xFF,
        ));
        frame = await paintMark();
        expect(px(frame, const Offset(4, 50)).a, 0);
      });
    });
  });

  group('themeTrailsRamp', () {
    /// CIE Lab of [c] under D65 — the input to [_deltaE00].
    List<double> lab(Color c) {
      double lin(double s) => s <= 0.04045
          ? s / 12.92
          : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
      final r = lin(c.r), g = lin(c.g), b = lin(c.b);
      final x = (r * 0.4124 + g * 0.3576 + b * 0.1805) / 0.95047;
      final y = r * 0.2126 + g * 0.7152 + b * 0.0722;
      final z = (r * 0.0193 + g * 0.1192 + b * 0.9505) / 1.08883;
      double f(double t) =>
          t > 0.008856 ? math.pow(t, 1 / 3).toDouble() : 7.787 * t + 16 / 116;
      return [116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))];
    }

    /// CIEDE2000 between two Lab triples — the same measure check_tokens.py
    /// uses for the brandWarm/warning floor.
    double deltaE00(List<double> a, List<double> b) {
      final l1 = a[0], a1 = a[1], b1 = a[2];
      final l2 = b[0], a2 = b[1], b2 = b[2];
      final c1 = math.sqrt(a1 * a1 + b1 * b1);
      final c2 = math.sqrt(a2 * a2 + b2 * b2);
      final cBar7 = math.pow((c1 + c2) / 2, 7).toDouble();
      final g = 0.5 * (1 - math.sqrt(cBar7 / (cBar7 + math.pow(25, 7))));
      final a1p = a1 * (1 + g), a2p = a2 * (1 + g);
      final c1p = math.sqrt(a1p * a1p + b1 * b1);
      final c2p = math.sqrt(a2p * a2p + b2 * b2);
      double hp(double ap, double bp) {
        if (ap == 0 && bp == 0) return 0;
        final h = math.atan2(bp, ap) * 180 / math.pi;
        return h < 0 ? h + 360 : h;
      }

      final h1p = hp(a1p, b1), h2p = hp(a2p, b2);
      final dl = l2 - l1, dc = c2p - c1p;
      var dh = 0.0;
      if (c1p * c2p != 0) {
        dh = h2p - h1p;
        if (dh > 180) dh -= 360;
        if (dh < -180) dh += 360;
      }
      final dH = 2 * math.sqrt(c1p * c2p) * math.sin(dh * math.pi / 360);
      final lBarP = (l1 + l2) / 2, cBarP = (c1p + c2p) / 2;
      var hBarP = h1p + h2p;
      if (c1p * c2p != 0) {
        hBarP = (h1p - h2p).abs() > 180
            ? (h1p + h2p < 360 ? h1p + h2p + 360 : h1p + h2p - 360) / 2
            : hBarP / 2;
      }
      final t =
          1 -
          0.17 * math.cos((hBarP - 30) * math.pi / 180) +
          0.24 * math.cos(2 * hBarP * math.pi / 180) +
          0.32 * math.cos((3 * hBarP + 6) * math.pi / 180) -
          0.20 * math.cos((4 * hBarP - 63) * math.pi / 180);
      final dTheta = 30 * math.exp(-math.pow((hBarP - 275) / 25, 2));
      final cBarP7 = math.pow(cBarP, 7).toDouble();
      final rc = 2 * math.sqrt(cBarP7 / (cBarP7 + math.pow(25, 7)));
      final sl =
          1 +
          0.015 *
              math.pow(lBarP - 50, 2) /
              math.sqrt(20 + math.pow(lBarP - 50, 2));
      final sc = 1 + 0.045 * cBarP;
      final sh = 1 + 0.015 * cBarP * t;
      final rt = -math.sin(2 * dTheta * math.pi / 180) * rc;
      return math.sqrt(
        math.pow(dl / sl, 2).toDouble() +
            math.pow(dc / sc, 2).toDouble() +
            math.pow(dH / sh, 2).toDouble() +
            rt * (dc / sc) * (dH / sh),
      );
    }

    test('the violet accent reproduces the approved colorway', () {
      // Approved violet lanes, outermost first.
      const approved = [
        Color(0xFF6E56CF),
        Color(0xFF8F7BEA),
        Color(0xFFB9ABFF),
        Color(0xFFE4DEFF),
      ];
      final dark = themeTrailsRamp(
        const Color(0xFFA48CF2),
        brandWarm: SkotiqColors.dark.brandWarm,
        lightGround: false,
      );
      for (var i = 0; i < 4; i++) {
        expect(
          deltaE00(lab(dark[i]), lab(approved[i])),
          lessThan(2.0),
          reason: 'dark lane $i',
        );
      }
      // Approved light colorway, same order.
      const approvedLight = [
        Color(0xFF4B36A8),
        Color(0xFF6A55CC),
        Color(0xFF8E7BE3),
        Color(0xFF2B2347),
      ];
      final light = themeTrailsRamp(
        const Color(0xFF6A4FD1),
        brandWarm: SkotiqColors.light.brandWarm,
        lightGround: true,
      );
      for (var i = 0; i < 4; i++) {
        expect(
          deltaE00(lab(light[i]), lab(approvedLight[i])),
          lessThan(2.0),
          reason: 'light lane $i',
        );
      }
    });

    test('the warm lane and the four cool lanes come out in order', () {
      final ramp = themeTrailsRamp(
        const Color(0xFF6EB3EC),
        brandWarm: const Color(0xFFFFD9A8),
        lightGround: false,
      );
      expect(ramp, hasLength(5));
      expect(ramp[4], const Color(0xFFFFD9A8));
      // On a dark ground the cool lanes lighten inward, as the violet
      // colorway runs #6E56CF → #E4DEFF.
      for (var i = 0; i < 3; i++) {
        expect(
          ramp[i + 1].computeLuminance(),
          greaterThan(ramp[i].computeLuminance()),
        );
      }
    });

    test('every accent keeps its hue through the cool lanes', () {
      const accents = {
        'blue': Color(0xFF6EB3EC),
        'green': Color(0xFF43B67A),
        'amber': Color(0xFFE0A53E),
        'pink': Color(0xFFE77FB3),
        'violet': Color(0xFFA48CF2),
      };
      for (final e in accents.entries) {
        final hue = HSVColor.fromColor(e.value).hue;
        final ramp = themeTrailsRamp(
          e.value,
          brandWarm: const Color(0xFFFFD9A8),
          lightGround: false,
        );
        for (var i = 0; i < 4; i++) {
          var diff = (HSVColor.fromColor(ramp[i]).hue - hue).abs();
          if (diff > 180) diff = 360 - diff;
          expect(diff, lessThan(30), reason: '${e.key} lane $i');
        }
      }
    });
  });

  group('SkotiqSpinner', () {
    testWidgets('is a small mono loading mark', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: Center(child: SkotiqSpinner(semanticLabel: 'Loading')),
          ),
        ),
      );
      final mark = tester.widget<SkotiqMark>(find.byType(SkotiqMark));
      expect(mark.motion, SkotiqMarkMotion.loading);
      expect(mark.tone, SkotiqMarkTone.mono);
      expect(mark.size, 16);
      expect(find.bySemanticsLabel('Loading'), findsOneWidget);
    });
  });

  group('SkotiqWordmark and SkotiqLockup', () {
    testWidgets('the wordmark is lowercase Sora SemiBold at −0.04em', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: Center(child: SkotiqWordmark(fontSize: 20)),
          ),
        ),
      );
      final text = tester.widget<Text>(find.text('skotiq'));
      expect(text.style!.fontFamily, 'Sora');
      expect(text.style!.fontWeight, FontWeight.w600);
      expect(text.style!.letterSpacing, moreOrLessEquals(-0.8, epsilon: 1e-9));
    });

    testWidgets('the lockup keeps the approved proportions', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: Center(child: SkotiqLockup(markSize: 40))),
        ),
      );
      expect(tester.widget<SkotiqMark>(find.byType(SkotiqMark)).size, 40);
      final text = tester.widget<Text>(find.text('skotiq'));
      // The drawn S (about 72% of the box) stands about 1.1 times the
      // wordmark's ascenders: fontSize = 0.85 × mark, gap = 0.25 × mark.
      expect(text.style!.fontSize, moreOrLessEquals(34, epsilon: 1e-9));
      final gap = find.byWidgetPredicate(
        (w) => w is SizedBox && w.width == SkotiqLockup.gapFor(40),
      );
      expect(gap, findsOneWidget);
    });
  });
}
