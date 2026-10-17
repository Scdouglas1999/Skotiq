// Component C8 (painter half) — the Flutter-side GPU HiPS framing tile painter.
//
// This is the *compositor* of the Flutter-side HiPS framing tile layer. It
// takes the immutable, versioned [HipsResidentSnapshot] the C6 loader produced
// (resident decoded tiles, each with the screen-space mesh C3 projected through
// the shared framing projection) and draws them into the framing canvas — into
// the *exact same* canvas coordinate space the survey-image background and the
// FOV/mosaic overlays use, so the tiles register to the overlays to the pixel
// at every zoom/pan/rotation.
//
// ## Why this is its own painter, not part of FramingSurveyImagePainter
//
// The single-cutout survey background draws one [ui.Image] into one
// `drawImageRect`. A HiPS view is a *mosaic* of many small tiles, each a curved
// HEALPix diamond that must follow the sky's curvature and the field rotation —
// a single flat quad per tile would leave visible seams between neighbours and
// bow the imagery at wide FOV. So each tile is drawn as a fine textured
// triangle **mesh** (`drawVertices`), warping its image onto the projected sky
// footprint C3 computed. Adjacent tiles share byte-identical boundary sky points
// (C3 builds the mesh from the same HEALPix boundary routine), so their
// projected edges coincide and the mosaic is seam-free.
//
// ## The anti-jank contract this painter upholds (by item)
//
//  4. **Never blank.** The painter draws, bottom to top: (a) the Allsky
//     whole-sky base, (b) the coarse *fallback* tiles (a resident lower-order
//     ancestor stretched across a not-yet-loaded sharp tile's footprint), then
//     (c) the sharp *primary* tiles on top. A region whose sharp tile is still
//     streaming therefore shows a softer coarse tile (or the Allsky), never
//     black. When the snapshot has no imagery at all the painter draws nothing
//     and the layer is fully transparent, so the framing canvas's existing
//     single survey snapshot / starfield shows through underneath — the
//     outermost never-blank fallback.
//  5. **Seam-free.** Mesh vertices come straight from C3 (shared HEALPix
//     boundaries); this painter never re-derives geometry, so neighbours stay
//     gapless. A 1px overdraw inset on the texture sampling avoids edge-bleed
//     halos from neighbouring tiles packed in an atlas-less decode while keeping
//     the *position* mesh exact.
//  6. **GPU compositing only.** Every pixel is moved by `Canvas.drawVertices`
//     (textured triangles uploaded to the GPU) with [FilterQuality.high] — the
//     sharp tiles, the coarse fallback ancestors, AND the coarse Allsky cells
//     all draw through the same mesh path. There is no per-frame CPU pixel work,
//     no `getBytes`, no software blend.
//  7. **Registration.** Every layer is a textured mesh whose vertices C3 already
//     projected through the shared framing projection — which bakes in pan,
//     zoom and rotation about the canvas centre, identically to the survey
//     background and the FOV/mosaic overlays. So the painter draws the meshes
//     *verbatim* and never applies its own canvas transform; re-rotating would
//     double-apply the field rotation and de-register the tiles. Even the coarse
//     Allsky base is sampled per visible cell and warped onto the *same* visible
//     meshes, so it too registers to the FOV overlay rather than being a
//     meaningless full-image stretch.
//
// `shouldRepaint` is gated on the cheap snapshot [HipsResidentSnapshot.version]
// (a monotonic integer the loader bumps on every meaningful change — including
// every view movement, which produces a new snapshot with fresh meshes), so a
// stationary view with no new tiles does not repaint, and a one-tile arrival or
// a pan/zoom/rotate repaints exactly once.
//
// This painter performs NO I/O, NO fetching, NO Riverpod reads: it is handed a
// finished snapshot and paints it. It is therefore trivially unit-testable by
// replaying it into a recording canvas (see the C8 painter test) to assert tile
// destination geometry registers against the FOV overlay rect.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
// The HiPS resident-snapshot + visible-tile/mesh types live in skotiq_core's
// services/models layer and are intentionally not surfaced through the public
// barrel (they are app->core src-model types shared with the framing tile
// layer), so they are imported directly here, matching the established
// `framing_plate_scale` / `framing_background_painters` convention in this
// package.
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_loader.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_selection.dart';

