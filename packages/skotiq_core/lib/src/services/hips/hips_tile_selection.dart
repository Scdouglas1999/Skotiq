// Norder selection + visible-tile-set computation for the Flutter-side GPU
// HiPS framing tile layer (component C3).
//
// This is the pure-Dart "what do I draw, and where" brain of the tile layer.
// It answers the two questions the framing tile painter asks every time the
// view changes:
//
//   1. *Which HiPS resolution level* (`Norder`) matches the on-screen pixel
//      scale right now? Too coarse and tiles look soft; too fine and we fetch
//      4x more tiles than the screen can resolve. [selectNorder] picks the
//      level whose native tile pixel scale is closest-but-not-coarser than the
//      screen's arcsec/pixel, clamped to the survey's published range.
//
//   2. *Which tiles at that level are visible*, and *where on the canvas does
//      each one land*? [computeVisibleTiles] runs a HEALPix disc query over the
//      field of view (covering the FOV diagonal plus a pad so tiles clipping
//      the frame edge are included) to get the candidate set, then — for each
//      tile — subdivides its curved HEALPix footprint into an N x N mesh of sky
//      points and forward-projects every mesh vertex to the canvas through the
// shared framing projection. The painter turns those screen meshes
//      into seam-free textured triangles, so tiles register to the survey
//      background and the FOV/mosaic overlay to the pixel under any
//      pan/zoom/rotation.
//
// This file owns NO I/O, NO Flutter widgets, NO Riverpod: it is pure geometry
// and arithmetic built strictly on top of:
//   * C0  — `HipsProperties` / `HipsTileId` (survey metadata + tile addressing),
//   * C1  — `HealpixNested` (sky <-> tile index, cell boundaries, disc query),
//   * C2  — `FramingSkyProjection` / `FramingPlateScale` (sky <-> screen).
// so it is fully unit-testable in isolation and reused unchanged by both the
// framing tile painter and any verification/golden harness.
//
// References for the level-of-detail rule:
//   * IVOA "HiPS - Hierarchical Progressive Survey" Recommendation 1.0
//     (2017-05-19), §4.1: at `Norder` the sphere has `12 * 4^Norder` tiles and
//     a tile is `hips_tile_width` px square, so a tile's angular pixel scale is
//     `(sky area per tile / tile_width^2)`.
//   * Aladin Lite's renderer chooses the order whose tile texel scale matches
//     the screen, using the well-known constant that a `512`-px HiPS tile at
//     `Norder` k subtends about `2.0148 / (2^k) * 512` arcsec across — i.e. the
//     per-texel arcsec scale halves each order. The `412`-arcsec reference in
//     [selectNorder] is the standard "tilepix" constant (the arcsec/px of the
//     order-0 / Nside=1 base tile divided down) used by Aladin and hips2fits to
//     map a target arcsec/px onto a HiPS order.

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import '../../models/framing_hips_projection.dart';
import '../../models/framing_plate_scale.dart';
import '../../models/hips/hips_properties.dart';
import '../../models/hips/hips_tile_id.dart';
import '../../providers/framing_provider.dart' show FramingTarget;
import 'healpix_nested.dart';

/// Raised when tile selection is asked to do something geometrically
/// impossible — a degenerate plate scale, an out-of-range subdivision, an order
/// outside the survey's published range. A miswired caller fails here rather
/// than painting a blank or wrong sky.
class HipsTileSelectionError extends ArgumentError {
  /// Creates a tile-selection argument error.
  HipsTileSelectionError(super.message);
}

/// One screen-space vertex of a tile's projected mesh.
///
/// [u] and [v] are the *normalized* texture coordinates within the tile image
/// in `[0, 1]` (`u` rightward, `v` downward, matching image pixel convention),
/// and [screen] is where that texel lands on the canvas. The painter feeds
/// these straight into `Canvas.drawVertices` / a textured-triangle mesh: the
/// `screen` points become the vertex positions and `(u * tileWidth, v *
/// tileWidth)` the texture coordinates.
class HipsMeshVertex {
  /// Normalized horizontal texture coordinate within the tile image, `[0, 1]`.
  final double u;

