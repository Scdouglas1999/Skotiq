// Geometry bridge between the planetarium's sky projection and the HiPS tile
// pyramid — the part of the sky-imagery layer that decides *where on the
// planetarium canvas* each survey tile lands.
//
// ## Why this file exists at all
//
// skotiq_core already owns a complete, tested HiPS stack: HEALPix indexing,
// LOD selection, tile fetch/decode, a bounded LRU cache, and a debounced loader
// that turns a moving viewport into a never-blank set of resident tiles. All of
// that is reused verbatim here.
//
// One piece is not reusable: `HipsTileSelection.computeVisibleTiles` builds its
// screen meshes by constructing a `FramingSkyProjection` *internally*, from the
// framing screen's plate scale. It exposes no seam for an arbitrary projection
// function. The planetarium does not use that projection — it uses
// `SkyCanvasPainter`'s (mirrored publicly by [SkyFovProjector]), which is a
// different family of projections entirely: stereographic / orthographic /
// azimuthal-equidistant, optionally in the alt-az frame, with a view rotation.
// Feeding framing-projected meshes into the planetarium would put the imagery
// in visibly the wrong place — the very failure mode that makes an overlay
// worse than no overlay.
//
// So this file re-derives ONE thing — the per-tile screen mesh — through
// [SkyFovProjector], and reuses everything else. It deliberately mirrors
// `HipsTileSelection._buildMesh` vertex-for-vertex (same fractional intra-face
// lattice, same `(u, v)` parameterisation, same [HealpixNested.xyfToAng] call)
// so that the painter's verified tile-image transpose (`tx = v, ty = u`) stays
// valid and neighbouring tiles keep sharing byte-identical boundary sky points,
// i.e. stay seam-free.
//
// ## What is reused, unchanged
//
//   * [HealpixNested] — sky <-> tile index and the fractional cell lattice.
//   * [HipsTileSelection.selectNorder] — the LOD rule.
//   * `HipsTileLoader` / `HipsTileCache` / `HipsTileFetcher` (via the C7
//     providers) — the one and only fetch + residency path. There is no second
//     cache here; [reproject] reads the loader's own cache snapshot.
//   * `HipsTileLayerPainter` — the GPU compositor, fed a rebuilt snapshot.
//
// Pure Dart + `dart:ui` geometry: no widgets, no Riverpod, no I/O, so the
// registration test can drive it directly.

import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:skotiq_core/skotiq_core.dart'
    show HealpixNested, HealpixXyf, HipsProperties, HipsTileId;
// FramingPlateScale and the HiPS selection/loader value types live in
// skotiq_core's src layer and are intentionally not surfaced through the
// public barrel (they are app->core src-model types shared with the framing
// tile layer), so they are imported directly here, matching the established
// convention in `screens/framing/painters/hips_tile_layer_painter.dart`.
// ignore: implementation_imports
import 'package:skotiq_core/src/models/framing_plate_scale.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_cache.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_loader.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_selection.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// The planetarium view pose resolved into everything the imagery layer needs:
/// the projector the stars are drawn with, the equatorial centre of the canvas,
/// and the on-screen angular scale.
///
/// Built once per frame from the live [SkyViewState] and handed to both halves
/// of the layer — the half that asks the loader for tiles (which needs a sky
/// centre and a scale) and the half that draws them (which needs the projector
/// itself). Sharing one value is what keeps "what we fetched" and "where we
/// drew it" describing the same view.
class PlanetariumSkyProjection {
  /// The projector, term-for-term identical to the sky painter's own geometry.
  final SkyFovProjector projector;

  /// Logical canvas size the projector was built for.
  final Size canvasSize;

  /// Equatorial coordinate at the centre of the canvas.
  ///
  /// Obtained by *unprojecting* the canvas centre rather than reading
  /// [SkyViewState.centerRA] / [SkyViewState.centerDec] directly, because in
  /// [SkyViewMode.horizontal] the view is centred on an alt/az pose and its
  /// equatorial centre depends on sidereal time. Unprojecting handles both
  /// frames with one code path, and in the equatorial frame it returns exactly
  /// the view centre.
  final CelestialCoordinate center;

  const PlanetariumSkyProjection({
    required this.projector,
    required this.canvasSize,
    required this.center,
  });

