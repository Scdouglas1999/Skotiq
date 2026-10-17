// Deep-sky objects are drawn at their angular size.
//
// Without it, M31 (178' x 63') at a 2.0 degree field, NGC 7000 (120' x 30') at
// 7.2 degrees, and IC 5070 and NGC 6997 beside it are each a fixed ~6-10 px
// marker: three identical dots where a galaxy and its two companions fill the
// frame. The catalogue data is present and right — the details panel prints
// "120.0' x 30.0'" for the same object — so the planetarium cannot answer the
// one question it exists to answer: does this fit my field?
//
// A draw size of `sizeArcMin/60 * scale` clamped to a 40 px ceiling renders
// every object past ~40 px at the same size, however large it is and however
// far the view is zoomed in.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/celestial_object.dart';
import 'package:skotiq_planetarium/src/coordinate_system.dart';
import 'package:skotiq_planetarium/src/rendering/render_quality.dart';
import 'package:skotiq_planetarium/src/rendering/sky_renderer.dart';

const _size = Size(400, 400);

/// 1.0 degree x 0.33 degree, on the view centre. At the test's narrow field
/// (200 px per degree) that is 200 px long and ~67 px wide — an extent, not a
/// marker.
const _extendedDso = DeepSkyObject(
  id: 'test-dso',
  name: 'NGC 0000',
  coordinates: CelestialCoordinate(ra: 0, dec: 0),
  type: DsoType.galaxy,
  magnitude: 8.0,
  sizeArcMin: 60,
  minorAxisArcMin: 20,
);

/// Deep sky only, and no labels: label ink would widen the measured extent and
/// hide the very thing under test.
const _dsoOnlyConfig = SkyRenderConfig(
  showStars: false,
  showConstellationLines: false,
  showConstellationLabels: false,
  showDSOLabels: false,
  showHorizon: false,
  showCardinalDirections: false,
  showMountPosition: false,
  showSun: false,
  showMoon: false,
  showPlanets: false,
  showGroundPlane: false,
);

SkyCanvasPainter _painter({
  required List<DeepSkyObject> dsos,
  required double fieldOfView,
}) => SkyCanvasPainter(
  viewState: SkyViewState(centerRA: 0, centerDec: 0, fieldOfView: fieldOfView),
  config: _dsoOnlyConfig,
  qualityConfig: const RenderQualityConfig.balanced(),
  stars: const [],
  dsos: dsos,
  constellations: const [],
  observationTime: DateTime.utc(2026, 3, 21, 2),
  latitude: 40,
  longitude: -75,
  dsoPopinAnimationPhase: 1.0,
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

/// Bounding box of the pixels the deep-sky pass added, in canvas pixels.
Future<Rect> _inkExtent(double fieldOfView) async {
  final withDso = await _rasterise(
    _painter(dsos: const [_extendedDso], fieldOfView: fieldOfView),
  );
  final without = await _rasterise(
    _painter(dsos: const [], fieldOfView: fieldOfView),
  );

  final width = _size.width.toInt();
  final height = _size.height.toInt();
  var left = width.toDouble();
  var top = height.toDouble();
  var right = 0.0;
  var bottom = 0.0;
  var any = false;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      if (withDso.getUint32(i) == without.getUint32(i)) continue;
      any = true;
      if (x < left) left = x.toDouble();
      if (x > right) right = x.toDouble();
      if (y < top) top = y.toDouble();
      if (y > bottom) bottom = y.toDouble();
    }
  }
  expect(any, isTrue, reason: 'the deep-sky pass drew nothing at all');
  return Rect.fromLTRB(left, top, right + 1, bottom + 1);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an extended object is drawn at its catalogued angular size', () async {
    // 400 px across 2 degrees = 200 px per degree; the object is 1 degree long.
    final ink = await _inkExtent(2.0);

    expect(
      ink.height,
      greaterThan(150),
      reason: 'a 1 degree object in a 2 degree field must fill half the frame',
    );
    expect(
      ink.width,
      lessThan(ink.height * 0.6),
      reason: 'the 3:1 catalogued axis ratio must survive to the canvas',
    );
  });

  test('zooming in grows the object with the field', () async {
    // 20 px per degree: the same object is 20 px long and reads as a marker.
    final wide = await _inkExtent(20.0);
    final narrow = await _inkExtent(2.0);

    expect(wide.height, lessThan(50));
    expect(
      narrow.height,
      greaterThan(wide.height * 5),
      reason: 'a 10x zoom that does not grow the object is the 40 px ceiling',
    );
  });
}
