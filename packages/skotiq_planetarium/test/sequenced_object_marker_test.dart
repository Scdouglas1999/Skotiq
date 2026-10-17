import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/celestial_object.dart';
import 'package:skotiq_planetarium/src/coordinate_system.dart';
import 'package:skotiq_planetarium/src/rendering/render_quality.dart';
import 'package:skotiq_planetarium/src/rendering/sky_renderer.dart';

/// The sky shows which objects are targets of tonight's sequence, using the
/// same marker mechanism as observed / observing-list objects.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const canvasSize = Size(320, 240);
  const target = CelestialCoordinate(ra: 5, dec: 0);

  const dso = DeepSkyObject(
    id: 'NGC1976',
    name: 'NGC1976',
    coordinates: target,
    magnitude: 4.0,
    type: DsoType.nebula,
    sizeArcMin: 30,
    minorAxisArcMin: 30,
  );

  // One shared list instance: the painter treats a NEW catalog list as new
  // data (identity compare), which would mask what shouldRepaint is asserting.
  const dsos = <DeepSkyObject>[dso];

  SkyCanvasPainter painterWith(Set<String> sequencedIds) => SkyCanvasPainter(
    viewState: const SkyViewState(centerRA: 5, centerDec: 0, fieldOfView: 5),
    config: const SkyRenderConfig(
      showStars: false,
      showConstellationLines: false,
      showConstellationLabels: false,
      showMilkyWay: false,
      showGroundPlane: false,
      showHorizon: false,
      showCoordinateGrid: false,
      showSun: false,
      showMoon: false,
      showPlanets: false,
      showCardinalDirections: false,
    ),
    qualityConfig: const RenderQualityConfig.balanced(),
    stars: const [],
    dsos: dsos,
    constellations: const [],
    observationTime: DateTime.utc(2026, 1, 15, 6),
    latitude: 40,
    longitude: -75,
    sequencedObjectIds: sequencedIds,
  );

  Future<int> cyanPixelCount(Set<String> sequencedIds) async {
    final recorder = ui.PictureRecorder();
    painterWith(sequencedIds).paint(Canvas(recorder), canvasSize);
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      canvasSize.width.toInt(),
      canvasSize.height.toInt(),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    picture.dispose();

    // The marker is 0xFF4DD0E1 — strongly cyan: blue and green high, red low.
    var count = 0;
    for (var i = 0; i < bytes!.lengthInBytes; i += 4) {
      final r = bytes.getUint8(i);
      final g = bytes.getUint8(i + 1);
      final b = bytes.getUint8(i + 2);
      if (b > 120 && g > 110 && r < g - 40 && r < b - 40) count++;
    }
    return count;
  }

  test('a sequenced DSO gets a marker', () async {
    expect(await cyanPixelCount({'NGC1976'}), greaterThan(0));
  });

  test('an unsequenced DSO gets no marker', () async {
    expect(await cyanPixelCount(const {}), 0);
  });

  test('a non-matching id does not mark', () async {
    // Matching is over the object's OWN designations (id, name, Messier number,
    // NGC/IC). Cross-catalogue aliasing (M42 <-> NGC1976) is resolved on the
    // sequence side, by the provider that builds the id set, not here.
    expect(await cyanPixelCount({'M31'}), 0);
    expect(await cyanPixelCount({'M42'}), 0);
  });

  test('shouldRepaint fires when the sequence target set changes', () {
    expect(painterWith({'M42'}).shouldRepaint(painterWith(const {})), isTrue);
    expect(painterWith({'M42'}).shouldRepaint(painterWith({'M42'})), isFalse);
  });
}