  /// On-screen logical pixels per degree of sky (short canvas axis).
  double get pixelsPerDegree => projector.pixelsPerDegree;

  /// Resolves the projection for a pose, or null when the pose cannot place a
  /// fixed sky coordinate at all.
  ///
  /// Returns null (draw nothing) rather than guessing when the canvas is not
  /// laid out, the field of view is degenerate, or the alt-az frame is active
  /// without a site — the same "draw nothing rather than garbage" rule the FOV
  /// overlay follows.
  ///
  /// [latitude] is null when no observing site is on record. It is only read in
  /// the horizontal frame, which is exactly the frame that cannot be placed
  /// without one.
  static PlanetariumSkyProjection? resolve({
    required SkyViewState viewState,
    required Size canvasSize,
    required double? latitude,
    double? lstHours,
  }) {
    if (canvasSize.isEmpty ||
        !canvasSize.width.isFinite ||
        !canvasSize.height.isFinite) {
      return null;
    }
    if (!viewState.fieldOfView.isFinite || viewState.fieldOfView <= 0) {
      return null;
    }
    if (viewState.viewMode == SkyViewMode.horizontal && latitude == null) {
      return null;
    }

    final projector = SkyFovProjector.forSize(
      viewState,
      canvasSize,
      latitude: latitude ?? 0,
      lstHours: lstHours,
    );
    if (!projector.canProjectSkyCoordinates) return null;
    if (!projector.pixelsPerDegree.isFinite || projector.pixelsPerDegree <= 0) {
      return null;
    }

    final center = projector.unproject(projector.screenCenter);
    if (center == null) return null;

    return PlanetariumSkyProjection(
      projector: projector,
      canvasSize: canvasSize,
      center: center,
    );
  }
}

/// Turns the planetarium's view pose into HiPS tile geometry.
///
/// Stateless: every member is `static`. The layer widget calls
/// [plateScaleFor] + [selectNorder] to drive the shared loader, and [reproject]
/// to turn the loader's resident snapshot into one the painter can draw at the
/// planetarium's own projection.
class PlanetariumSkyTiles {
  PlanetariumSkyTiles._();

  /// Per-tile mesh subdivision.
  ///
  /// Matches [HipsTileSelection.defaultSubdivisions]. A 4x4 mesh (25 vertices)
  /// tracks a selected-order HEALPix diamond's curvature to well under a pixel
  /// at any field the layer is active at, and at a few dozen visible tiles that
  /// is under a thousand projections per frame — far below the cost of the star
  /// pass it sits behind.
  static const int defaultSubdivisions = HipsTileSelection.defaultSubdivisions;

  /// Synthesises the [FramingPlateScale] that makes the shared HiPS loader
  /// compute *the planetarium's* level of detail and *the planetarium's* field
  /// of view.
  ///
  /// The loader (and the selection code underneath it) is parameterised on the
  /// framing screen's plate-scale value object. Only two scalars actually reach
  /// the decisions this layer depends on:
  ///
  ///   * `pixelsPerDegree(canvasSize, zoom)` -> which Norder to fetch;
  ///   * `canvasSize / pixelsPerDegree` -> the disc-query radius, i.e. which
  ///     tiles are in the field.
  ///
  /// Both are reproduced exactly here by describing a virtual "survey image"
  /// with the canvas's own pixel dimensions and the angular size the
  /// planetarium is currently showing. The meshes the loader then builds are
  /// discarded and rebuilt by [reproject] through the real sky projector, so
  /// nothing about the framing projection survives into what is drawn — this
  /// shim exists only to address the right tiles at the right depth.
  ///
  /// Verified by construction and pinned by test: the returned scale satisfies
  /// `pixelsPerDegree(canvasSize, 1.0) == pixelsPerDegree`.
  static FramingPlateScale plateScaleFor(
    Size canvasSize,
    double pixelsPerDegree,
  ) {
    final widthPx = math.max(1, canvasSize.width.round());
    final heightPx = math.max(1, canvasSize.height.round());

    // Probe the fit-to-canvas rule with a unit angular size to learn the drawn
    // width this aspect ratio produces, then choose the angular width that maps
    // that drawn width onto exactly `pixelsPerDegree`.
    final probe = FramingPlateScale(
      surveyFovWidthDeg: 1,
      surveyFovHeightDeg: 1,
      imagePixelWidth: widthPx,
      imagePixelHeight: heightPx,
    );
    final drawnWidth = probe.drawSizeFor(canvasSize, 1.0).width;
    final fovWidthDeg = drawnWidth / pixelsPerDegree;

    return FramingPlateScale(
      surveyFovWidthDeg: fovWidthDeg,
      surveyFovHeightDeg: fovWidthDeg * heightPx / widthPx,
      imagePixelWidth: widthPx,
      imagePixelHeight: heightPx,
    );
  }