  /// Normalized vertical texture coordinate within the tile image, `[0, 1]`.
  final double v;

  /// Right ascension of this vertex, in hours.
  final double raHours;

  /// Declination of this vertex, in degrees.
  final double decDegrees;

  /// On-screen position of this vertex, in logical pixels.
  final Offset screen;

  const HipsMeshVertex({
    required this.u,
    required this.v,
    required this.raHours,
    required this.decDegrees,
    required this.screen,
  });

  @override
  String toString() =>
      'HipsMeshVertex(u: $u, v: $v, ra: $raHours h, '
      'dec: $decDegrees deg, screen: $screen)';
}

/// A single visible HiPS tile together with the screen-space mesh the painter
/// warps its image onto.
///
/// The mesh is an [HipsTileMesh.subdivisions] x [HipsTileMesh.subdivisions]
/// lattice of [HipsMeshVertex] in row-major order (`index = row * (n+1) + col`,
/// `row`/`col` in `[0, n]`). Subdividing the curved HEALPix diamond into a fine
/// grid and projecting each vertex individually means the tile follows the
/// sky's curvature (and the field rotation) instead of being a single flat
/// quad, which is what keeps neighbouring tiles seam-free: adjacent tiles share
/// the exact same boundary sky points (from [HealpixNested.boundaries]), so
/// their projected edges coincide to the pixel.
class HipsVisibleTile {
  /// The addressed tile (survey + Norder + Npix).
  final HipsTileId id;

  /// The projected mesh for this tile.
  final HipsTileMesh mesh;

  const HipsVisibleTile({required this.id, required this.mesh});

  @override
  String toString() => 'HipsVisibleTile($id, ${mesh.subdivisions}x mesh)';
}

/// A coarse-ancestor fallback drawn under a not-yet-resident sharp tile.
///
/// The never-blank LOD strategy (anti-jank requirement #4) covers a sharp tile
/// whose image has not streamed in yet with the coarsest *resident* ancestor
/// (parent, grandparent, ...). The ancestor image is one full HiPS tile that
/// covers `4^(childNorder - ancestorNorder)` sharp cells; the child occupies
/// exactly ONE nested sub-square of it. So the painter must sample only that
/// sub-square of the ancestor image and warp it onto the child's screen mesh —
/// NOT stretch the whole ancestor image across the child footprint (which would
/// show a wrong, zoomed-out, content-shifted parent during every pan/zoom).
///
/// This value carries everything the painter needs to do that: the resident
/// [ancestorId] (which image to sample), the child's screen [mesh] (where to
/// draw), and the child's position within the ancestor as a `(subX, subY)` cell
/// in a [gridSize] x [gridSize] lattice (which sub-rect of the ancestor image to
/// sample). The mapping is identical in spirit to the packed-Allsky cell
/// sampling, but here the ancestor is a single full tile image rather than a
/// packed grid.
class HipsFallbackTile {
  /// The resident coarse ancestor tile whose image is sampled.
  final HipsTileId ancestorId;

  /// The screen-space mesh of the *sharp* child tile (where the coarse imagery
  /// is warped to). Identical to the child's primary mesh, so the fallback
  /// registers to the FOV overlay exactly like the sharp tile would.
  final HipsTileMesh mesh;

  /// The child's column within the ancestor, in `[0, gridSize)`.
  final int subX;

  /// The child's row within the ancestor, in `[0, gridSize)`.
  final int subY;

  /// The ancestor is subdivided into [gridSize] x [gridSize] descendant cells at
  /// the child's order: `gridSize = 2^(childNorder - ancestorNorder)`.
  final int gridSize;

  const HipsFallbackTile({
    required this.ancestorId,
    required this.mesh,
    required this.subX,
    required this.subY,
    required this.gridSize,
  });

