// Pins the planetarium's sky-survey imagery to the star field.
//
// Imagery that disagrees with the chart is worse than no imagery: it states,
// falsely, that a nebula sits where it does not, and a user frames a target on
// it. The single thing that can make that happen is a projection mismatch —
// the HiPS tile meshes are built by skotiq_core through the *framing*
// screen's projection, and the planetarium draws with `SkyCanvasPainter`'s,
// which is a different family entirely (stereographic / orthographic /
// azimuthal-equidistant, an optional alt-az frame, a view rotation).
//
// So the layer rebuilds every mesh through [SkyFovProjector]. This file asserts
// the result: a known sky coordinate — specifically a HEALPix cell corner, i.e.
// an actual vertex of a tile's mesh — lands on the SAME screen pixel in the
// tile mesh and in the real sky painter, across every projection, both view
// frames, rotated views, the 0h/24h seam and high declination.
//
// The sky painter's projection is private, so its output is read the only
// honest way available: render the real painter and observe where it actually
// draws. A single variable star is the probe because `_drawVariableStars`
// emits a `drawCircle` at the raw projected offset (no rounding, no glyph
// atlas), so the comparison is exact rather than raster-quantised. This is the
// same technique `skotiq_planetarium/test/fov_overlay_projection_test.dart`
// uses to pin the projector itself.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/sky_imagery/planetarium_sky_geometry.dart';
import 'package:skotiq_app/screens/planetarium/sky_imagery/planetarium_sky_imagery_providers.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show
        FramingTarget,
        HealpixNested,
        HipsFrame,
        HipsProperties,
        HipsTileFormat,
        HipsTileId;
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_cache.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_loader.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_selection.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart' hide SurveySource;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Deliberately larger than a HiPS tile's on-screen extent (~512 px at the
  // order the LOD rule selects), so several whole tiles fit on the canvas and
  // most mesh vertices are inside the painter's cull window.
  const size = Size(1200, 1200);
  final time = DateTime.utc(2026, 3, 14, 22, 0, 0);
  const latitude = 40.0;
  const longitude = -75.0;
  final lst = AstronomyCalculations.localSiderealTime(time, longitude);

  /// A stand-in for the DSS2 survey metadata (CDS publishes order 0..11, 512px
  /// JPEG tiles, equatorial frame). Only the order range, tile width and frame
  /// influence geometry.
  const props = HipsProperties(
    hipsOrder: 11,
    hipsOrderMin: 0,
    tileWidth: 512,
    tileWidthWasDefaulted: false,
    tileFormats: [HipsTileFormat.jpeg],
    frame: HipsFrame.equatorial,
    obsCopyright: 'Digitized Sky Survey',
  );

  /// The probe star's outer marker radius is a pure function of its magMax:
  /// `5.0 + (8.0 - magMax).clamp(0, 4)`. magMax 6.0 gives 7.0, which no other
  /// circle the marker draws can collide with.
  const probeMagMax = 6.0;
  const probeOuterRadius = 7.0;

  VariableStarData probe(double raHours, double decDeg) => VariableStarData(
        name: 'registration probe',
        constellation: 'Xxx',
        ra: raHours,
        dec: decDeg,
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

  /// Where [SkyCanvasPainter] actually draws `(raHours, decDeg)` at
  /// [viewState]. Null when the painter culls it.
  Offset? skyPainterOffset(
    double raHours,
    double decDeg,
    SkyViewState viewState,
  ) {
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
      variableStars: [probe(raHours, decDeg)],
    ).paint(canvas, size);

    final markers = canvas.circles
        .where((c) => (c.radius - probeOuterRadius).abs() < 1e-9)
        .toList();
    if (markers.isEmpty) return null;
    expect(markers, hasLength(1), reason: 'the probe marker must be unique');
    return markers.single.center;
  }

  PlanetariumSkyProjection projectionFor(SkyViewState viewState) {
    final resolved = PlanetariumSkyProjection.resolve(
      viewState: viewState,
      canvasSize: size,
      latitude: latitude,
      lstHours: lst,
    );
    expect(resolved, isNotNull, reason: 'pose must be projectable');
    return resolved!;
  }

  /// The HEALPix cell at the centre of the view, at the order the LOD rule
  /// picks for this pose — i.e. exactly the tile the layer would draw there.
  ({HealpixNested healpix, int npix, int norder}) centreTile(
    PlanetariumSkyProjection projection,
  ) {
    final norder = HipsTileSelection.selectNorder(
      projection.pixelsPerDegree,
      props,
    );
    final healpix = HealpixNested(norder);
    final npix = healpix.ang2pixNest(
      projection.center.ra * 15,
      projection.center.dec,
    );
    return (healpix: healpix, npix: npix, norder: norder);
  }

  // A pose grid covering every branch the projector has.
  final poses = <String, SkyViewState>{
    'stereographic, imaging field': const SkyViewState(
      centerRA: 5.588,
      centerDec: -5.39, // M42
      fieldOfView: 1.5,
    ),
    'stereographic, rotated 37°': const SkyViewState(
      centerRA: 5.588,
      centerDec: -5.39,
      fieldOfView: 1.5,
      rotation: 37,
    ),
    'stereographic, rotated -114°': const SkyViewState(
      centerRA: 5.588,
      centerDec: -5.39,
      fieldOfView: 3,
      rotation: -114,
    ),
    'orthographic': const SkyViewState(
      centerRA: 5,
      centerDec: 20,
      fieldOfView: 4,
      projection: SkyProjection.orthographic,
    ),
    'azimuthal equidistant, rotated': const SkyViewState(
      centerRA: 5,
      centerDec: 20,
      fieldOfView: 4,
      rotation: 22,
      projection: SkyProjection.azimuthalEquidistant,
    ),
    'high declination': const SkyViewState(
      centerRA: 5,
      centerDec: 78,
      fieldOfView: 2,
    ),
    'across the 0h/24h seam': const SkyViewState(
      centerRA: 23.98,
      centerDec: 20,
      fieldOfView: 2,
    ),
    'at the imagery FOV threshold': const SkyViewState(
      centerRA: 5,
      centerDec: 20,
      fieldOfView: kPlanetariumSkyImageryMaxFovDegrees,
    ),
    'horizontal frame': const SkyViewState(
      fieldOfView: 3,
      viewMode: SkyViewMode.horizontal,
      centerAz: 140,
      centerAltitude: 45,
    ),
    'horizontal frame, rotated': const SkyViewState(
      fieldOfView: 3,
      rotation: 63,
      viewMode: SkyViewMode.horizontal,
      centerAz: 140,
      centerAltitude: 45,
    ),
  };

  group('tile mesh vertices land where the sky painter draws them', () {
    poses.forEach((name, viewState) {
      test('$name — every mesh vertex matches the painter to 1e-9 px', () {
        final projection = projectionFor(viewState);
        final tile = centreTile(projection);

        final mesh = PlanetariumSkyTiles.buildMesh(
          healpix: tile.healpix,
          npix: tile.npix,
          projector: projection.projector,
        );
        expect(
          mesh,
          isNotNull,
          reason: 'the tile under the view centre must be placeable',
        );

        final canvasRect = Offset.zero & size;
        var compared = 0;
        for (final vertex in mesh!.vertices) {
          final painted = skyPainterOffset(
            vertex.raHours,
            vertex.decDegrees,
            viewState,
          );
          if (painted == null) {
            // The painter culls what falls outside the canvas, so a null is
            // only legitimate when the mesh put the vertex off-canvas too.
            // A culled vertex the mesh placed ON canvas would mean the two
            // disagree about where that sky point is — the exact failure this
            // file exists to catch.
            expect(
              canvasRect.contains(vertex.screen),
              isFalse,
              reason:
                  'the painter culled ${vertex.raHours}h ${vertex.decDegrees}° '
                  'but the mesh placed it ON canvas at ${vertex.screen} '
                  'in "\$name"',
            );
            continue;
          }
          expect(
            vertex.screen.dx,
            closeTo(painted.dx, 1e-9),
            reason: 'x mismatch at (u=${vertex.u}, v=${vertex.v}) in "\$name"',
          );
          expect(
            vertex.screen.dy,
            closeTo(painted.dy, 1e-9),
            reason: 'y mismatch at (u=${vertex.u}, v=${vertex.v}) in "\$name"',
          );
          compared++;
        }

        expect(
          compared,
          greaterThanOrEqualTo(4),
          reason: 'the pose must actually exercise the comparison',
        );
      });
    });

    test('M42 itself lands on the same pixel in mesh space and star space', () {
      // The motivating case, stated as a single explicit fact rather than a
      // loop: at the 1.5° field where the catalogue supplies ~15 stars, the
      // tile the layer draws over M42 is anchored to M42's own pixel.
      const m42Ra = 5.58806;
      const m42Dec = -5.39111;
      const viewState = SkyViewState(
        centerRA: m42Ra,
        centerDec: m42Dec,
        fieldOfView: 1.5,
      );

      final projection = projectionFor(viewState);
      final painted = skyPainterOffset(m42Ra, m42Dec, viewState)!;
      final projected = projection.project(m42Ra, m42Dec)!;

      expect(projected.dx, closeTo(painted.dx, 1e-9));
      expect(projected.dy, closeTo(painted.dy, 1e-9));
      // And it is the view centre, so the imagery is centred on the target.
      expect(painted.dx, closeTo(size.width / 2, 1e-6));
      expect(painted.dy, closeTo(size.height / 2, 1e-6));
    });
  });

  group('mesh construction', () {
    const viewState = SkyViewState(
      centerRA: 5.588,
      centerDec: -5.39,
      fieldOfView: 1.5,
    );

    test('mirrors the core mesh lattice: 5x5 row-major, u=col, v=row', () {
      final projection = projectionFor(viewState);
      final tile = centreTile(projection);
      final mesh = PlanetariumSkyTiles.buildMesh(
        healpix: tile.healpix,
        npix: tile.npix,
        projector: projection.projector,
      )!;

      expect(mesh.subdivisions, PlanetariumSkyTiles.defaultSubdivisions);
      expect(mesh.verticesPerSide, 5);
      expect(mesh.vertices, hasLength(25));
      for (var row = 0; row < 5; row++) {
        for (var col = 0; col < 5; col++) {
          final vertex = mesh.vertexAt(row, col);
          expect(vertex.u, closeTo(col / 4, 1e-12));
          expect(vertex.v, closeTo(row / 4, 1e-12));
        }
      }
    });

    test(
        'shares its corner sky points with the core boundary routine, so '
        'neighbouring tiles stay seam-free', () {
      // Seam-freedom depends on adjacent tiles agreeing on their shared edge
      // sky points to the bit. The core selection builds its corners from
      // HealpixNested.xyfToAng on the same fractional lattice; asserting the
      // mesh corners equal HealpixNested.boundaries pins that this rebuild did
      // not drift.
      final projection = projectionFor(viewState);
      final tile = centreTile(projection);
      final mesh = PlanetariumSkyTiles.buildMesh(
        healpix: tile.healpix,
        npix: tile.npix,
        projector: projection.projector,
      )!;
      final corners = tile.healpix.boundaries(tile.npix);

      // boundaries() returns the four corners in the same (0,0)/(1,0)/(0,1)/
      // (1,1) intra-face order the mesh corners are generated in.
      final meshCorners = <({double ra, double dec})>[
        (ra: mesh.vertexAt(0, 0).raHours, dec: mesh.vertexAt(0, 0).decDegrees),
        (ra: mesh.vertexAt(0, 4).raHours, dec: mesh.vertexAt(0, 4).decDegrees),
        (ra: mesh.vertexAt(4, 0).raHours, dec: mesh.vertexAt(4, 0).decDegrees),
        (ra: mesh.vertexAt(4, 4).raHours, dec: mesh.vertexAt(4, 4).decDegrees),
      ];

      for (final corner in meshCorners) {
        final matched = corners.any(
          (c) =>
              (c.raDeg / 15 - corner.ra).abs() < 1e-9 &&
              (c.decDeg - corner.dec).abs() < 1e-9,
        );
        expect(
          matched,
          isTrue,
          reason: 'mesh corner ${corner.ra}h ${corner.dec}° is not one of the '
              'HEALPix cell boundary points $corners',
        );
      }
    });

    test('a tile behind the projection plane yields no mesh at all', () {
      // Half-projected meshes smear a tile across the canvas; the builder must
      // refuse rather than place some of the vertices.
      const wide = SkyViewState(centerRA: 5, centerDec: 0, fieldOfView: 8);
      final projection = projectionFor(wide);
      final healpix = HealpixNested(2);
      // The cell antipodal to the view centre.
      final antipodalNpix = healpix.ang2pixNest((5 + 12) % 24 * 15, 0);
      expect(
        PlanetariumSkyTiles.buildMesh(
          healpix: healpix,
          npix: antipodalNpix,
          projector: projection.projector,
        ),
        isNull,
      );
    });
  });

  group('loader plate-scale shim', () {
    test(
        'reproduces the planetarium scale exactly, so the loader selects the '
        'planetarium level of detail', () {
      for (final canvas in const [
        Size(400, 400),
        Size(1920, 1080),
        Size(600, 900),
        Size(1280, 800),
      ]) {
        for (final fov in const [0.5, 1.5, 4.0, 8.0]) {
          final ppd = SkyFovProjector.scaleFor(canvas, fov);
          final scale = PlanetariumSkyTiles.plateScaleFor(canvas, ppd);
          expect(
            scale.pixelsPerDegree(canvas, 1.0),
            closeTo(ppd, 1e-9),
            reason: 'canvas \$canvas at \$fov deg must round-trip',
          );
        }
      }
    });

    test('and therefore picks the same Norder the planetarium scale implies',
        () {
      const canvas = Size(1920, 1080);
      for (final fov in const [0.5, 1.5, 4.0, 8.0]) {
        final ppd = SkyFovProjector.scaleFor(canvas, fov);
        final scale = PlanetariumSkyTiles.plateScaleFor(canvas, ppd);
        expect(
          HipsTileSelection.selectNorder(
            scale.pixelsPerDegree(canvas, 1.0),
            props,
          ),
          HipsTileSelection.selectNorder(ppd, props),
        );
      }
    });
  });

  group('reprojecting the loader snapshot', () {
    const viewState = SkyViewState(
      centerRA: 5.588,
      centerDec: -5.39,
      fieldOfView: 1.5,
    );
    const surveyId = 'CDS/P/DSS2/red';

    /// A loader snapshot whose meshes are in FRAMING projection space, exactly
    /// as the shared loader produces them.
    HipsResidentSnapshot framingSnapshot(PlanetariumSkyProjection projection) {
      final norder = HipsTileSelection.selectNorder(
        projection.pixelsPerDegree,
        props,
      );
      final visible = HipsTileSelection.computeVisibleTiles(
        PlanetariumSkyTiles.plateScaleFor(size, projection.pixelsPerDegree),
        FramingTarget(
          name: 'probe',
          raHours: projection.center.ra,
          decDegrees: projection.center.dec,
        ),
        size,
        1.0,
        norder,
        props,
        surveyId: surveyId,
      );
      return HipsResidentSnapshot(
        version: 7,
        selectedNorder: norder,
        primaryTiles: const [],
        fallbackTiles: const [],
        allsky: null,
        cacheSnapshot: HipsTileCacheSnapshot.empty,
        visibleSet: visible,
        failures: const [],
      );
    }

    test(
        'keeps the loader tile set and replaces every mesh with the '
        'planetarium projection', () {
      final projection = projectionFor(viewState);
      final source = framingSnapshot(projection);
      expect(source.visibleSet!.tiles, isNotEmpty);

      final result = PlanetariumSkyTiles.reproject(
        source: source,
        projector: projection.projector,
        props: props,
        surveyId: surveyId,
        version: 42,
      );

      expect(result.version, 42);
      expect(result.selectedNorder, source.selectedNorder);

      // The drawn tile ids are a subset of the ids the loader asked for, so the
      // layer can never draw a tile that was never fetched.
      final requested = source.visibleSet!.tiles.map((t) => t.id).toSet();
      for (final tile in result.visibleSet!.tiles) {
        expect(requested, contains(tile.id));
      }

      // Every drawn vertex is at the planetarium projector's position for its
      // own sky coordinate — not the framing projection's.
      for (final tile in result.visibleSet!.tiles) {
        for (final vertex in tile.mesh.vertices) {
          final expected = projection.projector.projectRaDec(
            vertex.raHours,
            vertex.decDegrees,
          );
          expect(expected, isNotNull);
          expect(vertex.screen.dx, closeTo(expected!.dx, 1e-9));
          expect(vertex.screen.dy, closeTo(expected.dy, 1e-9));
        }
      }
    });

    test(
        'classifies resident tiles as primary and the rest as coarse '
        'fallbacks carrying the REPROJECTED child mesh', () async {
      final projection = projectionFor(viewState);
      final source = framingSnapshot(projection);
      final tiles = source.visibleSet!.tiles;
      final norder = source.selectedNorder;

      // One resident sharp tile, and one resident grandparent to back a second
      // sharp tile that has not arrived.
      final image = await _solidImage();
      final sharp = tiles.first.id;
      final orphan = tiles.length > 1 ? tiles[1].id : tiles.first.id;
      final ancestor = HipsTileId(
        survey: surveyId,
        norder: norder - 2,
        npix: orphan.npix >> 4,
      );
      final cache = HipsTileCache(maxEntries: 8, maxBytes: 8 << 20);
      addTearDown(cache.dispose);
      cache.put(sharp, image);
      cache.put(ancestor, await _solidImage());

      final result = PlanetariumSkyTiles.reproject(
        source: HipsResidentSnapshot(
          version: source.version,
          selectedNorder: norder,
          primaryTiles: const [],
          fallbackTiles: const [],
          allsky: null,
          cacheSnapshot: cache.snapshot(),
          visibleSet: source.visibleSet,
          failures: const [],
        ),
        projector: projection.projector,
        props: props,
        surveyId: surveyId,
        version: 1,
      );

      expect(result.primaryTiles.map((t) => t.id), contains(sharp));
      final fallback =
          result.fallbackTiles.where((f) => f.ancestorId == ancestor).toList();
      if (orphan != sharp) {
        // Several sharp tiles can share one grandparent, so this is "at least
        // one", not exactly one.
        expect(
          fallback,
          isNotEmpty,
          reason: 'the un-arrived sharp tiles must fall back to the ancestor',
        );
        // Each fallback must carry its child's REPROJECTED mesh, otherwise the
        // coarse imagery would be drawn at the framing projection.
        for (final entry in fallback) {
          for (final vertex in entry.mesh.vertices) {
            final expected = projection.projector.projectRaDec(
              vertex.raHours,
              vertex.decDegrees,
            )!;
            expect(vertex.screen.dx, closeTo(expected.dx, 1e-9));
            expect(vertex.screen.dy, closeTo(expected.dy, 1e-9));
          }
        }
      }
    });

    test('an empty loader snapshot reprojects to nothing to draw', () {
      final projection = projectionFor(viewState);
      final result = PlanetariumSkyTiles.reproject(
        source: HipsResidentSnapshot.empty,
        projector: projection.projector,
        props: props,
        surveyId: surveyId,
        version: 3,
      );
      expect(result.hasAnyImagery, isFalse);
      expect(result.visibleSet, isNull);
    });
  });

  group('activation gate', () {
    test('the FOV threshold is inside the band where the chart runs out', () {
      // ~2.9 HYG stars per square degree: the threshold must sit where the
      // chart is still worth showing (hundreds of stars) and the layer must be
      // engaged by the time a normal imaging field is on screen.
      const density = 118000 / 41253.0;
      const atThreshold = density *
          kPlanetariumSkyImageryMaxFovDegrees *
          kPlanetariumSkyImageryMaxFovDegrees;
      expect(atThreshold, greaterThan(100));
      expect(kPlanetariumSkyImageryMaxFovDegrees, greaterThan(3.0));
      expect(kPlanetariumSkyImageryMaxFovDegrees, lessThan(15.0));
    });
  });
}

/// A solid 4x4 image, enough to stand in for a decoded tile in the cache.
Future<ui.Image> _solidImage() {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 4, 4),
    Paint()..color = const Color(0xFF808080),
  );
  return recorder.endRecording().toImage(4, 4);
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