  /// Rebuilds one tile's screen mesh at the planetarium's projection.
  ///
  /// Mirrors `HipsTileSelection._buildMesh` exactly except for the final
  /// projection step: the HEALPix cell at [npix] is sampled on the same
  /// fractional intra-face lattice, in the same row-major `(u, v)` order, via
  /// the same [HealpixNested.xyfToAng] used to generate cell boundaries — so
  /// adjacent tiles still share byte-identical edge sky points (seam-free), and
  /// the painter's verified `(u, v) -> image` transpose still applies.
  ///
  /// Returns null when any vertex cannot be projected (behind the projection
  /// plane, or outside the projectable disc). The caller drops the whole tile:
  /// a partially-projected mesh would smear the tile across the canvas, and a
  /// missing tile at the very edge of the field is invisible next to drawing
  /// something wrong.
  static HipsTileMesh? buildMesh({
    required HealpixNested healpix,
    required int npix,
    required SkyFovProjector projector,
    int subdivisions = defaultSubdivisions,
  }) {
    final xyf = healpix.nestToXyf(npix);
    final ix = xyf.x;
    final iy = xyf.y;
    final face = xyf.face;
    final n = subdivisions;
    final inv = 1.0 / n;

    final vertices = <HipsMeshVertex>[];
    for (var row = 0; row <= n; row++) {
      final fy = iy + row * inv;
      final v = row * inv;
      for (var col = 0; col <= n; col++) {
        final fx = ix + col * inv;
        final u = col * inv;
        final ang = healpix.xyfToAng(HealpixXyf(fx, fy, face));
        final raHours = _normalizeRaHours(ang.raDeg / 15.0);
        final decDeg = ang.decDeg;
        final screen = projector.projectRaDec(raHours, decDeg);
        if (screen == null) return null;
        vertices.add(
          HipsMeshVertex(
            u: u,
            v: v,
            raHours: raHours,
            decDegrees: decDeg,
            screen: screen,
          ),
        );
      }
    }

    return HipsTileMesh(
      subdivisions: n,
      vertices: List<HipsMeshVertex>.unmodifiable(vertices),
    );
  }