  /// Decomposes a [childNpix] at [childNorder] into the resident [ancestorId]'s
  /// sub-cell, building the fallback for [childMesh].
  ///
  /// The low `2*(childNorder - ancestorId.norder)` bits of the child's NESTED
  /// index are the bit-interleaved (even→x, odd→y) intra-ancestor position, so
  /// de-interleaving them yields the `(subX, subY)` cell in the
  /// `2^(childNorder-ancestorNorder)` grid the child occupies within the
  /// ancestor — exactly the HEALPix NESTED parent/child relationship.
  factory HipsFallbackTile.fromDescent({
    required HipsTileId ancestorId,
    required int childNorder,
    required int childNpix,
    required HipsTileMesh childMesh,
  }) {
    final levels = childNorder - ancestorId.norder;
    if (levels < 0) {
      throw HipsTileSelectionError(
        'ancestor order ${ancestorId.norder} is deeper than child order '
        '$childNorder; an ancestor must be coarser than its descendant',
      );
    }
    final shift = 2 * levels;
    // The low `shift` bits address the descendant within the ancestor; the high
    // bits are the ancestor's own npix and must match ancestorId.npix.
    if ((childNpix >> shift) != ancestorId.npix) {
      throw HipsTileSelectionError(
        'npix $childNpix at Norder$childNorder is not a descendant of '
        '${ancestorId.npix} at Norder${ancestorId.norder}',
      );
    }
    final low = childNpix & ((1 << shift) - 1);
    // De-interleave the low bits: even bit positions → x, odd → y. This is the
    // same NESTED interleaving HEALPix uses for intra-face addressing.
    var subX = 0;
    var subY = 0;
    for (var bit = 0; bit < levels; bit++) {
      subX |= ((low >> (2 * bit)) & 1) << bit;
      subY |= ((low >> (2 * bit + 1)) & 1) << bit;
    }
    return HipsFallbackTile(
      ancestorId: ancestorId,
      mesh: childMesh,
      subX: subX,
      subY: subY,
      gridSize: 1 << levels,
    );
  }

  @override
  String toString() =>
      'HipsFallbackTile($ancestorId, cell ($subX,$subY)/$gridSize)';
}

/// The screen-projected mesh of one tile.
class HipsTileMesh {
  /// Number of cells per side; the vertex lattice is `(subdivisions+1)` per
  /// side. `1` means a flat quad (4 corners); higher values follow the sky's
  /// curvature more closely.
  final int subdivisions;

  /// Row-major lattice of `(subdivisions+1)^2` vertices.
  final List<HipsMeshVertex> vertices;

  const HipsTileMesh({required this.subdivisions, required this.vertices});

  /// Number of vertices per row (and per column): `subdivisions + 1`.
  int get verticesPerSide => subdivisions + 1;

  /// The vertex at lattice position `(row, col)`, both in `[0, subdivisions]`.
  HipsMeshVertex vertexAt(int row, int col) {
    final n = verticesPerSide;
    if (row < 0 || row >= n || col < 0 || col >= n) {
      throw HipsTileSelectionError(
        'mesh vertex ($row, $col) out of range for a ${n}x$n lattice',
      );
    }
    return vertices[row * n + col];
  }

  /// The axis-aligned screen bounding rectangle of all projected vertices.
  ///
  /// The painter uses this to cull tiles that project entirely off-canvas and
  /// to size an intermediate layer; it is the union of every vertex's screen
  /// position. Returns `null` only when there are no vertices (never happens
  /// for a validly built mesh), surfacing the degeneracy instead of inventing
  /// an empty rect.
  Rect? get screenBounds {
    if (vertices.isEmpty) return null;
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (final vtx in vertices) {
      final s = vtx.screen;
      if (s.dx < minX) minX = s.dx;
      if (s.dy < minY) minY = s.dy;
      if (s.dx > maxX) maxX = s.dx;
      if (s.dy > maxY) maxY = s.dy;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }
}

/// The full visible-tile computation for one frame.
///
/// Carries the selected [norder], the ordered [tiles] (each with its projected
/// mesh), and the [projection] used to build them so the painter can derive the
/// same geometry for the existing single-cutout fallback and the FOV overlay
/// without re-resolving the plate scale.
class HipsVisibleTileSet {
  /// The HiPS resolution level the tiles are addressed at.
  final int norder;

