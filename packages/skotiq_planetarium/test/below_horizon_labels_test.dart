// Nothing behind the observer's own ground gets named.
//
// Alt/Az view looking az 134 / alt -12 with the ground plane and horizon layers
// on draws 'Fomalhaut' as a bright labelled star in the middle of the ground
// gradient (its true altitude there is -11.5 deg), with 'Alnair', 'Peacock',
// 'GRUS', 'INDUS', 'SCULPTOR', 'TUCANA' and 'PHOENIX' all over the ground. At
// midday the same view shows 'CRUX', 'Acrux', 'Mimosa', 'Gacrux', 'CENTAURUS'
// and 'MUSCA' — objects never visible from 40N at all.
//
// The ground fill is painted after the sky objects in the horizontal frame, so
// the star DOTS are occluded; the label passes run after the ground, so without
// this gate their text prints on top of the terrain. A named object on the
// ground reads as an observable target, which is the single most misleading
// thing a planning map can say.
//
// The equatorial frame paints no terrain, so nothing is occluded there and its
// labels stay untouched (this also keeps the committed equatorial render
// goldens unchanged).
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/astronomy/astronomy_calculations.dart';
import 'package:skotiq_planetarium/src/celestial_object.dart';
import 'package:skotiq_planetarium/src/catalogs/constellation_data.dart';
import 'package:skotiq_planetarium/src/coordinate_system.dart';
import 'package:skotiq_planetarium/src/rendering/render_quality.dart';
import 'package:skotiq_planetarium/src/rendering/sky_renderer.dart';

const _canvasSize = Size(400, 300);
final _time = DateTime.utc(2026, 3, 21, 2);
const _latitude = 40.0;
const _longitude = -75.0;

/// Where the view is pointed: 12 deg BELOW the horizon, as audited.
const _viewAlt = -12.0;
const _viewAz = 134.0;

double get _lst => AstronomyCalculations.localSiderealTime(_time, _longitude);

/// A catalog object placed at the given alt/az for [_time] and the test site.
CelestialCoordinate _at({required double altDeg, required double azDeg}) {
  final (raDeg, decDeg) = AstronomyCalculations.horizontalToEquatorial(
    altDeg: altDeg,
    azDeg: azDeg,
    latitudeDeg: _latitude,
    lstHours: _lst,
  );
  return CelestialCoordinate(ra: raDeg / 15, dec: decDeg);
}

/// Bright enough that the label passes always consider it (mag < 2.0).
Star _star(String name, CelestialCoordinate coords) =>
    Star(id: name, name: name, coordinates: coords, magnitude: 1.2);

DeepSkyObject _dso(String name, CelestialCoordinate coords) => DeepSkyObject(
  id: name,
  name: name,
  coordinates: coords,
  type: DsoType.galaxy,
  magnitude: 6.0,
);

ConstellationData _constellation(String name, CelestialCoordinate coords) =>
    ConstellationData(
      name: name,
      abbreviation: name.substring(0, 3),
      center: coords,
      lines: const [],
    );

