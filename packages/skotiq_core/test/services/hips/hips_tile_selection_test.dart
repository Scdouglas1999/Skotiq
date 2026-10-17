import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/framing_hips_projection.dart';
import 'package:skotiq_core/src/models/framing_plate_scale.dart';
import 'package:skotiq_core/src/models/hips/hips_properties.dart';
import 'package:skotiq_core/src/models/hips/hips_tile_id.dart';
import 'package:skotiq_core/src/providers/framing_provider.dart'
    show FramingTarget;
import 'package:skotiq_core/src/services/hips/healpix_nested.dart';
import 'package:skotiq_core/src/services/hips/hips_tile_selection.dart';

/// Tests for component C3 — Norder selection + visible-tile-set computation.
///
/// Coverage:
///   * [HipsTileSelection.selectNorder] implements the tilepix rule exactly,
///     clamps to the survey range, scales with tile width, and surfaces a
///     degenerate scale instead of guessing.
///   * [HipsTileSelection.computeVisibleTiles] returns a non-empty, ordered,
///     in-range tile set whose meshes register to the same projection the
///     survey background uses, with seam-free shared corners between
///     neighbours, and that grows/shrinks the set with the FOV.
void main() {
  // A realistic CDS-style survey: DSS2 red, 512-px tiles, order 9.
  final props512 = HipsProperties.parse('''
hips_order        = 9
hips_order_min    = 3
hips_tile_width   = 512
hips_tile_format  = jpeg
hips_frame        = equatorial
''');

  HipsProperties propsWithTileWidth(int width) => HipsProperties.parse('''
hips_order        = 12
hips_order_min    = 0
hips_tile_width   = $width
hips_tile_format  = jpeg
hips_frame        = equatorial
''');

  // A standard framing plate scale: a 3-degree-wide square survey cutout at
  // 1000x1000 px. pixelsPerDegree at zoom 1 on a 1000-px canvas == 1000/3.
  const plateScale = FramingPlateScale(
    surveyFovWidthDeg: 3.0,
    surveyFovHeightDeg: 3.0,
    imagePixelWidth: 1000,
    imagePixelHeight: 1000,
  );

  const target = FramingTarget(
    name: 'M42',
    raHours: 5.5882, // 83.823 deg
    decDegrees: -5.391,
  );

  const canvas = Size(1000, 1000);

  group('selectNorder', () {
    test('implements the literal tilepix rule for 512-px tiles', () {
      // For any positive scale, the result must equal the spec formula
      // clamped: ceil(log2(412 / arcsec_per_px)) clamped to [min, max].
      for (final pxPerDeg in <double>[50, 200, 1000, 5000, 50000]) {
        final arcsecPerPx = 3600.0 / pxPerDeg;
        final expectedRaw = (math.log(412.0 / arcsecPerPx) / math.ln2).ceil();
        final expected = expectedRaw.clamp(
          props512.hipsOrderMin,
          props512.hipsOrder,
        );
        expect(
          HipsTileSelection.selectNorder(pxPerDeg, props512),
          expected,
          reason: 'tilepix rule mismatch at $pxPerDeg px/deg',
        );
      }
    });

    test('monotonically non-decreasing with zoom (finer at higher px/deg)', () {
      var last = -1;
      for (final pxPerDeg in <double>[10, 50, 200, 1000, 5000, 50000]) {
        final order = HipsTileSelection.selectNorder(pxPerDeg, props512);
        expect(
          order,
          greaterThanOrEqualTo(last),
          reason: 'order must not drop as we zoom in',
        );
        last = order;
      }
    });

    test('clamps to the survey min when zoomed far out', () {
      // Whole-sky scale: arcsec/px huge -> raw order negative -> clamp to min.
      final order = HipsTileSelection.selectNorder(0.1, props512);
      expect(order, props512.hipsOrderMin);
    });

    test('clamps to the survey max when zoomed far in', () {
      final order = HipsTileSelection.selectNorder(1e7, props512);
      expect(order, props512.hipsOrder);
    });

    test('a wider tile reaches the same order at coarser screen scale', () {
      // A 1024-px survey resolves twice as finely per order as a 512-px one,
      // so at the same arcsec/px it selects an order >= the 512 selection.
      const pxPerDeg = 3000.0;
      final order512 = HipsTileSelection.selectNorder(
        pxPerDeg,
        propsWithTileWidth(512),
      );
      final order1024 = HipsTileSelection.selectNorder(
        pxPerDeg,
        propsWithTileWidth(1024),
      );
      expect(order1024, greaterThanOrEqualTo(order512));
      // Specifically one order finer for an exact doubling (log2(2) == 1),
      // away from the clamp bounds.
      expect(order1024 - order512, 1);
    });

    test('surfaces a degenerate scale instead of guessing', () {
      expect(
        () => HipsTileSelection.selectNorder(0.0, props512),
        throwsA(isA<HipsTileSelectionError>()),
      );
      expect(
        () => HipsTileSelection.selectNorder(-5.0, props512),
        throwsA(isA<HipsTileSelectionError>()),
      );
      expect(
        () => HipsTileSelection.selectNorder(double.nan, props512),
        throwsA(isA<HipsTileSelectionError>()),
      );
      expect(
        () => HipsTileSelection.selectNorder(double.infinity, props512),
        throwsA(isA<HipsTileSelectionError>()),
      );
    });
  });

  group('computeVisibleTiles', () {
    test('returns a non-empty, ordered, in-range tile set', () {
      final norder = HipsTileSelection.selectNorder(
        plateScale.pixelsPerDegree(canvas, 1.0),
        props512,
      );
      final set = HipsTileSelection.computeVisibleTiles(
        plateScale,
        target,
        canvas,
        1.0,
        norder,
        props512,
        surveyId: 'CDS/P/DSS2/red',
      );

      expect(set.tiles, isNotEmpty);
      expect(set.norder, norder);

      // Ordered ascending by npix (deterministic).
      final npix = set.tiles.map((t) => t.id.npix).toList();
      final sorted = [...npix]..sort();
      expect(npix, sorted);

      // Every tile is in range and carries a full mesh.
      final tileCount = HipsTileId.numberOfTiles(norder);
      for (final tile in set.tiles) {
        expect(tile.id.norder, norder);
        expect(tile.id.npix, inInclusiveRange(0, tileCount - 1));
        expect(tile.id.survey, 'CDS/P/DSS2/red');
        const n = HipsTileSelection.defaultSubdivisions;
        expect(tile.mesh.subdivisions, n);
        expect(tile.mesh.vertices.length, (n + 1) * (n + 1));
      }
    });

    test('tile corners register to the projection the background uses', () {
      const norder = 6;
      final set = HipsTileSelection.computeVisibleTiles(
        plateScale,
        target,
        canvas,
        1.0,
        norder,
        props512,
      );
      // Build the SAME projection independently and verify each mesh corner's
      // screen position equals the projection's forward transform of its sky
      // point. This is the registration guarantee: tiles use C2, full stop.
      final projection = FramingSkyProjection.fromResolved(
        plateScale: plateScale,
        canvasSize: canvas,
        centerRaHours: target.raHours,
        centerDecDegrees: target.decDegrees,
        zoom: 1.0,
        pan: Offset.zero,
        rotationDegrees: 0.0,
      );
      for (final tile in set.tiles) {
        for (final vtx in tile.mesh.vertices) {
          final expected = projection.raDecToScreen(
            vtx.raHours,
            vtx.decDegrees,
          );
          expect(
            (vtx.screen - expected).distance,
            lessThan(1e-6),
            reason: 'mesh vertex must equal C2 projection of its sky point',
          );
        }
      }
    });

    test('mesh corners coincide exactly with HEALPix boundaries (seam-free)', () {
      const norder = 6;
      final set = HipsTileSelection.computeVisibleTiles(
        plateScale,
        target,
        canvas,
        1.0,
        norder,
        props512,
      );
      final healpix = HealpixNested(norder);

      String key(double ra, double dec) =>
          '${ra.toStringAsFixed(10)},${dec.toStringAsFixed(10)}';

      // The four mesh corners (row/col 0 and n) must be the four
      // HealpixNested.boundaries corners, so adjacent tiles share them exactly.
      for (final tile in set.tiles) {
        final mesh = tile.mesh;
        final n = mesh.subdivisions;
        final meshCorners = <String>{
          key(mesh.vertexAt(0, 0).raHours * 15, mesh.vertexAt(0, 0).decDegrees),
          key(mesh.vertexAt(0, n).raHours * 15, mesh.vertexAt(0, n).decDegrees),
          key(mesh.vertexAt(n, n).raHours * 15, mesh.vertexAt(n, n).decDegrees),
          key(mesh.vertexAt(n, 0).raHours * 15, mesh.vertexAt(n, 0).decDegrees),
        };
        final boundaryCorners = healpix
            .boundaries(tile.id.npix)
            .map((a) => key(a.raDeg, a.decDeg))
            .toSet();
        expect(
          meshCorners,
          boundaryCorners,
          reason:
              'tile ${tile.id.npix} mesh corners must equal its '
              'HEALPix boundary corners (seam-free)',
        );
      }

      // Neighbour adjacency: any two visible neighbours share >= 2 exact
      // corner sky points, hence their projected edges coincide.
      final visible = {for (final t in set.tiles) t.id.npix};
      var sharedPairs = 0;
      for (final tile in set.tiles) {
        for (final nb in healpix.neighboursNest(tile.id.npix)) {
          if (nb < 0 || !visible.contains(nb)) continue;
          final a = healpix
              .boundaries(tile.id.npix)
              .map((p) => key(p.raDeg, p.decDeg))
              .toSet();
          final b = healpix
              .boundaries(nb)
              .map((p) => key(p.raDeg, p.decDeg))
              .toSet();
          if (a.intersection(b).length >= 2) sharedPairs++;
        }
      }
      expect(
        sharedPairs,
        greaterThan(0),
        reason: 'neighbouring tiles must share exact edges',
      );
    });

    test('the visible set covers the canvas corners', () {
      const norder = 7;
      final set = HipsTileSelection.computeVisibleTiles(
        plateScale,
        target,
        canvas,
        1.0,
        norder,
        props512,
      );
      final healpix = HealpixNested(norder);
      final visible = {for (final t in set.tiles) t.id.npix};

      // The HEALPix tile under each canvas corner's sky point must be in the
      // visible set — otherwise we would paint a blank gutter at that corner.
      for (final corner in set.projection.visibleSkyCorners()) {
        final raDeg = corner.raHours * 15.0;
        final pix = healpix.ang2pixNest(raDeg, corner.decDegrees);
        expect(
          visible,
          contains(pix),
          reason: 'canvas corner sky pixel $pix missing from visible set',
        );
      }
    });

    test('the visible set grows when zooming out (larger FOV)', () {
      // Same order, two zooms: the more-zoomed-out view (smaller zoom factor =>
      // smaller px/deg => larger FOV) must include at least as many tiles.
      const norder = 6;
      final zoomedIn = HipsTileSelection.computeVisibleTiles(
        plateScale,
        target,
        canvas,
        2.0,
        norder,
        props512,
      );
      final zoomedOut = HipsTileSelection.computeVisibleTiles(
        plateScale,
        target,
        canvas,
        0.5,
        norder,
        props512,
      );
      expect(
        zoomedOut.tiles.length,
        greaterThanOrEqualTo(zoomedIn.tiles.length),
      );
    });

    test('rotation rotates the meshes but preserves the tile set', () {
      const norder = 6;
      final noRot = HipsTileSelection.computeVisibleTiles(
        plateScale,
        target,
        canvas,
        1.0,
        norder,
        props512,
      );
      final rotated = HipsTileSelection.computeVisibleTiles(
        plateScale,
        target,
        canvas,
        1.0,
        norder,
        props512,
        rotationDegrees: 30.0,
      );

      // Same tiles selected (selection is sky-based, independent of rotation
      // about the canvas center because the disc is centered on the target).
      expect(rotated.tileIds, noRot.tileIds);

      // But the screen meshes differ (rotated) for at least one off-center
      // vertex.
      final a = noRot.tiles.first.mesh.vertices.first.screen;
      final b = rotated.tiles.first.mesh.vertices.first.screen;
      expect(
        (a - b).distance,
        greaterThan(0.5),
        reason: 'rotation must move off-center mesh vertices on screen',
      );
    });

    test('rejects out-of-range Norder, subdivisions, and canvas', () {
      expect(
        () => HipsTileSelection.computeVisibleTiles(
          plateScale,
          target,
          canvas,
          1.0,
          props512.hipsOrder + 1,
          props512,
        ),
        throwsA(isA<HipsTileSelectionError>()),
      );
      expect(
        () => HipsTileSelection.computeVisibleTiles(
          plateScale,
          target,
          canvas,
          1.0,
          props512.hipsOrderMin - 1,
          props512,
        ),
        throwsA(isA<HipsTileSelectionError>()),
      );
      expect(
        () => HipsTileSelection.computeVisibleTiles(
          plateScale,
          target,
          canvas,
          1.0,
          6,
          props512,
          subdivisions: 0,
        ),
        throwsA(isA<HipsTileSelectionError>()),
      );
      expect(
        () => HipsTileSelection.computeVisibleTiles(
          plateScale,
          target,
          Size.zero,
          1.0,
          6,
          props512,
        ),
        throwsA(isA<HipsTileSelectionError>()),
      );
    });

    test('honours a custom subdivision count', () {
      final set = HipsTileSelection.computeVisibleTiles(
        plateScale,
        target,
        canvas,
        1.0,
        6,
        props512,
        subdivisions: 8,
      );
      expect(set.tiles.first.mesh.subdivisions, 8);
      expect(set.tiles.first.mesh.vertices.length, 9 * 9);
    });

    test('rejects a non-equatorial (galactic/ecliptic) survey rather than '
        'silently mis-projecting it against the equatorial FOV overlay', () {
      // The whole pipeline assumes an equatorial tiling: the framing target's
      // equatorial RA/Dec is fed straight into HEALPix. A galactic- or
      // ecliptic-framed survey would be addressed with the wrong pixels and the
      // mesh sky points reprojected as if equatorial — total misregistration
      // with no error. Until a frame->equatorial rotation exists, such a
      // survey must fail here rather than be consumed.
      for (final frame in const ['galactic', 'ecliptic']) {
        final props = HipsProperties.parse('''
hips_order        = 9
hips_order_min    = 3
hips_tile_width   = 512
hips_tile_format  = jpeg
hips_frame        = $frame
''');
        expect(
          () => HipsTileSelection.computeVisibleTiles(
            plateScale,
            target,
            canvas,
            1.0,
            6,
            props,
          ),
          throwsA(isA<HipsTileSelectionError>()),
          reason: 'a $frame-framed survey must be rejected by tile selection',
        );
      }

      // The equatorial control still succeeds.
      expect(
        HipsTileSelection.computeVisibleTiles(
          plateScale,
          target,
          canvas,
          1.0,
          6,
          props512,
        ).tiles,
        isNotEmpty,
      );
    });
  });
}