  /// Visible tiles, ordered by ascending [HealpixNested] pixel index (the
  /// deterministic order [HealpixNested.queryDisc] returns), so the painter
  /// draws and the cache keys in a stable sequence across frames.
  final List<HipsVisibleTile> tiles;

  /// The projection these tiles were computed against (shared with the survey
  /// background and overlays for pixel-exact registration).
  final FramingSkyProjection projection;

  const HipsVisibleTileSet({
    required this.norder,
    required this.tiles,
    required this.projection,
  });

  /// The ordered tile ids only, for the fetch/cache layer (which needs the
  /// addresses, not the meshes).
  List<HipsTileId> get tileIds =>
      tiles.map((t) => t.id).toList(growable: false);

  @override
  String toString() =>
      'HipsVisibleTileSet(Norder$norder, ${tiles.length} tiles)';
}

/// Pure functions for HiPS level-of-detail and visible-set selection.
///
/// Stateless: every method is `static`. Callers hold no instance; the painter
/// calls [computeVisibleTiles] each time the view changes (debounced upstream
/// in the fetch layer, not here — this layer is cheap and deterministic).
class HipsTileSelection {
  HipsTileSelection._();

  /// The "tilepix" reference constant, in arcseconds.
  ///
  /// A HiPS tile is `hips_tile_width` px square and at `Norder` k the sphere is
  /// split into `12 * 4^k` such tiles, so a single texel subtends an angle that
  /// halves each time the order increases by one. Solving for the order that
  /// makes the tile texel scale match a target arcsec/px gives
  /// `Norder = ceil(log2(reference / arcsec_per_px))`, where `reference` is the
  /// texel arcsec scale at `Norder` 0 for the publisher's tile width — i.e. the
  /// scale at which order 0 is "1:1". For the standard `512`-px tiles CDS
  /// publishes this constant is `~412` arcsec, the same value Aladin and the
  /// hips2fits service use to map a requested pixel scale to a HiPS order. It is
  /// scaled by tile width in [selectNorder] so non-`512` surveys are handled
  /// correctly rather than silently mis-levelled.
  static const double tilepixReferenceArcsec = 412.0;

  /// The tile width the [tilepixReferenceArcsec] constant is calibrated for.
  static const int referenceTileWidth = 512;

  /// Selects the HiPS [HipsProperties.hipsOrder]-bounded `Norder` whose tile
  /// texel scale best matches the current screen scale.
  ///
  /// [pixelsPerDegree] is the authoritative on-screen scale from
  /// [FramingPlateScale.pixelsPerDegree] (the same value every framing overlay
  /// uses); it is converted to arcsec/px (`3600 / pixelsPerDegree`).
  ///
  /// The rule (matching Aladin / hips2fits):
  ///
  /// ```
  /// Norder = clamp(
  ///   ceil( log2( referenceArcsec / arcsec_per_px ) ),
  ///   hips_order_min,
  ///   hips_order,
  /// )
  /// ```
  ///
  /// where `referenceArcsec` is [tilepixReferenceArcsec] rescaled for the
  /// survey's actual [HipsProperties.tileWidth] (a `1024`-px tile resolves twice
  /// as finely as a `512`-px tile at the same order, so its reference doubles).
  ///
  /// Throws [HipsTileSelectionError] when [pixelsPerDegree] is not a positive
  /// finite number — a degenerate scale must surface, never silently clamp to a
  /// guessed order.
  static int selectNorder(double pixelsPerDegree, HipsProperties props) {
    if (!pixelsPerDegree.isFinite || pixelsPerDegree <= 0.0) {
      throw HipsTileSelectionError(
        'pixelsPerDegree must be a positive finite number for Norder '
        'selection, got $pixelsPerDegree',
      );
    }

    final arcsecPerPixel = 3600.0 / pixelsPerDegree;

    // Rescale the 512-px-calibrated reference for this survey's tile width: a
    // wider tile resolves more finely at the same order, so it reaches the same
    // arcsec/px one (or more) orders earlier — the reference scales linearly
    // with tile width.
    final referenceArcsec =
        tilepixReferenceArcsec * (props.tileWidth / referenceTileWidth);

    // ceil(log2(reference / arcsec_per_px)): pick the first order whose texel
    // scale is at least as fine as the screen, never coarser (so we never paint
    // a softer-than-screen tile when a sharper one is published).
    final ratio = referenceArcsec / arcsecPerPixel;
    // log2(ratio) via natural logs. ratio is finite and > 0 here (referenceArcsec
    // > 0, arcsecPerPixel > 0), so log is well defined.
    final rawOrder = (math.log(ratio) / math.ln2).ceil();

    return rawOrder.clamp(props.hipsOrderMin, props.hipsOrder);
  }

