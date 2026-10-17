// The ground plane / horizon layers.
//
// Two contracts live here, one per view frame.
//
// HORIZONTAL — "the sky from where I stand". The ground is real terrain and
// must actually appear when the view is pointed at it.
// [AstronomyCalculations.equatorialToHorizontal] returns (alt, az), so
// destructuring it as `(_, centerAlt)` binds the AZIMUTH into the altitude
// slot: because azimuth is always in [0, 360) the computed horizon line sits
// below the canvas for almost every pose and a view pointed straight at the
// ground renders as clean sky.
//
// EQUATORIAL — a star atlas. It paints NO ground fill, and its background must
// not depend on which way the view is pointed. The ground fill is a horizontal
// screen band whose Y comes from the view centre's altitude, which only
// describes the horizon where screen-up is altitude; drawn in this frame it has
// three completely different whole-screen regimes (no fill / a gradient band /
// the entire canvas flooded with opaque ground once the centre drops below the
// horizon), so panning or rotating flips the sky between a night-sky gradient
// and flat brown-black. Composing a session around a target that has not risen
// yet is a first-class use of this frame, so the chart also has to stay legible
// whichever way it points.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/astronomy/astronomy_calculations.dart';
import 'package:skotiq_planetarium/src/rendering/render_quality.dart';
import 'package:skotiq_planetarium/src/rendering/sky_renderer.dart';

const _canvasSize = Size(240, 180);
final _time = DateTime.utc(2026, 3, 21, 2);
const _latitude = 40.0;
const _longitude = -75.0;
const _ground = Color(0xFF0A0805);

Future<ByteData> _raster(SkyViewState viewState) async {
  final painter = SkyCanvasPainter(
    viewState: viewState,
    // Anything that moves with the pose and is not background would masquerade
    // as a background change: the Sun and Moon are pinned at RA 0 / Dec 0 by
    // the stub positions below, and the cardinal markers sit at fixed azimuths
    // and so cross the sampled pixels as the view swings.
    config: const SkyRenderConfig(
      showSun: false,
      showMoon: false,
      showCardinalDirections: false,
    ),
    qualityConfig: const RenderQualityConfig.balanced(),
    stars: const [],
    dsos: const [],
    constellations: const [],
    observationTime: _time,
    latitude: _latitude,
    longitude: _longitude,
    selectedObject: null,
    mountPosition: null,
    mountStatus: MountRenderStatus.disconnected,
    sunPosition: const (0, 0),
    moonPosition: const (0, 0, 0),
    planets: const [],
  );

  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), _canvasSize);
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    _canvasSize.width.toInt(),
    _canvasSize.height.toInt(),
  );
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  picture.dispose();
  return bytes!;
}

/// The equatorial pose that looks at the given alt/az right now.
SkyViewState _equatorialPose({
  required double altDeg,
  required double azDeg,
  double rotation = 0,
}) {
  final lst = AstronomyCalculations.localSiderealTime(_time, _longitude);
  final (raDeg, decDeg) = AstronomyCalculations.horizontalToEquatorial(
    altDeg: altDeg,
    azDeg: azDeg,
    latitudeDeg: _latitude,
    lstHours: lst,
  );
  return SkyViewState(
    centerRA: raDeg / 15,
    centerDec: decDeg,
    fieldOfView: 60,
    rotation: rotation,
  );
}

/// Fraction of pixels in the bottom quarter of the raster that are the dark
/// ground colour (the ground plane paints over the sky gradient).
Future<double> _groundFraction(SkyViewState viewState) async {
  final bytes = await _raster(viewState);
  final width = _canvasSize.width.toInt();
  final height = _canvasSize.height.toInt();
  final firstRow = (height * 0.75).toInt();
  var matched = 0;
  var total = 0;
  for (var y = firstRow; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      final r = bytes.getUint8(i);
      final g = bytes.getUint8(i + 1);
      final b = bytes.getUint8(i + 2);
      total++;
      if ((r - (_ground.r * 255)).abs() <= 6 &&
          (g - (_ground.g * 255)).abs() <= 6 &&
          (b - (_ground.b * 255)).abs() <= 6) {
        matched++;
      }
    }
  }
  return matched / total;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('horizontal frame', () {
    SkyViewState pose(double altDeg, double azDeg) => SkyViewState(
      viewMode: SkyViewMode.horizontal,
      centerAltitude: altDeg,
      centerAz: azDeg,
      fieldOfView: 60,
    );

    test('a view centred below the horizon renders ground', () async {
      for (final az in const [0.0, 90.0, 180.0, 310.0]) {
        expect(
          await _groundFraction(pose(-40, az)),
          greaterThan(0.9),
          reason: 'ground missing for a below-horizon view at azimuth $az',
        );
      }
    });

    test('a view centred at the zenith renders no ground', () async {
      for (final az in const [0.0, 180.0, 310.0]) {
        expect(
          await _groundFraction(pose(85, az)),
          lessThan(0.05),
          reason: 'ground wrongly drawn for a zenith view at azimuth $az',
        );
      }
    });
  });

  group('equatorial frame', () {
    test('a below-horizon view is not flooded with ground', () async {
      for (final az in const [0.0, 90.0, 180.0, 310.0]) {
        expect(
          await _groundFraction(_equatorialPose(altDeg: -40, azDeg: az)),
          lessThan(0.05),
          reason:
              'the star atlas was covered in ground colour looking at azimuth '
              '$az — a target that has not risen must still be chartable',
        );
      }
    });

    test('the background does not change with view direction', () async {
      // Sampled where no chart content can land: the four corners and the
      // canvas centre are all background in an empty catalogue.
      const probes = [
        Offset(3, 3),
        Offset(236, 3),
        Offset(3, 176),
        Offset(236, 176),
        Offset(120, 90),
      ];
      List<int> sample(ByteData bytes) => [
        for (final p in probes)
          bytes.getUint32(
            ((p.dy.toInt() * _canvasSize.width.toInt()) + p.dx.toInt()) * 4,
          ),
      ];

      final reference = sample(
        await _raster(_equatorialPose(altDeg: 60, azDeg: 0)),
      );

      for (final alt in const [85.0, 20.0, 0.0, -20.0, -85.0]) {
        for (final az in const [0.0, 90.0, 180.0, 270.0]) {
          expect(
            sample(await _raster(_equatorialPose(altDeg: alt, azDeg: az))),
            reference,
            reason: 'the sky background shifted at altitude $alt, azimuth $az',
          );
        }
      }

      for (final rotation in const [45.0, 90.0, 180.0, 270.0]) {
        expect(
          sample(
            await _raster(
              _equatorialPose(altDeg: 60, azDeg: 0, rotation: rotation),
            ),
          ),
          reference,
          reason: 'the sky background shifted when rotated to $rotation deg',
        );
      }
    });
  });
}