/// Paints a resident HiPS tile mosaic into the framing canvas, registered to the
/// shared [FramingPlateScale]/projection so the tiles line up with the survey
/// background and the FOV/mosaic overlays to the pixel.
///
/// The painter is a pure function of its inputs: the [snapshot] (what to draw,
/// produced by the C6 loader) and the survey [allskyOrder] used to address the
/// correct Allsky cell per visible mesh. The per-tile meshes (primary, fallback
/// and Allsky-base) already encode pan + rotation about the canvas centre (C3
/// projected them through the rotated framing projection), so this painter draws
/// them verbatim and never re-applies a transform — re-rotating would
/// double-apply the field rotation.
///
/// It draws nothing — leaving the layer transparent — when [snapshot] carries no
/// imagery, so the framing canvas's existing single survey snapshot / starfield
/// remains the outermost never-blank fallback underneath this layer.
class HipsTileLayerPainter extends CustomPainter {
  /// The resident-tile snapshot to composite. Borrowed for this frame only; its
  /// [HipsResidentSnapshot.cacheSnapshot] images are valid for the paint pass.
  final HipsResidentSnapshot snapshot;

  /// The survey's HEALPix order the Allsky whole-sky map is published at
  /// ([HipsProperties.allskyOrder] — the conventional whole-sky order, NOT
  /// `hips_order_min`). The Allsky packs every tile at this order into one image;
  /// the painter slices the correct cell per visible mesh and warps it onto that
  /// mesh, so the coarse base is geometrically registered (never a meaningless
  /// full-image stretch). This MUST be the same order the loader fetched the
  /// Allsky at, or the cell indices would not line up.
  final int allskyOrder;

  HipsTileLayerPainter({
    required this.snapshot,
    required this.allskyOrder,
  });

  /// 1px texture-coordinate inset applied to each tile's interior sampling to
  /// avoid edge bleed from a neighbouring cell when the decoded tile carries a
  /// hair of a neighbour at its border. The *position* mesh is never inset (that
  /// would open seams); only the sampled `uv` rectangle is nudged inward.
  static const double _textureInsetPx = 1.0;

  @override
  void paint(Canvas canvas, Size size) {
    // Clip to the canvas so a tile whose mesh projects partly off-screen never
    // paints into the surrounding chrome.
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    // 1) Coarsest base: the Allsky whole-sky map, sliced per visible cell and
    //    warped onto the visible meshes, so a freshly-targeted view is never
    //    blank even before any individual tile or coarse ancestor has loaded.
    _paintAllskyCells(canvas);

    // 2) Coarse fallback tiles (a resident lower-order ancestor), under the
    //    sharp layer. Each fallback samples ONLY the sub-cell of the ancestor
    //    image that the sharp child occupies (not the whole ancestor squashed
    //    into the child footprint), so the coarse imagery is correctly
    //    registered to the sky under the streaming sharp tile.
    for (final fallback in snapshot.fallbackTiles) {
      final image = snapshot.cacheSnapshot[fallback.ancestorId];
      if (image != null) _paintFallback(canvas, fallback, image);
    }

    // 3) Sharp primary tiles at the selected Norder, on top.
    for (final tile in snapshot.primaryTiles) {
      final image = snapshot.cacheSnapshot[tile.id];
      if (image != null) _paintMesh(canvas, tile.mesh, image);
    }

    canvas.restore();
  }

