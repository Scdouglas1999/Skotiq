import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/astronomy/astronomy_calculations.dart';
import 'package:skotiq_planetarium/src/catalogs/variable_star_catalog.dart';
import 'package:skotiq_planetarium/src/coordinate_system.dart';
import 'package:skotiq_planetarium/src/rendering/fov_overlays.dart';
import 'package:skotiq_planetarium/src/rendering/render_quality.dart';
import 'package:skotiq_planetarium/src/rendering/sky_renderer.dart';
import 'package:skotiq_planetarium/src/widgets/interactive_sky_view.dart';

/// Pins the equipment FOV overlays to the star field.
///
/// An FOV box is how an imager sees where their sensor lands on the sky, so it
/// has exactly one job: agree with the stars. These tests assert that
/// [SkyFovProjector] — the projector every FOV overlay places its footprint
/// with — lands on the *same pixel* [SkyCanvasPainter] draws a catalog object
/// at, across every projection, view rotation, view frame and RA seam. If the
/// two ever drift apart again, this file fails.
///
/// The sky painter's own projection is private, so its output is read the only
/// honest way: render the real painter and observe where it actually draws. A
/// single variable star is the probe because `_drawVariableStars` emits a
/// `drawCircle` at the raw projected offset (no rounding, no glyph atlas), so
/// the comparison is exact rather than raster-quantised.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const size = Size(400, 400);
  final time = DateTime.utc(2026, 3, 14, 22, 0, 0);
  const latitude = 40.0;
  const longitude = -75.0;
  final lst = AstronomyCalculations.localSiderealTime(time, longitude);

  /// The probe star's outer marker radius is a pure function of its magMax:
  /// `5.0 + (8.0 - magMax).clamp(0, 4)`. magMax 6.0 gives 7.0, which no other
  /// circle the marker draws can collide with (the inner disc is at most 0.8x
  /// the outer, the second ring is outer + 2.5).
  const probeMagMax = 6.0;
  const probeOuterRadius = 7.0;

  VariableStarData probe(CelestialCoordinate coord) => VariableStarData(
    name: 'FOV probe',
    constellation: 'Xxx',
    ra: coord.ra,
    dec: coord.dec,
    type: VariableStarType.semiRegular,
    magMax: probeMagMax,
    magMin: 8.0,
  );

  /// Everything off except the variable-star pass, so the only markers on the
  /// canvas belong to the probe.
  const probeOnlyConfig = SkyRenderConfig(
    showStars: false,
    showConstellationLines: false,
    showConstellationLabels: false,
    showConstellationBoundaries: false,
    showDSOs: false,
    showDSOLabels: false,
    showCoordinateGrid: false,
    showAltAzGrid: false,
    showEquatorialGrid: false,
    showEcliptic: false,
    showGalacticPlane: false,
    showHorizon: false,
    showCardinalDirections: false,
    showMilkyWay: false,
    showMountPosition: false,
    showSun: false,
    showMoon: false,
    showPlanets: false,
    showGroundPlane: false,
    showMeridian: false,
    showSatellites: false,
    showVariableStars: true,
    showMinorPlanets: false,
    showConstellationArt: false,
  );

  /// Where [SkyCanvasPainter] actually draws [coord] at [viewState].
  /// Null when the painter culls it (behind the viewer or off-canvas).
  Offset? skyPainterOffset(CelestialCoordinate coord, SkyViewState viewState) {
    final canvas = _CircleRecordingCanvas();
    SkyCanvasPainter(
      viewState: viewState,
      config: probeOnlyConfig,
      qualityConfig: const RenderQualityConfig.minimal(),
      stars: const [],
      dsos: const [],
      constellations: const [],
      observationTime: time,
      latitude: latitude,
      longitude: longitude,
      variableStars: [probe(coord)],
    ).paint(canvas, size);

    final markers = canvas.circles
        .where((c) => (c.radius - probeOuterRadius).abs() < 1e-9)
        .toList();
    if (markers.isEmpty) return null;
    expect(
      markers,
      hasLength(1),
      reason: 'the probe marker must be unambiguous',
    );
    return markers.single.center;
  }

  SkyFovProjector projectorFor(SkyViewState viewState) =>
      SkyFovProjector.forSize(
        viewState,
        size,
        latitude: latitude,
        lstHours: lst,
      );

  group('SkyFovProjector agrees with the sky painter', () {
    // A pose grid covering every branch the projector has: all three
    // projections, rotated and unrotated views, a high-declination center
    // where cos(dec) matters most, the 0h/24h seam, and the alt/az frame.
    final poses = <String, SkyViewState>{
      'stereographic, unrotated': const SkyViewState(
        centerRA: 5,
        centerDec: 20,
        fieldOfView: 20,
      ),
      'stereographic, rotated 37°': const SkyViewState(
        centerRA: 5,
        centerDec: 20,
        fieldOfView: 20,
        rotation: 37,
      ),
      'stereographic, rotated -114°': const SkyViewState(
        centerRA: 5,
        centerDec: 20,
        fieldOfView: 20,
        rotation: -114,
      ),
      'orthographic': const SkyViewState(
        centerRA: 5,
        centerDec: 20,
        fieldOfView: 20,
        projection: SkyProjection.orthographic,
      ),
      'azimuthal equidistant, rotated': const SkyViewState(
        centerRA: 5,
        centerDec: 20,
        fieldOfView: 20,
        rotation: 22,
        projection: SkyProjection.azimuthalEquidistant,
      ),
      'high declination': const SkyViewState(
        centerRA: 5,
        centerDec: 78,
        fieldOfView: 20,
      ),
      'across the 0h/24h seam': const SkyViewState(
        centerRA: 23.9,
        centerDec: 20,
        fieldOfView: 20,
      ),
      'wide field': const SkyViewState(
        centerRA: 5,
        centerDec: 20,
        fieldOfView: 90,
      ),
      'horizontal frame': const SkyViewState(
        centerRA: 5,
        centerDec: 20,
        fieldOfView: 30,
        viewMode: SkyViewMode.horizontal,
        centerAz: 140,
        centerAltitude: 45,
      ),
      'horizontal frame, rotated': const SkyViewState(
        centerRA: 5,
        centerDec: 20,
        fieldOfView: 30,
        rotation: 63,
        viewMode: SkyViewMode.horizontal,
        centerAz: 140,
        centerAltitude: 45,
      ),
    };

    poses.forEach((name, viewState) {
      test('$name — every sample point lands on the same pixel', () {
        // Sample points spread around the view center. For the horizontal
        // poses the center is an alt/az point, so the samples are taken about
        // the equatorial coordinate that currently sits there.
        late final CelestialCoordinate anchor;
        if (viewState.viewMode == SkyViewMode.horizontal) {
          final (ra, dec) = AstronomyCalculations.horizontalToEquatorial(
            altDeg: viewState.centerAltitude,
            azDeg: viewState.centerAz,
            latitudeDeg: latitude,
            lstHours: lst,
          );
          anchor = CelestialCoordinate(ra: ra / 15, dec: dec);
        } else {
          anchor = CelestialCoordinate(
            ra: viewState.centerRA,
            dec: viewState.centerDec,
          );
        }

        final projector = projectorFor(viewState);
        var compared = 0;

        for (final decOffset in const [-3.0, -1.0, 0.0, 1.5, 4.0]) {
          for (final raOffsetDeg in const [-6.0, -2.0, 0.0, 2.0, 5.0]) {
            final dec = (anchor.dec + decOffset).clamp(-89.9, 89.9);
            // Keep the on-sky separation roughly constant with declination so
            // the samples stay inside the canvas near the pole.
            final cosDec = math.cos(dec * math.pi / 180).abs();
            final raHours =
                anchor.ra + (raOffsetDeg / 15) / cosDec.clamp(0.05, 1.0);
            final coord = CelestialCoordinate(ra: raHours, dec: dec);

            final expected = skyPainterOffset(coord, viewState);
            final actual = projector.project(coord);
            if (expected == null) continue; // culled by the painter

            expect(
              actual,
              isNotNull,
              reason: 'painter drew $coord but the projector refused it',
            );
            expect(
              actual!.dx,
              closeTo(expected.dx, 1e-9),
              reason: 'x mismatch for $coord in "$name"',
            );
            expect(
              actual.dy,
              closeTo(expected.dy, 1e-9),
              reason: 'y mismatch for $coord in "$name"',
            );
            compared++;
          }
        }

        expect(
          compared,
          greaterThanOrEqualTo(9),
          reason: 'the pose must actually exercise the comparison',
        );
      });
    });
  });

  group('RA sign convention', () {
    const viewState = SkyViewState(centerRA: 5, centerDec: 20, fieldOfView: 20);

    test('a target 2° EAST of center draws LEFT of center, like the stars', () {
      // Increasing RA runs to the left across the sky view. The overlay used to
      // add the RA offset to dx, mirroring the box about the view center: a
      // target 2° east drew 2° west.
      final target = CelestialCoordinate(
        ra: 5 + (2.0 / math.cos(20 * math.pi / 180)) / 15,
        dec: 20,
      );
      final projector = SkyFovProjector.forSize(viewState, size);
      final placed = projector.project(target)!;

      expect(placed.dx, lessThan(projector.screenCenter.dx));
      // ~2 degrees of sky at 20 px/deg.
      expect(projector.screenCenter.dx - placed.dx, closeTo(40, 1.0));
      // And it is where the painter actually draws that coordinate.
      expect(placed.dx, closeTo(skyPainterOffset(target, viewState)!.dx, 1e-9));
    });

    test('a target 2° WEST of center draws RIGHT of center', () {
      final target = CelestialCoordinate(
        ra: 5 - (2.0 / math.cos(20 * math.pi / 180)) / 15,
        dec: 20,
      );
      final projector = SkyFovProjector.forSize(viewState, size);
      final placed = projector.project(target)!;
      expect(placed.dx, greaterThan(projector.screenCenter.dx));
    });

    test('a target north of center draws above it', () {
      const target = CelestialCoordinate(ra: 5, dec: 22);
      final projector = SkyFovProjector.forSize(viewState, size);
      final placed = projector.project(target)!;
      expect(placed.dy, lessThan(projector.screenCenter.dy));
    });
  });

  group('0h/24h seam', () {
    // M31 sits at RA 0.71h: the seam case for a view parked just below 24h.
    const viewState = SkyViewState(
      centerRA: 23.9,
      centerDec: 20,
      fieldOfView: 20,
    );

    test('a target at RA 0.2h with the view at RA 23.9h stays on canvas', () {
      const target = CelestialCoordinate(ra: 0.2, dec: 20);
      final projector = SkyFovProjector.forSize(viewState, size);
      final placed = projector.project(target)!;

      // 0.3h = 4.5 deg of RA, foreshortened by cos(20 deg) => ~4.23 deg east,
      // i.e. ~85 px to the LEFT at 20 px/deg. A flat RA difference reads
      // -23.7h here and puts the box thousands of pixels off the right edge.
      expect(placed.dx, lessThan(projector.screenCenter.dx));
      expect(projector.screenCenter.dx - placed.dx, closeTo(85, 3.0));
      expect(placed.dx, inInclusiveRange(0, size.width));
      expect(placed.dy, inInclusiveRange(0, size.height));
      expect(placed.dx, closeTo(skyPainterOffset(target, viewState)!.dx, 1e-9));
    });

    test('the seam is symmetric — 23.6h and 0.2h straddle the center', () {
      final projector = SkyFovProjector.forSize(viewState, size);
      final east = projector.project(
        const CelestialCoordinate(ra: 0.2, dec: 20),
      )!;
      final west = projector.project(
        const CelestialCoordinate(ra: 23.6, dec: 20),
      )!;
      final center = projector.screenCenter.dx;
      expect(center - east.dx, closeTo(west.dx - center, 0.5));
    });

    test('normalizeRaDeltaHours wraps into (-12, +12]', () {
      expect(
        SkyFovProjector.normalizeRaDeltaHours(0.2 - 23.9),
        closeTo(0.3, 1e-9),
      );
      expect(
        SkyFovProjector.normalizeRaDeltaHours(23.9 - 0.2),
        closeTo(-0.3, 1e-9),
      );
      expect(SkyFovProjector.normalizeRaDeltaHours(0), 0);
      expect(SkyFovProjector.normalizeRaDeltaHours(11.5), closeTo(11.5, 1e-9));
      expect(SkyFovProjector.normalizeRaDeltaHours(-13), closeTo(11, 1e-9));
      // The interval is half-open at +12, so an exact half turn stays +12.
      expect(SkyFovProjector.normalizeRaDeltaHours(36), closeTo(12, 1e-9));
      expect(SkyFovProjector.normalizeRaDeltaHours(-36), closeTo(12, 1e-9));
    });
  });

  group('guards', () {
    const viewState = SkyViewState(centerRA: 5, centerDec: 20, fieldOfView: 20);

    test('a target behind the viewer projects to null', () {
      final projector = SkyFovProjector.forSize(viewState, size);
      // Antipodal to the view center.
      expect(
        projector.project(const CelestialCoordinate(ra: 17, dec: -20)),
        isNull,
      );
    });

    test('NaN coordinates project to null rather than garbage', () {
      final projector = SkyFovProjector.forSize(viewState, size);
      expect(
        projector.project(const CelestialCoordinate(ra: double.nan, dec: 20)),
        isNull,
      );
      expect(
        projector.project(
          const CelestialCoordinate(ra: 5, dec: double.infinity),
        ),
        isNull,
      );
    });

    test('the horizontal frame refuses RA/Dec without a sidereal time', () {
      const horizontal = SkyViewState(
        fieldOfView: 30,
        viewMode: SkyViewMode.horizontal,
        centerAz: 140,
        centerAltitude: 45,
      );
      final blind = SkyFovProjector.forSize(horizontal, size);
      expect(blind.canProjectSkyCoordinates, isFalse);
      expect(blind.project(const CelestialCoordinate(ra: 5, dec: 20)), isNull);

      final informed = SkyFovProjector.forSize(
        horizontal,
        size,
        latitude: latitude,
        lstHours: lst,
      );
      expect(informed.canProjectSkyCoordinates, isTrue);
    });

    test('a degenerate canvas projects to null', () {
      final degenerate = SkyFovProjector.forSize(viewState, Size.zero);
      expect(
        degenerate.project(const CelestialCoordinate(ra: 5, dec: 20)),
        isNull,
      );
    });
  });

  group('inverse projection', () {
    final poses = <String, SkyViewState>{
      'stereographic': const SkyViewState(
        centerRA: 5,
        centerDec: 20,
        fieldOfView: 20,
      ),
      'stereographic, rotated': const SkyViewState(
        centerRA: 5,
        centerDec: 20,
        fieldOfView: 20,
        rotation: -47,
      ),
      'orthographic': const SkyViewState(
        centerRA: 5,
        centerDec: 20,
        fieldOfView: 20,
        projection: SkyProjection.orthographic,
      ),
      'azimuthal equidistant': const SkyViewState(
        centerRA: 5,
        centerDec: 20,
        fieldOfView: 20,
        projection: SkyProjection.azimuthalEquidistant,
      ),
      'seam': const SkyViewState(
        centerRA: 23.9,
        centerDec: 20,
        fieldOfView: 20,
      ),
      'horizontal': const SkyViewState(
        fieldOfView: 30,
        viewMode: SkyViewMode.horizontal,
        centerAz: 140,
        centerAltitude: 45,
      ),
    };

    poses.forEach((name, viewState) {
      test('$name — unproject(project(c)) round-trips', () {
        final projector = projectorFor(viewState);
        final anchor = projector.unproject(projector.screenCenter)!;

        for (final d in const [
          Offset(0, 0),
          Offset(60, -35),
          Offset(-80, 20),
          Offset(15, 90),
        ]) {
          final point = projector.screenCenter + d;
          final coord = projector.unproject(point);
          expect(coord, isNotNull, reason: 'unproject failed at $d in "$name"');
          final back = projector.project(coord!);
          expect(back, isNotNull);
          expect(back!.dx, closeTo(point.dx, 1e-6), reason: '$name at $d');
          expect(back.dy, closeTo(point.dy, 1e-6), reason: '$name at $d');
        }

        // The view center unprojects to the coordinate the view is centered on.
        expect(projector.project(anchor)!.dx, closeTo(size.width / 2, 1e-6));
      });
    });

    test('RA is normalised into [0, 24) across the seam', () {
      const viewState = SkyViewState(
        centerRA: 23.9,
        centerDec: 20,
        fieldOfView: 20,
      );
      final projector = SkyFovProjector.forSize(viewState, size);
      // Well to the left of center => increasing RA => past 24h.
      final coord = projector.unproject(
        projector.screenCenter - const Offset(120, 0),
      )!;
      expect(coord.ra, inInclusiveRange(0, 24));
      expect(coord.ra, lessThan(12));
    });
  });

  group('north angle', () {
    test('at the view center it is exactly the view rotation', () {
      const viewState = SkyViewState(
        centerRA: 5,
        centerDec: 20,
        fieldOfView: 20,
        rotation: 31,
      );
      final projector = SkyFovProjector.forSize(viewState, size);
      final angle = projector.northAngleAt(
        const CelestialCoordinate(ra: 5, dec: 20),
      );
      expect(angle, isNotNull);
      expect(angle! * 180 / math.pi, closeTo(31, 1e-3));
    });

    test('it tilts away from screen-up for an off-center target', () {
      // Near the pole the meridians fan out, so celestial north at a target
      // well off-axis is visibly not straight up.
      const viewState = SkyViewState(
        centerRA: 5,
        centerDec: 80,
        fieldOfView: 40,
      );
      final projector = SkyFovProjector.forSize(viewState, size);
      final angle = projector.northAngleAt(
        const CelestialCoordinate(ra: 8, dec: 78),
      );
      expect(angle, isNotNull);
      expect(angle!.abs() * 180 / math.pi, greaterThan(5));
    });
  });

  group('FOVOverlayPainter (public rendering API)', () {
    const viewState = SkyViewState(centerRA: 5, centerDec: 20, fieldOfView: 20);
    // A target 2 degrees east of the view center.
    final target = CelestialCoordinate(
      ra: 5 + (2.0 / math.cos(20 * math.pi / 180)) / 15,
      dec: 20,
    );

    /// The Telrad glyph's 3px center dot marks the indicator center exactly.
    Offset telradCenter(FOVOverlayPainter painter) {
      final canvas = _CircleRecordingCanvas();
      painter.paint(canvas, size);
      final dots = canvas.circles
          .where((c) => (c.radius - 3.0).abs() < 1e-9)
          .toList();
      expect(dots, hasLength(1));
      return dots.single.center;
    }

    test('places its indicators where the sky painter draws the target', () {
      final painter = FOVOverlayPainter(
        centerRA: viewState.centerRA,
        centerDec: viewState.centerDec,
        viewFOV: viewState.fieldOfView,
        indicators: const [
          FOVIndicator(
            type: FOVType.telradCircles,
            widthDegrees: 4,
            heightDegrees: 4,
          ),
        ],
        indicatorCenter: target,
      );

      final expected = SkyFovProjector.forSize(
        viewState,
        size,
      ).project(target)!;
      final actual = telradCenter(painter);
      expect(actual.dx, closeTo(expected.dx, 1e-9));
      expect(actual.dy, closeTo(expected.dy, 1e-9));
      // East draws LEFT of center; flat RA arithmetic mirrors it.
      expect(actual.dx, lessThan(size.width / 2));
    });

    test('an indicator near the 0h seam stays on canvas', () {
      const seamView = SkyViewState(
        centerRA: 23.9,
        centerDec: 20,
        fieldOfView: 20,
      );
      final painter = FOVOverlayPainter(
        centerRA: seamView.centerRA,
        centerDec: seamView.centerDec,
        viewFOV: seamView.fieldOfView,
        indicators: const [
          FOVIndicator(
            type: FOVType.telradCircles,
            widthDegrees: 4,
            heightDegrees: 4,
          ),
        ],
        indicatorCenter: const CelestialCoordinate(ra: 0.2, dec: 20),
      );
      final actual = telradCenter(painter);
      expect(actual.dx, inInclusiveRange(0, size.width));
      expect(actual.dy, inInclusiveRange(0, size.height));
    });

    test(
      'an unpinned overlay is centered on the view (unchanged behaviour)',
      () {
        final painter = FOVOverlayPainter(
          centerRA: viewState.centerRA,
          centerDec: viewState.centerDec,
          viewFOV: viewState.fieldOfView,
          indicators: const [
            FOVIndicator(
              type: FOVType.telradCircles,
              widthDegrees: 4,
              heightDegrees: 4,
            ),
          ],
        );
        expect(telradCenter(painter), const Offset(200, 200));
      },
    );

    test('a target behind the viewer draws nothing', () {
      final painter = FOVOverlayPainter(
        centerRA: viewState.centerRA,
        centerDec: viewState.centerDec,
        viewFOV: viewState.fieldOfView,
        indicators: const [
          FOVIndicator(
            type: FOVType.telradCircles,
            widthDegrees: 4,
            heightDegrees: 4,
          ),
        ],
        indicatorCenter: const CelestialCoordinate(ra: 17, dec: -20),
      );
      final canvas = _CircleRecordingCanvas();
      painter.paint(canvas, size);
      expect(canvas.circles, isEmpty);
    });
  });
}

/// A [Canvas] that records the circles drawn on it and swallows everything
/// else, so a painter's exact geometry can be read back without rasterising.
class _CircleRecordingCanvas implements Canvas {
  final List<({Offset center, double radius})> circles = [];

  @override
  void drawCircle(Offset c, double radius, Paint paint) {
    circles.add((center: c, radius: radius));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
