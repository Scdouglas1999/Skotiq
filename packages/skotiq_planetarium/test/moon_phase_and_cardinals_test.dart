import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/astronomy/astronomy_calculations.dart';
import 'package:skotiq_planetarium/src/rendering/render_quality.dart';
import 'package:skotiq_planetarium/src/rendering/sky_renderer.dart';

/// Covers the two things the sky painter used to state incorrectly on every
/// frame: the Moon's phase (wrong shape, wrong orientation) and the compass
/// labels (painted at fixed screen corners regardless of where the user looks).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Fixed instant + mid-northern site so every sidereal-time-dependent
  // projection below is deterministic.
  final time = DateTime.utc(2026, 6, 6, 4, 0, 0);
  const latitude = 40.0;
  const longitude = -75.0;
  const size = Size(400, 400);

  SkyCanvasPainter painterAt({
    required SkyViewState viewState,
    (double, double)? sun,
    (double, double, double)? moon,
    SkyRenderConfig config = const SkyRenderConfig(),
  }) => SkyCanvasPainter(
    viewState: viewState,
    config: config,
    qualityConfig: const RenderQualityConfig.minimal(),
    stars: const [],
    dsos: const [],
    constellations: const [],
    observationTime: time,
    latitude: latitude,
    longitude: longitude,
    sunPosition: sun,
    moonPosition: moon,
  );

  group('lunar terminator geometry', () {
    test('semi-minor axis is |2k-1| and never a cosine of it', () {
      // Wrapping |2k-1| in another cosine makes the ellipse full width at
      // first quarter (drawn as a new moon) and zero width at k = 0.75 (drawn
      // as full).
      expect(
        MoonPhaseGeometry.terminatorSemiAxisFraction(0.0),
        closeTo(1.0, 1e-9),
      );
      expect(
        MoonPhaseGeometry.terminatorSemiAxisFraction(0.25),
        closeTo(0.5, 1e-9),
      );
      expect(
        MoonPhaseGeometry.terminatorSemiAxisFraction(0.5),
        closeTo(0.0, 1e-9),
      );
      expect(
        MoonPhaseGeometry.terminatorSemiAxisFraction(0.75),
        closeTo(0.5, 1e-9),
      );
      expect(
        MoonPhaseGeometry.terminatorSemiAxisFraction(1.0),
        closeTo(1.0, 1e-9),
      );
    });

    test('lit fraction of the construction equals the illumination', () {
      for (final k in [0.0, 0.25, 0.5, 0.75, 1.0]) {
        expect(
          MoonPhaseGeometry.litDiscFraction(k),
          closeTo(k, 1e-9),
          reason: 'illumination $k must paint exactly that fraction lit',
        );
      }
    });

    test('lit fraction is monotonic across the whole month', () {
      var previous = -1.0;
      for (var i = 0; i <= 200; i++) {
        final lit = MoonPhaseGeometry.litDiscFraction(i / 200);
        expect(
          lit,
          greaterThan(previous),
          reason: 'regressed at k = ${i / 200}',
        );
        previous = lit;
      }
    });

    test(
      'non-finite and out-of-range illumination are clamped, not propagated',
      () {
        expect(MoonPhaseGeometry.terminatorSemiAxisFraction(double.nan), 0.0);
        expect(MoonPhaseGeometry.litDiscFraction(double.infinity), 0.0);
        expect(
          MoonPhaseGeometry.terminatorSemiAxisFraction(1.4),
          closeTo(1.0, 1e-9),
        );
        expect(MoonPhaseGeometry.litDiscFraction(-0.2), closeTo(0.0, 1e-9));
      },
    );
  });

  group('bright limb position angle', () {
    double pa({
      required double sunRa,
      required double sunDec,
      double moonRa = 0,
      double moonDec = 0,
    }) => MoonPhaseGeometry.brightLimbPositionAngleDeg(
      sunRaDeg: sunRa,
      sunDecDeg: sunDec,
      moonRaDeg: moonRa,
      moonDecDeg: moonDec,
    );

    test('points at the Sun for the four cardinal configurations', () {
      // Sun a quarter turn east of the Moon on the equator: the lit limb faces
      // east, position angle 90.
      expect(pa(sunRa: 90, sunDec: 0), closeTo(90, 1e-6));
      // A quarter turn west: 270.
      expect(pa(sunRa: 270, sunDec: 0), closeTo(270, 1e-6));
      // Same RA, Sun north of the Moon: position angle 0 (due north).
      expect(pa(sunRa: 0, sunDec: 30), closeTo(0, 1e-6));
      // Same RA, Sun south: 180.
      expect(pa(sunRa: 0, sunDec: -30), closeTo(180, 1e-6));
    });

    test('matches the great-circle bearing from the Moon to the Sun', () {
      final (sunRa, sunDec) = AstronomyCalculations.sunPosition(time);
      final (moonRa, moonDec, _) = AstronomyCalculations.moonPosition(time);
      expect(
        pa(sunRa: sunRa, sunDec: sunDec, moonRa: moonRa, moonDec: moonDec),
        closeTo(
          AstronomyCalculations.positionAngle(
            ra1Deg: moonRa,
            dec1Deg: moonDec,
            ra2Deg: sunRa,
            dec2Deg: sunDec,
          ),
          1e-9,
        ),
      );
    });
  });

  group('bright limb screen angle', () {
    // Equatorial view centred on the Moon. In this frame celestial north is
    // screen-up and celestial east is screen-left (the mirrored "looking at the
    // sky" orientation), so a known position angle has a known screen angle.
    const view = SkyViewState(centerRA: 0, centerDec: 0, fieldOfView: 20);
    const moon = (0.0, 0.0, 0.5);

    double angleFor((double, double) sun) {
      final angle = painterAt(
        viewState: view,
        sun: sun,
        moon: moon,
      ).moonBrightLimbScreenAngle(size);
      expect(angle, isNotNull);
      return angle!;
    }

    /// Screen direction the local +x axis maps to after rotating by [angle].
    Offset limbDirection(double angle) =>
        Offset(math.cos(angle), math.sin(angle));

    test('Sun to the celestial east puts the lit limb screen-left', () {
      final d = limbDirection(angleFor((90.0, 0.0)));
      expect(d.dx, lessThan(-0.99));
      expect(d.dy.abs(), lessThan(0.02));
    });

    test('Sun to the celestial west puts the lit limb screen-right', () {
      final d = limbDirection(angleFor((270.0, 0.0)));
      expect(d.dx, greaterThan(0.99));
      expect(d.dy.abs(), lessThan(0.02));
    });

    test('Sun to the north puts the lit limb screen-up', () {
      final d = limbDirection(angleFor((0.0, 30.0)));
      expect(d.dy, lessThan(-0.99));
      expect(d.dx.abs(), lessThan(0.02));
    });

    test('Sun to the south puts the lit limb screen-down', () {
      final d = limbDirection(angleFor((0.0, -30.0)));
      expect(d.dy, greaterThan(0.99));
      expect(d.dx.abs(), lessThan(0.02));
    });

    test('horizontal mode keeps north-up over the southern horizon', () {
      // The Moon due south at 40 deg altitude, with the view centred on it.
      // Looking south, celestial north runs up toward the zenith on screen.
      final lst = AstronomyCalculations.localSiderealTime(time, longitude);
      final (moonRa, moonDec) = AstronomyCalculations.horizontalToEquatorial(
        altDeg: 40,
        azDeg: 180,
        latitudeDeg: latitude,
        lstHours: lst,
      );
      final angle = painterAt(
        viewState: const SkyViewState(
          viewMode: SkyViewMode.horizontal,
          centerAz: 180,
          centerAltitude: 40,
          fieldOfView: 60,
        ),
        // Sun directly north of the Moon: position angle 0.
        sun: (moonRa, moonDec + 20),
        moon: (moonRa, moonDec, 0.5),
      ).moonBrightLimbScreenAngle(size);
      expect(angle, isNotNull);
      expect(limbDirection(angle!).dy, lessThan(-0.9));
    });

    test('returns null without a Sun position so the caller can fall back', () {
      expect(
        painterAt(viewState: view, moon: moon).moonBrightLimbScreenAngle(size),
        isNull,
      );
    });
  });

  group('rendered moon phase', () {
    const litColor = Color(0xFFECEFF1);
    const darkColor = Color(0xFF37474F);

    /// Render only the Moon and return the fraction of the disc painted lit.
    Future<double> renderedLitFraction(double illumination) async {
      final painter = painterAt(
        // Tight field of view so the disc clamps to its maximum 80px radius and
        // the pixel count is precise.
        viewState: const SkyViewState(
          centerRA: 0,
          centerDec: 0,
          fieldOfView: 1,
        ),
        sun: (90.0, 0.0),
        // The painter's moon tuple carries a PERCENT — the unit
        // AstronomyCalculations.moonIllumination and every producer emit.
        moon: (0.0, 0.0, illumination * 100),
        config: const SkyRenderConfig(
          showStars: false,
          showConstellationLines: false,
          showConstellationLabels: false,
          showDSOs: false,
          showHorizon: false,
          showGroundPlane: false,
          showCardinalDirections: false,
          showSun: false,
          showMoon: true,
          showPlanets: false,
          showMountPosition: false,
        ),
      );

      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), size);
      final picture = recorder.endRecording();
      final image = await picture.toImage(
        size.width.toInt(),
        size.height.toInt(),
      );
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;

      bool matches(int i, Color c) =>
          bytes.getUint8(i + 3) == 255 &&
          (bytes.getUint8(i) - (c.r * 255).round()).abs() <= 6 &&
          (bytes.getUint8(i + 1) - (c.g * 255).round()).abs() <= 6 &&
          (bytes.getUint8(i + 2) - (c.b * 255).round()).abs() <= 6;

      var lit = 0;
      var dark = 0;
      final w = size.width.toInt();
      for (var y = 0; y < size.height.toInt(); y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 4;
          if (matches(i, litColor)) {
            lit++;
          } else if (matches(i, darkColor)) {
            dark++;
          }
        }
      }

      image.dispose();
      picture.dispose();

      expect(lit + dark, greaterThan(15000), reason: 'moon disc was not drawn');
      return lit / (lit + dark);
    }

    test('lit area tracks illumination through the whole cycle', () async {
      // A non-monotonic construction reads 0.0 at first quarter and 1.0 at
      // k = 0.75.
      for (final k in [0.05, 0.25, 0.5, 0.75, 0.95]) {
        expect(
          await renderedLitFraction(k),
          closeTo(k, 0.03),
          reason: 'rendered phase does not match illumination $k',
        );
      }
    });
  });

  group('cardinal direction labels', () {
    SkyCanvasPainter compassPainter(SkyViewState viewState) =>
        painterAt(viewState: viewState);

    test('horizontal view: labels track the direction the user is facing', () {
      final south = compassPainter(
        const SkyViewState(
          viewMode: SkyViewMode.horizontal,
          centerAz: 180,
          centerAltitude: 20,
          fieldOfView: 170,
        ),
      ).cardinalScreenPositions(size);

      expect(south.keys, contains('S'));
      expect(
        south.keys,
        isNot(contains('N')),
        reason: 'North is behind the viewer and must not be labelled',
      );
      // Due south sits on the vertical centre line of the view.
      expect(south['S']!.dx, closeTo(size.width / 2, 1.0));

      // Facing south, azimuth increases to the right: SE is left of S, SW right.
      expect(south['SE']!.dx, lessThan(south['S']!.dx));
      expect(south['SW']!.dx, greaterThan(south['S']!.dx));

      final north = compassPainter(
        const SkyViewState(
          viewMode: SkyViewMode.horizontal,
          centerAz: 0,
          centerAltitude: 20,
          fieldOfView: 170,
        ),
      ).cardinalScreenPositions(size);

      expect(north.keys, contains('N'));
      expect(north.keys, isNot(contains('S')));
      expect(north['N']!.dx, closeTo(size.width / 2, 1.0));
    });

    test('equatorial view: labels agree with the horizontal view', () {
      final lst = AstronomyCalculations.localSiderealTime(time, longitude);
      final (ra, dec) = AstronomyCalculations.horizontalToEquatorial(
        altDeg: 45,
        azDeg: 180,
        latitudeDeg: latitude,
        lstHours: lst,
      );

      final points = compassPainter(
        SkyViewState(centerRA: ra / 15, centerDec: dec, fieldOfView: 120),
      ).cardinalScreenPositions(size);

      expect(points.keys, contains('S'));
      expect(points.keys, isNot(contains('N')));
      // South is straight ahead and below the view centre (the centre is 45 deg
      // up, the compass point is on the horizon).
      expect(points['S']!.dx, closeTo(size.width / 2, 2.0));
      expect(points['S']!.dy, greaterThan(size.height / 2));
      // Same left/right ordering as the horizontal view.
      expect(points['SE']!.dx, lessThan(points['S']!.dx));
      expect(points['SW']!.dx, greaterThan(points['S']!.dx));
    });

    test('points behind the viewer or off canvas are dropped', () {
      final points = compassPainter(
        const SkyViewState(
          viewMode: SkyViewMode.horizontal,
          centerAz: 90,
          centerAltitude: 10,
          fieldOfView: 60,
        ),
      ).cardinalScreenPositions(size);

      expect(points.keys, contains('E'));
      expect(points.keys.length, lessThan(8));
      for (final entry in points.entries) {
        expect(
          Rect.fromLTWH(0, 0, size.width, size.height).contains(entry.value),
          isTrue,
          reason: '${entry.key} projected outside the canvas',
        );
      }
    });

    test('labels move when the view moves', () {
      Offset southAt(double az) => compassPainter(
        SkyViewState(
          viewMode: SkyViewMode.horizontal,
          centerAz: az,
          centerAltitude: 20,
          fieldOfView: 170,
        ),
      ).cardinalScreenPositions(size)['S']!;

      // Labels follow the sky, not a fixed screen corner, so rotating the view
      // moves them.
      expect((southAt(180) - southAt(210)).distance, greaterThan(20));
    });
  });
}