  /// Draws the Allsky whole-sky thumbnail as the coarse base layer by slicing
  /// the correct packed cell for each visible tile's [allskyOrder] ancestor and
  /// warping that sub-image onto the visible tile's mesh.
  ///
  /// The HiPS Allsky map (IVOA HiPS 1.0 §4.6) packs all `12 * 4^k` tiles at
  /// order *k* into one image laid out as a grid `nbTilesPerLine` cells wide,
  /// where `nbTilesPerLine = floor(sqrt(12 * 4^k))`; the tile with NESTED index
  /// `npix` occupies column `npix % nbTilesPerLine`, row `npix ~/ nbTilesPerLine`
  /// and each cell is `allskyWidth / nbTilesPerLine` px square. Sampling the
  /// right cell (not the whole image) is what makes the coarse base register
  /// with the sharp meshes drawn on top.
  void _paintAllskyCells(Canvas canvas) {
    final allsky = snapshot.allsky;
    final visibleSet = snapshot.visibleSet;
    if (allsky == null || visibleSet == null) return;

    final selectedNorder = visibleSet.norder;
    // The Allsky must be one or more orders *coarser* than (or equal to) the
    // selected order for an ancestor mapping to exist; the loader fetches it at
    // the survey min order, so this holds. If somehow it does not, skip rather
    // than mis-sample.
    if (allskyOrder > selectedNorder) return;

    final nbTilesPerLine = _allskyTilesPerLine(allskyOrder);
    if (nbTilesPerLine <= 0) return;
    // The HiPS Allsky (IVOA HiPS 1.0 §4.6) packs the `12 * 4^k` order-k tiles into
    // a grid that is `nbTilesPerLine` cells WIDE but
    // `ceil(numberOfTiles / nbTilesPerLine)` cells TALL — it is NOT square,
    // because `nbTilesPerLine = floor(sqrt(numberOfTiles))` rarely divides the
    // tile count evenly (e.g. order 3: 768 tiles -> 27 wide x 29 tall, last row
    // partly empty). The cells themselves are square. Deriving the cell HEIGHT
    // from the true row count (not `nbTilesPerLine`) is essential: dividing the
    // image height by `nbTilesPerLine` instead would make every cell ~7% too tall
    // and drift the sampled row-origin downward by `row * (excess)` px, so a
    // high-row tile's coarse base samples the wrong sky and the Allsky mosaic
    // appears shifted (up-and-to-the-side) from the registered sharp tiles and
    // the FOV overlay.
    final nbRows = _allskyRows(allskyOrder, nbTilesPerLine);
    if (nbRows <= 0) return;
    final cellW = allsky.width / nbTilesPerLine;
    final cellH = allsky.height / nbRows;
    if (cellW <= 0 || cellH <= 0) return;

    final shift = 2 * (selectedNorder - allskyOrder);

    for (final tile in visibleSet.tiles) {
      // The order-[allskyOrder] ancestor of this tile's NESTED index.
      final ancestorNpix = tile.id.npix >> shift;
      final col = ancestorNpix % nbTilesPerLine;
      final row = ancestorNpix ~/ nbTilesPerLine;

      // The sub-region of the packed Allsky image holding this ancestor cell.
      final cellOriginX = col * cellW;
      final cellOriginY = row * cellH;

      _paintMeshFromSubImage(
        canvas,
        tile.mesh,
        allsky,
        cellOriginX,
        cellOriginY,
        cellW,
        cellH,
      );
    }
  }

  /// `floor(sqrt(numberOfTiles))` — the Allsky grid width in cells at [order].
  static int _allskyTilesPerLine(int order) {
    final numberOfTiles = 12 * (1 << (2 * order));
    return math.sqrt(numberOfTiles).floor();
  }