  /// Default per-tile mesh subdivision.
  ///
  /// A HEALPix diamond at the selected order is small on screen (by
  /// construction — that is why this order was chosen), so its curvature across
  /// the tile is slight; a `4 x 4` mesh follows it well below one pixel of error
  /// for any realistic framing FOV while keeping the vertex count modest
  /// (`5 x 5 = 25` vertices per tile). Callers can override via
  /// [computeVisibleTiles]'s `subdivisions` parameter for verification renders
  /// that want a denser mesh.
  static const int defaultSubdivisions = 4;

  /// Fraction of the FOV diagonal added as a pad to the disc-query radius so
  /// tiles clipping the frame edge (and a margin for in-flight pan) are
  /// included, never leaving a blank gutter at the canvas border.
  static const double discRadiusPadFraction = 0.15;

  /// Computes the ordered set of visible tiles at [norder] for the current
  /// view, each with its screen-projected mesh.
  ///
  /// Tiles are projected through the same [FramingSkyProjection] the survey
  /// background and the FOV/mosaic overlays use, so they register to the pixel.
  /// The disc radius is the canvas DIAGONAL half-FOV (grown by
  /// [discRadiusPadFraction]), which keeps all four corners inside the disc
  /// under field rotation. Each tile's mesh is interpolated on the fractional
  /// intra-face lattice via [HealpixNested.xyfToAng], so mesh edges coincide
  /// with [HealpixNested.boundaries] and neighbouring tiles share them
  /// seam-free.
  ///
  /// [norder] must lie within the survey's published range
  /// `[hips_order_min, hips_order]` (use [selectNorder] to choose it).
  /// [subdivisions] defaults to [defaultSubdivisions]; it must be `>= 1`.
  /// [pan] and [rotationDegrees] default to no pan / no rotation so callers that
  /// only need the un-panned set (e.g. the registration golden) can omit them,
  /// while the live painter passes the framing state's pan/rotation for exact
  /// tracking.
  ///
  /// Throws [HipsTileSelectionError] for an out-of-range [norder] or
  /// [subdivisions], or a degenerate [canvasSize].
  static HipsVisibleTileSet computeVisibleTiles(
    FramingPlateScale plateScale,
    FramingTarget framingTarget,
    Size canvasSize,
    double zoom,
    int norder,
    HipsProperties props, {
    int subdivisions = defaultSubdivisions,
    Offset pan = Offset.zero,
    double rotationDegrees = 0.0,
    String? surveyId,
  }) {
    // The whole pipeline (HEALPix npix -> RA/Dec, mesh sky points, the FOV
    // overlay) treats the survey's tiling as EQUATORIAL: the framing target's
    // equatorial RA/Dec is fed straight into HealpixNested.ang2pixNest /
    // queryDisc. A galactic- or ecliptic-framed survey would be addressed with
    // the wrong pixel indices and the mesh sky points would be in the survey's
    // frame but reprojected as if equatorial — total misregistration with the
    // equatorial FOV overlay, with no error. Until a frame->equatorial rotation
    // is implemented, a non-equatorial survey is rejected loudly here rather
    // than silently consumed and mis-projected.
    if (props.frame != HipsFrame.equatorial) {
      throw HipsTileSelectionError(
        'HiPS survey frame ${props.frame.wireValue} is not supported by the '
        'framing tile layer: tile selection assumes an equatorial tiling and '
        'has no ${props.frame.wireValue}->equatorial rotation, so consuming it '
        'would silently misregister the mosaic against the equatorial FOV '
        'overlay. Only ${HipsFrame.equatorial.wireValue} surveys are accepted.',
      );
    }
    if (norder < props.hipsOrderMin || norder > props.hipsOrder) {
      throw HipsTileSelectionError(
        'Norder $norder is outside the survey published range '
        '[${props.hipsOrderMin}, ${props.hipsOrder}]',
      );
    }
    if (norder < 0 || norder > HealpixNested.maxOrder) {
      throw HipsTileSelectionError(
        'Norder $norder is outside the HEALPix supported range '
        '[0, ${HealpixNested.maxOrder}]',
      );
    }
    if (subdivisions < 1) {
      throw HipsTileSelectionError(
        'subdivisions must be >= 1, got $subdivisions',
      );
    }
    if (canvasSize.isEmpty ||
        canvasSize.width <= 0 ||
        canvasSize.height <= 0 ||
        !canvasSize.width.isFinite ||
        !canvasSize.height.isFinite) {
      throw HipsTileSelectionError(
        'canvasSize must be a positive finite size, got $canvasSize',
      );
    }

    final projection = FramingSkyProjection.fromResolved(
      plateScale: plateScale,
      canvasSize: canvasSize,
      centerRaHours: framingTarget.raHours,
      centerDecDegrees: framingTarget.decDegrees,
      zoom: zoom,
      pan: pan,
      rotationDegrees: rotationDegrees,
    );

    final radiusDeg = _discRadiusDeg(projection);

    final healpix = HealpixNested(norder);
    final centerDecDeg = framingTarget.decDegrees;
    final centerRaDeg = _normalizeRaDegrees(framingTarget.raHours * 15.0);

    final pixels = healpix.queryDisc(
      centerRaDeg,
      centerDecDeg,
      radiusDeg: radiusDeg,
      inclusive: true,
    );

    // The survey id keying the tile cache. Defaults to the survey's canonical
    // HiPS id is not knowable from props alone, so callers that share a cache
    // pass it explicitly; otherwise fall back to a stable per-order key so the
    // tile ids are still valid and self-consistent within this set.
    final survey = (surveyId != null && surveyId.isNotEmpty)
        ? surveyId
        : 'hips:order$norder';

    final tiles = <HipsVisibleTile>[];
    for (final npix in pixels) {
      final id = HipsTileId(survey: survey, norder: norder, npix: npix);
      final mesh = _buildMesh(healpix, npix, subdivisions, projection);
      tiles.add(HipsVisibleTile(id: id, mesh: mesh));
    }

    return HipsVisibleTileSet(
      norder: norder,
      tiles: List.unmodifiable(tiles),
      projection: projection,
    );
  }

