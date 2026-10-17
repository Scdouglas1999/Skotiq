// Component C10 — seam-free mosaicing guard for the Flutter-side GPU HiPS
// framing tile layer, over the committed C-FIX primary tile set.
//
// THE CONTRACT THIS PINS (anti-jank requirement #5, seam-free mosaicing):
// neighbouring HEALPix tiles must share byte-identical boundary sky points, so
// when each is projected to the canvas their touching edges coincide to the
// pixel and the mosaic has NO gaps / black slivers between tiles at any zoom.
//
// HOW IT PROVES IT, without trusting a single code path twice:
//   1. Build the production C3 visible-tile meshes for the M31 fixture field.
//   2. For every pair of tiles that are HEALPix neighbours (their NESTED indices
//      address adjacent diamonds), find the boundary they share and assert the
//      mesh vertices along that shared boundary co-locate on screen — to the
//      pixel — between the two tiles. Coinciding projected edges == seam-free.
//   3. Independently, assert each tile's projected footprint (its mesh screen
//      bounds) overlaps or abuts its neighbour with no gap wider than a sub-pixel
//      tolerance, at multiple zooms, so a regression that left a gutter is caught
//      visually as well as per-vertex.
//
// The fixture's committed primary set (the full gap-free Norder6 mosaic footprint
// over M31) is the realistic, dense neighbour graph this needs.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/models/framing_plate_scale.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/models/hips/hips_properties.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/providers/framing_provider.dart'
    show FramingTarget;
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/healpix_nested.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_selection.dart';

import '../../fixtures/hips/fixture_field.dart' as fixture;

const FramingTarget _target = FramingTarget(
  name: fixture.fieldName,
  catalogId: 'M31',
  raHours: fixture.fieldRaHours,
  decDegrees: fixture.fieldDecDeg,
);

const FramingPlateScale _plateScale = FramingPlateScale(
  surveyFovWidthDeg: fixture.fixtureFovWidthDeg,
  surveyFovHeightDeg: fixture.fixtureFovHeightDeg,
  imagePixelWidth: fixture.fixturePixelWidth,
  imagePixelHeight: fixture.fixturePixelHeight,
);

final Size _canvasSize = Size(
  fixture.fixturePixelWidth.toDouble(),
  fixture.fixturePixelHeight.toDouble(),
);

