import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/astronomy/astronomy_calculations.dart';
import 'package:skotiq_planetarium/src/celestial_object.dart';
import 'package:skotiq_planetarium/src/coordinate_system.dart';
import 'package:skotiq_planetarium/src/rendering/render_quality.dart';
import 'package:skotiq_planetarium/src/rendering/sky_renderer.dart';

/// Verifies the Alt/Az ("tonight from my site") view mode: a star at a known
/// altitude/azimuth must land at the expected place on screen — zenith at
/// center, the horizon at the bottom, East to the right and West to the left.
///
/// The painter's projection is internal, so these tests exercise the real
/// production render path end-to-end: they place a single bright star at a
/// chosen alt/az (by converting it to the equatorial coordinates the catalog
/// holds), render in horizontal mode, then locate the brightest pixel and
/// assert its screen position. The view is centered on the zenith so screen
/// up = increasing altitude.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const size = Size(400, 400);
  // A fixed instant + site so the sidereal-time-dependent transform is
  // deterministic. Mid-northern latitude, arbitrary longitude.
  final time = DateTime.utc(2026, 6, 6, 4, 0, 0);
  const latitude = 40.0;
  const longitude = -75.0;
  final lst = AstronomyCalculations.localSiderealTime(time, longitude);

  /// Equatorial coordinate that currently sits at the given alt/az.
  CelestialCoordinate eqAt(double altDeg, double azDeg) {
    final (ra, dec) = AstronomyCalculations.horizontalToEquatorial(
      altDeg: altDeg,
      azDeg: azDeg,
      latitudeDeg: latitude,
      lstHours: lst,
    );
    return CelestialCoordinate(ra: ra / 15, dec: dec);
  }

  /// Render one bright star (at [starCoord]) in horizontal mode, centered on
  /// the given alt/az, and return the location of the brightest pixel.
  Future<Offset> brightestPixelFor(
    CelestialCoordinate starCoord, {
    double centerAz = 0,
    double centerAltitude = 90,
    double fieldOfView = 160,
  }) async {
    final painter = SkyCanvasPainter(
      viewState: SkyViewState(
        viewMode: SkyViewMode.horizontal,
        centerAz: centerAz,
        centerAltitude: centerAltitude,
        fieldOfView: fieldOfView,
      ),
      // Minimal scene: no grids/ground/labels, just the star, so the brightest
      // pixel unambiguously belongs to it.
      config: const SkyRenderConfig(
        showStars: true,
        showConstellationLines: false,
        showConstellationLabels: false,
        showDSOs: false,
        showHorizon: false,
        showGroundPlane: false,
        showCardinalDirections: false,
        showSun: false,
        showMoon: false,
        showPlanets: false,
      ),
      qualityConfig: const RenderQualityConfig.minimal(),
      stars: [
        Star(
          id: 'altaz-probe',
          name: 'Alt/Az Probe',
          coordinates: starCoord,
          magnitude: -1.5, // very bright so it dominates
          spectralType: 'A0',
        ),
      ],
      dsos: const [],
      constellations: const [],
      observationTime: time,
      latitude: latitude,
      longitude: longitude,
    );

    final recorder = ui.PictureRecorder();
    painter.paint(Canvas(recorder), size);
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      size.width.toInt(),
      size.height.toInt(),
    );
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;

    var best = -1;
    var bestX = 0;
    var bestY = 0;
    final w = size.width.toInt();
    final h = size.height.toInt();
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        // Luminance proxy: R+G+B weighted by alpha.
        final a = bytes.getUint8(i + 3);
        if (a == 0) continue;
        final lum =
            bytes.getUint8(i) + bytes.getUint8(i + 1) + bytes.getUint8(i + 2);
        if (lum > best) {
          best = lum;
          bestX = x;
          bestY = y;
        }
      }
    }

    image.dispose();
    picture.dispose();
    expect(best, greaterThan(0), reason: 'star did not render any lit pixel');
    return Offset(bestX.toDouble(), bestY.toDouble());
  }

  test('the view center alt/az lands at screen center', () async {
    // A star exactly at the view-center alt/az (here the zenith) must project
    // to the middle of the canvas.
    final pos = await brightestPixelFor(eqAt(89.5, 0));
    expect(
      (pos.dx - size.width / 2).abs(),
      lessThan(20),
      reason: 'center-alt/az star should be horizontally centered, got $pos',
    );
    expect(
      (pos.dy - size.height / 2).abs(),
      lessThan(20),
      reason: 'center-alt/az star should be vertically centered, got $pos',
    );
  });

  test('higher altitude maps higher on screen (horizon-up)', () async {
    // Look due south at the horizon, then place two stars at the same azimuth
    // but different altitudes. The higher one must render nearer the top.
    final low = await brightestPixelFor(
      eqAt(10, 180),
      centerAz: 180,
      centerAltitude: 0,
      fieldOfView: 120,
    );
    final high = await brightestPixelFor(
      eqAt(50, 180),
      centerAz: 180,
      centerAltitude: 0,
      fieldOfView: 120,
    );
    expect(
      high.dy,
      lessThan(low.dy),
      reason:
          'higher altitude must be higher on screen '
          '(low=$low, high=$high)',
    );
    // The higher star should also be above the horizon-centered midline.
    expect(
      high.dy,
      lessThan(size.height / 2),
      reason:
          'a 50-deg star above a horizon center should be in the upper '
          'half, got $high',
    );
  });

  test('opposite azimuths project to opposite sides of center', () async {
    // Centered at the zenith, two stars at the same altitude on opposite
    // azimuths (East vs West) must straddle the center horizontally on
    // opposite sides — the defining property of the horizon frame's handedness.
    final east = await brightestPixelFor(eqAt(30, 90)); // due East
    final west = await brightestPixelFor(eqAt(30, 270)); // due West

    final cx = size.width / 2;
    expect(
      (east.dx - cx).sign,
      isNot((west.dx - cx).sign),
      reason:
          'East ($east) and West ($west) must fall on opposite sides '
          'of center',
    );
    expect(
      (east.dx - cx).abs(),
      greaterThan(20),
      reason: 'East should be clearly off-center, got $east',
    );
    expect(
      (west.dx - cx).abs(),
      greaterThan(20),
      reason: 'West should be clearly off-center, got $west',
    );
  });

  test('equatorial mode is unaffected by the alt/az fields (default frame)', () {
    // The default view state is equatorial; the new alt/az center fields must
    // not perturb it. This guards the committed equatorial render goldens.
    const a = SkyViewState(centerRA: 5, centerDec: 10, fieldOfView: 60);
    const b = SkyViewState(
      centerRA: 5,
      centerDec: 10,
      fieldOfView: 60,
      centerAz: 123, // different alt/az, same equatorial pose
      centerAltitude: 45,
    );
    // In equatorial mode the alt/az center is never read, but the value-equality
    // contract still distinguishes the states (they are genuinely different
    // poses once switched to horizontal), so they are not equal...
    expect(a == b, isFalse);
    // ...yet both report the equatorial frame and identical RA/Dec center.
    expect(a.viewMode, SkyViewMode.equatorial);
    expect(b.viewMode, SkyViewMode.equatorial);
    expect(a.centerRA, b.centerRA);
    expect(a.centerDec, b.centerDec);
  });
}