  /// The disc-query radius in degrees: the diagonal half-FOV grown by
  /// [discRadiusPadFraction].
  ///
  /// The FOV is read from the projection's arcsec/px so it tracks zoom exactly:
  /// `fov_deg = canvas_dimension_px / pixelsPerDegree`. The diagonal is
  /// `hypot(widthDeg, heightDeg)`; the *radius* is half of that, padded. This is
  /// the radius that guarantees the canvas corners (the worst case under
  /// rotation) fall inside the disc.
  static double _discRadiusDeg(FramingSkyProjection projection) {
    final pxPerDeg = projection.pixelsPerDegree;
    if (!pxPerDeg.isFinite || pxPerDeg <= 0.0) {
      throw HipsTileSelectionError(
        'projection pixelsPerDegree is degenerate ($pxPerDeg); cannot derive a '
        'field-of-view radius for the tile disc query',
      );
    }
    final widthDeg = projection.canvasSize.width / pxPerDeg;
    final heightDeg = projection.canvasSize.height / pxPerDeg;
    final diagonalDeg = math.sqrt(widthDeg * widthDeg + heightDeg * heightDeg);
    final radius = diagonalDeg / 2.0 * (1.0 + discRadiusPadFraction);
    // A spherical cap radius is meaningless beyond 180 degrees; clamp to the
    // full sphere so an extreme zoom-out (whole-sky FOV) still queries every
    // tile rather than throwing on an over-large cap.
    return radius.clamp(0.0, 180.0);
  }