/// Two tiles' meshes touch seamlessly when a vertex on one tile's mesh edge has
/// a coincident vertex on the other's edge. This is the per-pixel coincidence
/// tolerance: the shared HEALPix boundary points are byte-identical sky points,
/// so the projected screen positions must agree to floating-point precision.
const double _seamTolerancePx = 1e-6;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HipsProperties props;
  setUpAll(() {
    props = HipsProperties.parse(fixture.readPropertiesText());
  });

  HipsVisibleTileSet visibleSetAt(double zoom, {int subdivisions = 4}) {
    final norder = HipsTileSelection.selectNorder(
      _plateScale.pixelsPerDegree(_canvasSize, zoom),
      props,
    );
    return HipsTileSelection.computeVisibleTiles(
      _plateScale,
      _target,
      _canvasSize,
      zoom,
      norder,
      props,
      subdivisions: subdivisions,
      surveyId: fixture.surveyHipsId,
    );
  }

  test(
      'neighbouring tiles share coincident projected boundary vertices (no gaps '
      'between adjacent meshes)', () {
    final visibleSet = visibleSetAt(1.0);
    expect(visibleSet.tiles.length, greaterThan(1),
        reason: 'A multi-tile mosaic is needed to test seams between '
            'neighbours.');

    // The set of distinct projected vertices of each tile, rounded to a fine
    // grid so a shared boundary point on two tiles compares equal despite
    // floating-point noise below the seam tolerance.
    int key(double v) => (v / _seamTolerancePx).round();
    final tileVertexKeys = <int, Set<(int, int)>>{};
    for (var i = 0; i < visibleSet.tiles.length; i++) {
      final keys = <(int, int)>{};
      for (final vtx in visibleSet.tiles[i].mesh.vertices) {
        keys.add((key(vtx.screen.dx), key(vtx.screen.dy)));
      }
      tileVertexKeys[i] = keys;
    }

    // For every pair of tiles whose HEALPix diamonds are HEALPix neighbours, the
    // seam-free witness depends on HOW they touch:
    //   * EDGE-adjacent neighbours (compass W/N/E/S) share a full common edge, so
    //     their meshes MUST share BOTH of that edge's projected corner vertices
    //     (>= 2 coincident corners). A gap there would be a visible seam.
    //   * DIAGONAL (corner-only) neighbours (compass NW/NE/SE/SW) meet at a SINGLE
    //     shared corner, so they coincide at exactly 1 vertex; requiring 2 there
    //     would be a false failure (the diamonds genuinely touch at one point).
    // We classify each neighbour pair by WHICH compass slot of neighboursNest
    // holds it (the library's canonical W,NW,N,NE,E,SE,S,SW ordering: even slots
    // are edges, odd slots are diagonals), so the test shares the production
    // HEALPix topology rather than re-deriving adjacency across face seams.
    final healpix = HealpixNested(visibleSet.norder);
    var edgePairsChecked = 0;
    var diagonalPairsChecked = 0;
    for (var i = 0; i < visibleSet.tiles.length; i++) {
      for (var j = i + 1; j < visibleSet.tiles.length; j++) {
        final a = visibleSet.tiles[i];
        final b = visibleSet.tiles[j];
        final adjacency = _healpixAdjacency(healpix, a.id.npix, b.id.npix);
        if (adjacency == _Adjacency.none) continue;

        final shared = tileVertexKeys[i]!.intersection(tileVertexKeys[j]!);
        if (adjacency == _Adjacency.edge) {
          edgePairsChecked++;
          expect(shared.length, greaterThanOrEqualTo(2),
              reason: 'Edge-adjacent tiles ${a.id.npix} and ${b.id.npix} must '
                  'share their common edge\'s projected boundary vertices (>= 2 '
                  'coincident corners) so the mosaic is seam-free. Found '
                  '${shared.length}.');
        } else {
          diagonalPairsChecked++;
          expect(shared.length, greaterThanOrEqualTo(1),
              reason: 'Diagonal (corner-only) tiles ${a.id.npix} and '
                  '${b.id.npix} meet at exactly one shared corner; their '
                  'projected meshes must coincide at >= 1 vertex (no gap at the '
                  'shared corner). Found ${shared.length}.');
        }
      }
    }
    expect(edgePairsChecked, greaterThan(0),
        reason:
            'The fixture mosaic must contain >= 1 edge-adjacent tile pair to '
            'exercise the seam guarantee.');
    expect(diagonalPairsChecked, greaterThan(0),
        reason:
            'The fixture mosaic must contain >= 1 diagonal neighbour pair so '
            'the corner-only coincidence path is also exercised (this is the '
            'pair that a naive >= 2 assertion misclassifies as a seam).');
  });

  for (final zoom in const <double>[0.5, 1.0, 2.0, 4.0]) {
    test('mosaic footprints abut with no gap > sub-pixel at zoom $zoom', () {
      final visibleSet = visibleSetAt(zoom);
      if (visibleSet.tiles.length < 2) return; // Nothing to abut at this zoom.

      final healpix = HealpixNested(visibleSet.norder);

      // For each adjacent neighbour pair, the gap between their projected
      // footprints along the shared edge must be effectively zero: their bounding
      // rects must touch or overlap (a positive separation would be a visible
      // black sliver).
      for (var i = 0; i < visibleSet.tiles.length; i++) {
        for (var j = i + 1; j < visibleSet.tiles.length; j++) {
          final a = visibleSet.tiles[i];
          final b = visibleSet.tiles[j];
          if (_healpixAdjacency(healpix, a.id.npix, b.id.npix) ==
              _Adjacency.none) {
            continue;
          }

          final ra = a.mesh.screenBounds!;
          final rb = b.mesh.screenBounds!;
          // Separation between the two axis-aligned footprints: positive only if
          // they are disjoint with a gutter between them.
          final dx = math.max(
            0.0,
            math.max(rb.left - ra.right, ra.left - rb.right),
          );
          final dy = math.max(
            0.0,
            math.max(rb.top - ra.bottom, ra.top - rb.bottom),
          );
          final separation = math.sqrt(dx * dx + dy * dy);
          expect(separation, lessThan(1.0),
              reason: 'Adjacent tiles ${a.id.npix}/${b.id.npix} leave a '
                  '${separation.toStringAsFixed(3)}px gutter at zoom $zoom — a '
                  'visible seam. Neighbour footprints must touch or overlap.');
        }
      }
    });
  }
}

/// How two HEALPix NESTED diamonds touch.
enum _Adjacency {
  /// Not neighbours at all.
  none,

  /// Share a full common edge (compass W/N/E/S neighbour) — two shared corners.
  edge,

  /// Touch at a single corner only (compass NW/NE/SE/SW neighbour).
  diagonal,
}

/// Classifies how HEALPix NESTED pixels [npixA] and [npixB] at the [healpix]
/// order touch, using the library's own neighbour query so the test shares the
/// production HEALPix topology rather than re-deriving adjacency across face
/// seams.
///
/// `neighboursNest` returns the eight compass neighbours in the canonical
/// `W, NW, N, NE, E, SE, S, SW` order (with `-1` in any slot missing at a face
/// corner). The EVEN slots (0=W, 2=N, 4=E, 6=S) are edge-adjacent; the ODD slots
/// (1=NW, 3=NE, 5=SE, 7=SW) are corner-only diagonals. Classifying by slot is
/// exact even across face seams, where a raw `(dx, dy)` reconstruction would be
/// ambiguous.
_Adjacency _healpixAdjacency(HealpixNested healpix, int npixA, int npixB) {
  if (npixA == npixB) return _Adjacency.none;
  final neighbours = healpix.neighboursNest(npixA);
  final slot = neighbours.indexOf(npixB);
  if (slot < 0) return _Adjacency.none;
  // Even compass slots (W/N/E/S) are edge neighbours; odd (NW/NE/SE/SW) diagonal.
  return slot.isEven ? _Adjacency.edge : _Adjacency.diagonal;
}