  /// `ceil(numberOfTiles / nbTilesPerLine)` — the Allsky grid HEIGHT in cells at
  /// [order]. The packed Allsky grid is [nbTilesPerLine] wide but this many rows
  /// tall (the last row may be partly empty), so the cell height must be derived
  /// from this row count, not from [nbTilesPerLine] (the grid is not square).
  static int _allskyRows(int order, int nbTilesPerLine) {
    final numberOfTiles = 12 * (1 << (2 * order));
    return (numberOfTiles + nbTilesPerLine - 1) ~/ nbTilesPerLine;
  }

  /// Warps the sub-cell of a coarse ancestor [image] that the sharp child
  /// occupies onto the child's [HipsFallbackTile.mesh].
  ///
  /// The ancestor image covers `gridSize x gridSize` descendant cells at the
  /// child's order; the child occupies cell `(subX, subY)`. Sampling only that
  /// cell's pixel sub-rect (rather than the whole ancestor image) is what keeps
  /// the coarse fallback registered to the sky under the streaming sharp tile —
  /// the same sub-cell mapping the packed-Allsky path uses, applied to a single
  /// full ancestor tile image instead of a packed grid.
  void _paintFallback(
    Canvas canvas,
    HipsFallbackTile fallback,
    ui.Image image,
  ) {
    final grid = fallback.gridSize;
    if (grid <= 0) return;
    final cellW = image.width / grid;
    final cellH = image.height / grid;
    if (cellW <= 0 || cellH <= 0) return;
    _drawMesh(
      canvas,
      fallback.mesh,
      image,
      texOriginX: fallback.subX * cellW,
      texOriginY: fallback.subY * cellH,
      texSpanX: cellW,
      texSpanY: cellH,
    );
  }

  /// Warps a sub-rectangle of [image] (a packed Allsky cell) onto [mesh],
  /// mapping the mesh's normalized uv onto the cell's pixel sub-rect.
  void _paintMeshFromSubImage(
    Canvas canvas,
    HipsTileMesh mesh,
    ui.Image image,
    double subX,
    double subY,
    double subW,
    double subH,
  ) {
    _drawMesh(
      canvas,
      mesh,
      image,
      texOriginX: subX,
      texOriginY: subY,
      texSpanX: subW,
      texSpanY: subH,
    );
  }

  /// Draws one resident tile as a textured triangle mesh, warping the whole
  /// decoded [image] onto the screen-space [mesh] C3 projected.
  void _paintMesh(Canvas canvas, HipsTileMesh mesh, ui.Image image) {
    _drawMesh(
      canvas,
      mesh,
      image,
      texOriginX: 0,
      texOriginY: 0,
      texSpanX: image.width.toDouble(),
      texSpanY: image.height.toDouble(),
    );
  }