/// Renders and returns the count of non-background pixels in the raster.
///
/// Labels are the only text on an otherwise empty sky, so "did the label get
/// drawn" reduces to "did the ink count go up".
Future<int> _inkPixels({
  required SkyViewMode mode,
  required bool showGroundPlane,
  List<Star> stars = const [],
  List<DeepSkyObject> dsos = const [],
  List<ConstellationData> constellations = const [],
  SkyRenderScope scope = SkyRenderScope.full,
}) async {
  final painter = SkyCanvasPainter(
    renderScope: scope,
    // Twinkle is what activates the two-CustomPaint split on desktop, and the
    // bright pass needs a phase to run.
    animationPhase: 0.25,
    viewState: SkyViewState(
      viewMode: mode,
      centerAltitude: _viewAlt,
      centerAz: _viewAz,
      // The equatorial pose that looks at the same patch of sky, so both frames
      // are compared pointing the same way.
      centerRA: _at(altDeg: _viewAlt, azDeg: _viewAz).ra,
      centerDec: _at(altDeg: _viewAlt, azDeg: _viewAz).dec,
      fieldOfView: 60,
    ),
    config: SkyRenderConfig(
      showSun: false,
      showMoon: false,
      showCardinalDirections: false,
      showMilkyWay: false,
      showGroundPlane: showGroundPlane,
      showConstellationLines: false,
      showConstellationLabels: constellations.isNotEmpty,
      showDSOLabels: dsos.isNotEmpty,
    ),
    qualityConfig: const RenderQualityConfig.quality(),
    stars: stars,
    dsos: dsos,
    constellations: constellations,
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
  return _distinctColours(bytes!);
}

/// Number of distinct RGBA values in the raster. Text antialiasing introduces
/// many intermediate shades, so this rises sharply when a label is painted and
/// is insensitive to where exactly it lands.
int _distinctColours(ByteData bytes) {
  final seen = <int>{};
  for (var i = 0; i < bytes.lengthInBytes; i += 4) {
    seen.add(bytes.getUint32(i));
  }
  return seen.length;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Two objects, same brightness: one comfortably up, one under the ground.
  // Inside the same 60-deg field as the ground (centre alt -12, az 134) so the
  // two stars differ only in being above vs below the horizon.
  final upStar = _star('UpStar', _at(altDeg: 12, azDeg: 140));
  final downStar = _star('DownStar', _at(altDeg: -20, azDeg: _viewAz));

  group('horizontal frame with the ground drawn', () {
    test('an above-horizon star is still labelled', () async {
      final bare = await _inkPixels(
        mode: SkyViewMode.horizontal,
        showGroundPlane: true,
      );
      final withStar = await _inkPixels(
        mode: SkyViewMode.horizontal,
        showGroundPlane: true,
        stars: [upStar],
      );
      expect(
        withStar,
        greaterThan(bare),
        reason: 'an observable target must still be drawn and named',
      );
    });

    test('a below-ground star adds no label ink', () async {
      final bare = await _inkPixels(
        mode: SkyViewMode.horizontal,
        showGroundPlane: true,
      );
      final withStar = await _inkPixels(
        mode: SkyViewMode.horizontal,
        showGroundPlane: true,
        stars: [downStar],
      );
      expect(
        withStar,
        bare,
        reason:
            'nothing behind the observer\'s ground may be named — this is '
            'the Fomalhaut-on-the-ground defect',
      );
    });

    test('a below-ground DSO adds no label ink', () async {
      final bare = await _inkPixels(
        mode: SkyViewMode.horizontal,
        showGroundPlane: true,
      );
      final withDso = await _inkPixels(
        mode: SkyViewMode.horizontal,
        showGroundPlane: true,
        dsos: [_dso('DownGalaxy', _at(altDeg: -20, azDeg: _viewAz))],
      );
      expect(withDso, bare);
    });

    test('a below-ground constellation label is suppressed', () async {
      final bare = await _inkPixels(
        mode: SkyViewMode.horizontal,
        showGroundPlane: true,
      );
      final withConstellation = await _inkPixels(
        mode: SkyViewMode.horizontal,
        showGroundPlane: true,
        constellations: [
          _constellation('GRUS', _at(altDeg: -20, azDeg: _viewAz)),
        ],
      );
      expect(
        withConstellation,
        bare,
        reason:
            "'GRUS' and 'CRUX' printed across the ground were the loudest "
            'version of this',
      );
    });

    test('an above-horizon constellation label still draws', () async {
      final bare = await _inkPixels(
        mode: SkyViewMode.horizontal,
        showGroundPlane: true,
      );
      final withConstellation = await _inkPixels(
        mode: SkyViewMode.horizontal,
        showGroundPlane: true,
        constellations: [
          _constellation('UPPER', _at(altDeg: 20, azDeg: _viewAz)),
        ],
      );
      expect(withConstellation, greaterThan(bare));
    });
  });

  // The defect the verifier isolated: on desktop the bright-star pass runs in a
  // SEPARATE CustomPaint stacked above the base layer that holds the ground, so
  // paint order cannot occlude it. A single full-scope painter hides the bug —
  // it measured pure ground colour at the star — which is why these cases drive
  // the base/overlay split the interactive host actually uses.
  group('base/overlay split (the shipping desktop path)', () {
    test(
      'a below-ground bright star draws nothing on the overlay layer',
      () async {
        final bare = await _inkPixels(
          mode: SkyViewMode.horizontal,
          showGroundPlane: true,
          scope: SkyRenderScope.overlay,
        );
        final withStar = await _inkPixels(
          mode: SkyViewMode.horizontal,
          showGroundPlane: true,
          stars: [downStar],
          scope: SkyRenderScope.overlay,
        );
        expect(
          withStar,
          bare,
          reason:
              'the overlay layer is stacked ABOVE the ground, so a '
              'below-horizon bright star punched straight through the terrain',
        );
      },
    );

    test(
      'an above-horizon bright star still draws on the overlay layer',
      () async {
        final bare = await _inkPixels(
          mode: SkyViewMode.horizontal,
          showGroundPlane: true,
          scope: SkyRenderScope.overlay,
        );
        final withStar = await _inkPixels(
          mode: SkyViewMode.horizontal,
          showGroundPlane: true,
          stars: [upStar],
          scope: SkyRenderScope.overlay,
        );
        expect(
          withStar,
          greaterThan(bare),
          reason: 'the twinkle pass must keep drawing observable bright stars',
        );
      },
    );

    test('the equatorial overlay is untouched', () async {
      final bare = await _inkPixels(
        mode: SkyViewMode.equatorial,
        showGroundPlane: true,
        scope: SkyRenderScope.overlay,
      );
      final withStar = await _inkPixels(
        mode: SkyViewMode.equatorial,
        showGroundPlane: true,
        stars: [downStar],
        scope: SkyRenderScope.overlay,
      );
      expect(withStar, greaterThan(bare));
    });

    test('with the ground plane off the overlay draws it anyway', () async {
      final bare = await _inkPixels(
        mode: SkyViewMode.horizontal,
        showGroundPlane: false,
        scope: SkyRenderScope.overlay,
      );
      final withStar = await _inkPixels(
        mode: SkyViewMode.horizontal,
        showGroundPlane: false,
        stars: [downStar],
        scope: SkyRenderScope.overlay,
      );
      expect(withStar, greaterThan(bare));
    });
  });

  test('with the ground plane off nothing is treated as occluded', () async {
    // The user asked not to be shown terrain; the map is then a plain atlas.
    final bare = await _inkPixels(
      mode: SkyViewMode.horizontal,
      showGroundPlane: false,
    );
    final withStar = await _inkPixels(
      mode: SkyViewMode.horizontal,
      showGroundPlane: false,
      stars: [downStar],
    );
    expect(withStar, greaterThan(bare));
  });

  test('the equatorial atlas labels everything, ground plane or not', () async {
    // No terrain is painted in this frame, so nothing may be hidden — a target
    // that has not risen yet is a first-class thing to chart here.
    for (final ground in const [true, false]) {
      final bare = await _inkPixels(
        mode: SkyViewMode.equatorial,
        showGroundPlane: ground,
      );
      final withStar = await _inkPixels(
        mode: SkyViewMode.equatorial,
        showGroundPlane: ground,
        stars: [downStar],
      );
      expect(
        withStar,
        greaterThan(bare),
        reason:
            'equatorial labelling must be unchanged (showGroundPlane: '
            '$ground)',
      );
    }
  });
}