  /// Rebuilds [source] — the shared loader's resident snapshot, whose meshes
  /// are in framing-projection space — into a snapshot the painter can draw at
  /// the planetarium's projection.
  ///
  /// What is taken from [source] and what is recomputed:
  ///
  ///   * TAKEN: which tiles are in the field ([HipsResidentSnapshot.visibleSet]
  ///     tile ids), the decoded images
  ///     ([HipsResidentSnapshot.cacheSnapshot]) and the Allsky base. Those are
  ///     the loader's job and are projection-independent, so the drawn set can
  ///     never contain a tile the loader did not ask for.
  ///   * RECOMPUTED: every screen mesh, and therefore the primary/fallback
  ///     classification (which follows residency, not geometry, but is rebuilt
  ///     alongside so the fallback carries the *new* mesh).
  ///
  /// [version] becomes the returned snapshot's version. It must strictly
  /// increase whenever either the loader's snapshot OR the view pose changes,
  /// because `HipsTileLayerPainter.shouldRepaint` compares exactly that
  /// integer: a pose change that did not bump it would leave the imagery
  /// painted at the previous pose while the stars moved.
  ///
  /// Returns [HipsResidentSnapshot.empty] when there is nothing to draw.
  static HipsResidentSnapshot reproject({
    required HipsResidentSnapshot source,
    required SkyFovProjector projector,
    required HipsProperties props,
    required String surveyId,
    required int version,
  }) {
    final visibleSet = source.visibleSet;
    if (visibleSet == null || visibleSet.tiles.isEmpty) {
      return HipsResidentSnapshot.empty;
    }

    final norder = visibleSet.norder;
    if (norder < 0 || norder > HealpixNested.maxOrder) {
      return HipsResidentSnapshot.empty;
    }
    final healpix = HealpixNested(norder);

    final tiles = <HipsVisibleTile>[];
    final primary = <HipsVisibleTile>[];
    final fallback = <HipsFallbackTile>[];

    for (final tile in visibleSet.tiles) {
      final mesh = buildMesh(
        healpix: healpix,
        npix: tile.id.npix,
        projector: projector,
      );
      if (mesh == null) continue; // Not placeable in this view; drop it.

      final reprojected = HipsVisibleTile(id: tile.id, mesh: mesh);
      tiles.add(reprojected);

      if (source.cacheSnapshot.contains(tile.id)) {
        primary.add(reprojected);
        continue;
      }
      final coarse = _coarsestResidentAncestor(
        tile: reprojected,
        cacheSnapshot: source.cacheSnapshot,
        surveyId: surveyId,
        minOrder: props.hipsOrderMin,
      );
      if (coarse != null) fallback.add(coarse);
    }

    if (tiles.isEmpty) return HipsResidentSnapshot.empty;

    return HipsResidentSnapshot(
      version: version,
      selectedNorder: norder,
      primaryTiles: List<HipsVisibleTile>.unmodifiable(primary),
      fallbackTiles: List<HipsFallbackTile>.unmodifiable(fallback),
      allsky: source.allsky,
      cacheSnapshot: source.cacheSnapshot,
      // The painter reads only `norder` and `tiles` off the visible set (to
      // slice the packed Allsky per visible mesh); the `projection` field is
      // carried through untouched because nothing downstream reads it, and
      // fabricating a framing projection the planetarium does not use would be
      // a lie in the data.
      visibleSet: HipsVisibleTileSet(
        norder: norder,
        tiles: List<HipsVisibleTile>.unmodifiable(tiles),
        projection: visibleSet.projection,
      ),
      // Fetch failures stay the loader's to report; this layer degrades to the
      // star chart rather than surfacing them, because an observatory laptop on
      // an isolated LAN is the normal case, not an error.
      failures: const [],
    );
  }

  /// Walks up the HEALPix pyramid from [tile] to the coarsest resident
  /// ancestor, pairing the *reprojected* child mesh with the ancestor's
  /// sub-cell so the painter samples the correct region of the coarse image.
  ///
  /// Identical in shape to the loader's own ancestor walk; it must be redone
  /// here only because the mesh it pairs with is the reprojected one.
  static HipsFallbackTile? _coarsestResidentAncestor({
    required HipsVisibleTile tile,
    required HipsTileCacheSnapshot cacheSnapshot,
    required String surveyId,
    required int minOrder,
  }) {
    var order = tile.id.norder - 1;
    var npix = tile.id.npix >> 2;
    while (order >= minOrder && order >= 0) {
      final ancestorId = HipsTileId(
        survey: surveyId,
        norder: order,
        npix: npix,
      );
      if (cacheSnapshot.contains(ancestorId)) {
        return HipsFallbackTile.fromDescent(
          ancestorId: ancestorId,
          childNorder: tile.id.norder,
          childNpix: tile.id.npix,
          childMesh: tile.mesh,
        );
      }
      order--;
      npix >>= 2;
    }
    return null;
  }

  /// Normalizes RA hours into `[0, 24)` — the same wrap the core mesh builder
  /// applies, so the two produce identical vertex coordinates.
  static double _normalizeRaHours(double raHours) {
    var r = raHours % 24.0;
    if (r < 0) r += 24.0;
    return r;
  }
}

/// Convenience: the screen point [projector] places `(raHours, decDeg)` at, for
/// callers that hold a projection rather than a projector.
extension PlanetariumSkyProjectionPoint on PlanetariumSkyProjection {
  /// Projects an RA (hours) / Dec (degrees) pair, or null when unplaceable.
  Offset? project(double raHours, double decDeg) =>
      projector.projectRaDec(raHours, decDeg);
}