  /// The shared mesh-draw primitive: builds a textured triangle list from
  /// [mesh] sampling the `[texOriginX, texOriginX + texSpanX] x [texOriginY,
  /// texOriginY + texSpanY]` pixel rectangle of [image] (the whole image for a
  /// tile, one packed cell for the Allsky), inset 1px to avoid neighbour bleed,
  /// and draws it with `drawVertices` so all pixel work is on the GPU.
  void _drawMesh(
    Canvas canvas,
    HipsTileMesh mesh,
    ui.Image image, {
    required double texOriginX,
    required double texOriginY,
    required double texSpanX,
    required double texSpanY,
  }) {
    if (texSpanX <= 0 || texSpanY <= 0) return;

    final n = mesh.subdivisions;
    final perSide = mesh.verticesPerSide; // n + 1

    // Inset the sampled texture sub-rectangle by 1px on every edge to avoid
    // bleeding a neighbour's border texel into this tile, while leaving the
    // *position* mesh pixel-exact so neighbours stay seam-free. The inset is
    // expressed in normalized uv (relative to the sampled span) so it scales
    // with the cell's pixel size.
    final uInset =
        (texSpanX > 2 * _textureInsetPx) ? _textureInsetPx / texSpanX : 0.0;
    final vInset =
        (texSpanY > 2 * _textureInsetPx) ? _textureInsetPx / texSpanY : 0.0;

    // Build the triangle list: two triangles per mesh cell, (n*n*2) triangles =
    // (n*n*6) vertices, with matching texture coordinates. Using the explicit
    // triangle list (VertexMode.triangles) keeps the winding unambiguous across
    // engine versions versus strip/fan modes.
    final triCount = n * n * 2;
    final vertexCount = triCount * 3;
    final positions = Float32List(vertexCount * 2);
    final texCoords = Float32List(vertexCount * 2);

    var p = 0; // index into positions/texCoords (in floats)
    for (var row = 0; row < n; row++) {
      for (var col = 0; col < n; col++) {
        final tl = mesh.vertices[row * perSide + col];
        final tr = mesh.vertices[row * perSide + (col + 1)];
        final bl = mesh.vertices[(row + 1) * perSide + col];
        final br = mesh.vertices[(row + 1) * perSide + (col + 1)];

        // Triangle 1: tl, tr, bl. Triangle 2: tr, br, bl.
        p = _emitVertex(positions, texCoords, p, tl, texOriginX, texOriginY,
            texSpanX, texSpanY, uInset, vInset);
        p = _emitVertex(positions, texCoords, p, tr, texOriginX, texOriginY,
            texSpanX, texSpanY, uInset, vInset);
        p = _emitVertex(positions, texCoords, p, bl, texOriginX, texOriginY,
            texSpanX, texSpanY, uInset, vInset);

        p = _emitVertex(positions, texCoords, p, tr, texOriginX, texOriginY,
            texSpanX, texSpanY, uInset, vInset);
        p = _emitVertex(positions, texCoords, p, br, texOriginX, texOriginY,
            texSpanX, texSpanY, uInset, vInset);
        p = _emitVertex(positions, texCoords, p, bl, texOriginX, texOriginY,
            texSpanX, texSpanY, uInset, vInset);
      }
    }

    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      positions,
      textureCoordinates: texCoords,
    );

    // The shader samples the image at the per-vertex texture coordinates (in
    // image pixels). FilterQuality.high gives bilinear sampling so the warped
    // tile is smooth. TileMode.clamp prevents wrap artefacts at the sampled
    // sub-rectangle's edge.
    final shader = ui.ImageShader(
      image,
      ui.TileMode.clamp,
      ui.TileMode.clamp,
      _identityMatrix4,
      filterQuality: FilterQuality.high,
    );
    final paint = Paint()
      ..shader = shader
      ..filterQuality = FilterQuality.high;

    canvas.drawVertices(vertices, ui.BlendMode.srcOver, paint);