  /// Builds the `subdivisions x subdivisions` projected mesh for tile [npix].
  ///
  /// The HEALPix diamond at [npix] occupies the integer intra-face cell
  /// `[ix, ix+1] x [iy, iy+1]` on its face. We sample the *fractional*
  /// intra-face lattice at `subdivisions + 1` points per side via
  /// [HealpixNested.xyfToAng] (the exact same routine [HealpixNested.boundaries]
  /// uses for the four corners), so:
  ///   * the four mesh corners are byte-identical to [HealpixNested.boundaries],
  ///     hence identical to the neighbour's shared corners — seam-free;
  ///   * interior vertices follow the cell's curvature on the sphere.
  /// Each lattice sky point is then forward-projected to the canvas via C2.
  static HipsTileMesh _buildMesh(
    HealpixNested healpix,
    int npix,
    int subdivisions,
    FramingSkyProjection projection,
  ) {
    final xyf = healpix.nestToXyf(npix);
    final ix = xyf.x; // integer-valued double in [0, Nside)
    final iy = xyf.y;
    final face = xyf.face;
    final n = subdivisions;
    final inv = 1.0 / n;

    final vertices = <HipsMeshVertex>[];
    // Row-major: row steps the intra-face iy axis (v), col steps ix (u); both
    // 0..1 across the cell. This (u, v) lattice is a stable parameterisation of
    // the diamond keyed to its HEALPix corners ((u,v)=(0,0)->south, (1,0)->east,
    // (0,1)->west, (1,1)->north). It deliberately carries NO assumption about how
    // the tile *image* pixels are laid out relative to (u, v): the painter owns
    // the verified image convention (`HipsTileLayerPainter._emitVertex` samples
    // image (tx=v, ty=u) — a pure transpose, established against real DSS2 tile
    // content by the seam-continuity test, NOT the IVOA spec text). Keeping the
    // sky lattice and the (u, v) lattice consistent here is all this routine must
    // guarantee for the painter to map content seamlessly.
    for (var row = 0; row <= n; row++) {
      final fy = iy + row * inv;
      final v = row * inv;
      for (var col = 0; col <= n; col++) {
        final fx = ix + col * inv;
        final u = col * inv;
        final ang = healpix.xyfToAng(HealpixXyf(fx, fy, face));
        final raHours = _normalizeRaHours(ang.raDeg / 15.0);
        final decDeg = ang.decDeg;
        final screen = projection.raDecToScreen(raHours, decDeg);
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
      subdivisions: subdivisions,
      vertices: List.unmodifiable(vertices),
    );
  }

  /// Normalizes RA degrees into `[0, 360)`.
  static double _normalizeRaDegrees(double raDeg) {
    var r = raDeg % 360.0;
    if (r < 0) r += 360.0;
    return r;
  }

  /// Normalizes RA hours into `[0, 24)`.
  static double _normalizeRaHours(double raHours) {
    var r = raHours % 24.0;
    if (r < 0) r += 24.0;
    return r;
  }
}