    vertices.dispose();
    shader.dispose();
  }

  /// Writes one mesh vertex's screen position and (inset) pixel texture
  /// coordinate into [positions]/[texCoords] at float index [p], returning the
  /// next float index. The texture coordinate is in *image pixels* (what the
  /// [ui.ImageShader] samples in), mapping the vertex's mesh `(u, v)` onto the
  /// `[texOriginX, texOriginX + texSpanX] x [texOriginY, texOriginY + texSpanY]`
  /// sampled sub-rectangle with the edge inset folded in.
  ///
  /// ## HiPS tile-image orientation (the mesh-`(u,v)` -> image-`(x,y)` rotation)
  ///
  /// The mesh's `(u, v)` lattice runs `u` with the HEALPix intra-face `ix` axis
  /// and `v` with the `iy` axis (see [HipsTileSelection]'s `_buildMesh`), so its
  /// four corners are `(u,v)=(0,0)`->south, `(1,0)`->east, `(0,1)`->west,
  /// `(1,1)`->north (the [HealpixNested.boundaries] corner labelling).
  ///
  /// A HiPS tile *image* is NOT a naive top-left raster of that `(ix, iy)`
  /// lattice, and the pixel convention is fixed against REAL TILE CONTENT, not
  /// the IVOA spec text. The decisive test is seam continuity: two HEALPix
  /// diamonds that share a sky edge must show byte-identical content along it.
  /// Measuring the edge-content correlation of the committed real DSS2 tiles
  /// across every candidate `(u,v) -> (tx,ty)` map (see the painter's
  /// `SEAM CONTINUITY` / `STAR COINCIDENCE` tests) ranks
  ///
  ///   tx = v,   ty = u
  ///
  /// far above all others — a pure transpose (swap the mesh axes, NO flip).
  /// At the four corners that places south -> `(x=0,y=0)` (top-left),
  /// east -> `(x=0,y=w)` (bottom-left), west -> `(x=w,y=0)` (top-right),
  /// north -> `(x=w,y=w)` (bottom-right).
  ///
  /// Sampling with `tx = u, ty = v` transposes the other way (a 90° rotation),
  /// and any flipped variant leaves the content discontinuous at tile edges.
  /// Applying the transpose here — in the single shared sampling primitive —
  /// covers the primary, coarse-fallback and packed-Allsky meshes identically:
  /// they all route through [_drawMesh] -> this method.
  int _emitVertex(
    Float32List positions,
    Float32List texCoords,
    int p,
    HipsMeshVertex vtx,
    double texOriginX,
    double texOriginY,
    double texSpanX,
    double texSpanY,
    double uInset,
    double vInset,
  ) {
    positions[p] = vtx.screen.dx;
    positions[p + 1] = vtx.screen.dy;

    // Transpose mesh (u, v) into the HiPS tile-image axes (see method doc):
    // image-x runs with mesh v, image-y runs with mesh u. This is the convention
    // that makes adjacent real DSS2 tiles join seamlessly (verified by the seam-
    // continuity test); any flip of it re-opens the diagonal content seams.
    final tx = vtx.v;
    final ty = vtx.u;

    // Map the rotated [0,1] coordinate onto the inset [inset, 1-inset] band of
    // its own image axis, then onto the sampled sub-rectangle in image pixels.
    // The inset is applied per *image* axis (uInset on x, vInset on y) so it
    // nudges sampling away from the very edge texel to avoid neighbour bleed
    // while keeping interior sampling exact.
    final ix = uInset + tx * (1.0 - 2.0 * uInset);
    final iy = vInset + ty * (1.0 - 2.0 * vInset);
    texCoords[p] = texOriginX + ix * texSpanX;
    texCoords[p + 1] = texOriginY + iy * texSpanY;

    return p + 2;
  }

  @override
  bool shouldRepaint(covariant HipsTileLayerPainter oldDelegate) {
    // The snapshot version is a monotonic integer the loader bumps on every
    // meaningful change (a tile arrived, the Allsky loaded, the view moved, a
    // failure was recorded). Comparing it is O(1) and avoids walking the tile
    // lists. [allskyOrder] changes only on a survey switch, which also warrants
    // a repaint. Identity-compare the snapshot first so a re-pushed identical
    // snapshot (same object) with the same Allsky order never repaints.
    //
    // Rotation/pan/zoom are NOT compared here: they are already baked into the
    // snapshot's per-vertex meshes by the C6 loader → C3 selection, so any view
    // movement that should repaint also produced a new snapshot version. The
    // painter therefore never needs to know rotation as a separate input.
    if (identical(snapshot, oldDelegate.snapshot)) {
      return allskyOrder != oldDelegate.allskyOrder;
    }
    return snapshot.version != oldDelegate.snapshot.version ||
        allskyOrder != oldDelegate.allskyOrder;
  }

  /// The 4x4 identity matrix (row-major, 16 floats) for an [ui.ImageShader] that
  /// samples the image in its own pixel coordinates (the texture coordinates we
  /// supply are already in image pixels). Built once and shared.
  static final Float64List _identityMatrix4 = Float64List.fromList(
    <double>[
      1,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      1,
    ],
  );
}
