// Component C8 — painter geometry + never-blank + repaint-gating guards for the
// Flutter-side GPU HiPS framing tile layer painter.
//
// What these tests pin (the anti-jank + registration contract the painter is
// responsible for):
//
//   * REGISTRATION (#7): the meshes the painter draws are the EXACT meshes C3
//     projected through the shared framing projection — the same projection the
//     survey background and the FOV/mosaic overlays use. We prove this by
//     forward-projecting a tile's mesh corners through the standalone
//     `FramingSkyProjection` (what the FOV overlay registers against) and
//     asserting they coincide, to the pixel, with the mesh vertices the painter
//     consumes. If the painter (or C3) drifted off the shared projection the
//     tiles would de-register from the FOV reticle and this fails.
//   * GPU COMPOSITING (#6): every resident tile is drawn with `drawVertices`
//     (textured triangles on the GPU), never a per-pixel CPU path. We count the
//     `drawVertices` calls a recording canvas captures.
//   * NEVER-BLANK (#4): with no imagery the painter draws NOTHING (stays
//     transparent so the lower single-snapshot layer shows through); with only
//     coarse fallback / Allsky resident it still draws (a softer base), never a
//     blank flash.
//   * REPAINT GATING: `shouldRepaint` is true only when the snapshot version (or
//     the Allsky order) changed — a re-pushed identical snapshot does not
//     repaint, a one-tile arrival (new version) does.
//
// Determinism: tiles are tiny in-memory `ui.Image`s built via PictureRecorder
// (no network, no asset bundle), exactly like the framing registration golden's
// survey-image fixture.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/painters/hips_tile_layer_painter.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/models/framing_hips_projection.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/models/framing_plate_scale.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/models/hips/hips_properties.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/models/hips/hips_tile_id.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/providers/framing_provider.dart'
    show FramingTarget;
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_cache.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_loader.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_selection.dart';

/// A DSS2-like survey at a deep order so a small framing FOV resolves to a
/// handful of order-selected tiles, with a small min order so the Allsky base
/// maps cleanly.
const HipsProperties _props = HipsProperties(
  hipsOrder: 9,
  hipsOrderMin: 3,
  tileWidth: 512,
  tileWidthWasDefaulted: false,
  tileFormats: [HipsTileFormat.jpeg],
  frame: HipsFrame.equatorial,
);

const String _surveyId = 'CDS/P/DSS2/red';

/// A 2.0deg-wide cutout registered as 800x600 — identical astrometry shape to
/// the framing registration golden, so the plate scale math is the established
/// one.
const FramingPlateScale _plateScale = FramingPlateScale(
  surveyFovWidthDeg: 2.0,
  surveyFovHeightDeg: 1.5,
  imagePixelWidth: 800,
  imagePixelHeight: 600,
);

const FramingTarget _target = FramingTarget(
  name: 'NGC 7000',
  catalogId: 'NGC7000',
  raHours: 20.97,
  decDegrees: 44.33,
);

const Size _canvasSize = Size(960, 800);
const double _zoom = 1.0;
const Offset _pan = Offset.zero;
const double _rotation = 0.0;

/// A small solid tile image; content is irrelevant to geometry. 8x8 keeps the
/// fixture cheap.
Future<ui.Image> _solidTile(Color color, {int size = 8}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    Paint()..color = color,
  );
  return recorder.endRecording().toImage(size, size);
}

/// Recording canvas that counts `drawVertices` calls (the GPU mesh path) and
/// records any `drawImageRect` calls, so a test can assert the painter uses the
/// mesh path and never a full-image stretch.
class _RecordingCanvas implements Canvas {
  int drawVerticesCount = 0;
  final List<Rect> drawImageRectDest = [];

  @override
  void drawVertices(ui.Vertices vertices, BlendMode blendMode, Paint paint) {
    drawVerticesCount++;
  }

  @override
  void drawImageRect(ui.Image image, Rect src, Rect dst, Paint paint) {
    drawImageRectDest.add(dst);
  }

  @override
  void noSuchMethod(Invocation invocation) {}
}

/// Builds the C3 visible-tile set for the standard view.
HipsVisibleTileSet _buildVisibleSet({int subdivisions = 4}) {
  final norder = HipsTileSelection.selectNorder(
    _plateScale.pixelsPerDegree(_canvasSize, _zoom),
    _props,
  );
  return HipsTileSelection.computeVisibleTiles(
    _plateScale,
    _target,
    _canvasSize,
    _zoom,
    norder,
    _props,
    subdivisions: subdivisions,
    pan: _pan,
    rotationDegrees: _rotation,
    surveyId: _surveyId,
  );
}

/// Assembles a [HipsResidentSnapshot] from a visible set, marking [primaryIds]
/// resident in [cache] as primary tiles and optionally adding an Allsky image.
HipsResidentSnapshot _snapshotFrom({
  required HipsVisibleTileSet visibleSet,
  required HipsTileCache cache,
  required List<HipsVisibleTile> primary,
  List<HipsFallbackTile> fallback = const [],
  ui.Image? allsky,
  int version = 1,
}) {
  return HipsResidentSnapshot(
    version: version,
    selectedNorder: visibleSet.norder,
    primaryTiles: List.unmodifiable(primary),
    fallbackTiles: List.unmodifiable(fallback),
    allsky: allsky,
    cacheSnapshot: cache.snapshot(),
    visibleSet: visibleSet,
    failures: const [],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // NOTE on ownership: [HipsTileCache] TAKES OWNERSHIP of every image handed to
  // `put` and disposes it on `cache.dispose()`. So a cached image must be a
  // FRESH instance per entry (sharing one across ids would double-dispose). The
  // Allsky image is passed to the snapshot directly (never `put`), so the test
  // owns it and disposes it.
  late ui.Image allskyImage;

  setUpAll(() async {
    allskyImage = await _solidTile(const Color(0xFF113355), size: 64);
  });

  tearDownAll(() {
    allskyImage.dispose();
  });

  test(
      'painter meshes are the C3 meshes projected through the SAME framing '
      'projection the FOV overlay registers against (pixel-exact registration)',
      () {
    final visibleSet = _buildVisibleSet();
    expect(visibleSet.tiles, isNotEmpty,
        reason: 'The standard framing view must resolve to >=1 visible tile.');

    // The projection the FOV/mosaic overlays and the survey background register
    // against — built from the identical plate scale / target / zoom / pan /
    // rotation.
    final overlayProjection = FramingSkyProjection.fromResolved(
      plateScale: _plateScale,
      canvasSize: _canvasSize,
      centerRaHours: _target.raHours,
      centerDecDegrees: _target.decDegrees,
      zoom: _zoom,
      pan: _pan,
      rotationDegrees: _rotation,
    );

    // For every mesh vertex of every visible tile, the screen position the
    // painter will draw (vtx.screen) must equal the position the overlay
    // projection produces for that vertex's sky point — to the pixel.
    for (final tile in visibleSet.tiles) {
      for (final vtx in tile.mesh.vertices) {
        final expected =
            overlayProjection.raDecToScreen(vtx.raHours, vtx.decDegrees);
        expect((vtx.screen.dx - expected.dx).abs(), lessThan(1e-6),
            reason: 'Tile ${tile.id} mesh vertex x must register to the FOV '
                'overlay projection.');
        expect((vtx.screen.dy - expected.dy).abs(), lessThan(1e-6),
            reason: 'Tile ${tile.id} mesh vertex y must register to the FOV '
                'overlay projection.');
      }
    }
  });

  test('every resident primary tile is drawn via drawVertices (GPU mesh path)',
      () async {
    final cache = HipsTileCache(maxEntries: 64, maxBytes: 64 * 1024 * 1024);
    addTearDown(cache.dispose);

    final visibleSet = _buildVisibleSet();
    // Mark the first three tiles resident as primary, each with its OWN image
    // (the cache takes ownership and disposes them).
    final primary = visibleSet.tiles.take(3).toList();
    for (final tile in primary) {
      cache.put(tile.id, await _solidTile(const Color(0xFF2266AA)));
    }

    final snapshot = _snapshotFrom(
      visibleSet: visibleSet,
      cache: cache,
      primary: primary,
    );
    final painter = HipsTileLayerPainter(
      snapshot: snapshot,
      allskyOrder: _props.allskyOrder,
    );

    final recorder = _RecordingCanvas();
    painter.paint(recorder, _canvasSize);

    expect(recorder.drawVerticesCount, primary.length,
        reason: 'Each resident primary tile must be composited as one '
            'drawVertices mesh; no per-pixel CPU path.');
    expect(recorder.drawImageRectDest, isEmpty,
        reason: 'The painter must not full-image-stretch anything via '
            'drawImageRect; even the Allsky base is a per-cell mesh.');
  });

  test(
      'never-blank: empty snapshot draws nothing (transparent); coarse-only '
      'snapshot still draws a base', () {
    final cache = HipsTileCache(maxEntries: 64, maxBytes: 64 * 1024 * 1024);
    addTearDown(cache.dispose);
    final visibleSet = _buildVisibleSet();

    // Empty: no primary, no fallback, no allsky → zero draws.
    final empty = _snapshotFrom(
      visibleSet: visibleSet,
      cache: cache,
      primary: const [],
    );
    final emptyPainter = HipsTileLayerPainter(
      snapshot: empty,
      allskyOrder: _props.allskyOrder,
    );
    final emptyRecorder = _RecordingCanvas();
    emptyPainter.paint(emptyRecorder, _canvasSize);
    expect(emptyRecorder.drawVerticesCount, 0,
        reason: 'With no imagery the painter must draw nothing so the lower '
            'single-snapshot layer shows through.');

    // Allsky-only: the coarse whole-sky base must still paint a cell per
    // visible tile so the view is never blank while sharp tiles stream in.
    final allskyOnly = _snapshotFrom(
      visibleSet: visibleSet,
      cache: cache,
      primary: const [],
      allsky: allskyImage,
    );
    final allskyPainter = HipsTileLayerPainter(
      snapshot: allskyOnly,
      allskyOrder: _props.allskyOrder,
    );
    final allskyRecorder = _RecordingCanvas();
    allskyPainter.paint(allskyRecorder, _canvasSize);
    expect(allskyRecorder.drawVerticesCount, visibleSet.tiles.length,
        reason: 'The Allsky base must paint one warped cell per visible tile, '
            'so a freshly-targeted view is never blank.');
  });

  test(
      'Allsky base uses square packed cells (non-square grid): the sub-rectangle '
      'sampled for a high-row tile is not row-drifted', () async {
    // Registration offset: the HiPS Allsky packs the 12*4^k order-k tiles into a
    // grid that is floor(sqrt(N)) cells WIDE but ceil(N/width) cells TALL — NOT
    // square (order 3: 768 tiles -> 27 wide x 29 tall, last row partly empty). A
    // painter that derives the cell HEIGHT from the WIDTH (height/27 instead of
    // height/29) makes every cell ~7% too tall AND drifts the sampled row-origin
    // downward by `row * excess` px, so a high-row tile's coarse base samples the
    // wrong sky and the whole Allsky mosaic appears shifted (M81 at Dec+69, whose
    // order-3 ancestor is at row 4, lands ~0.3deg off-centre). The cells are
    // SQUARE, so the correct cell height is
    // `image.height / ceil(N/nbTilesPerLine)`, which equals the cell width.
    //
    // This pins it with a per-row vertical GRADIENT Allsky (green encodes the
    // exact Allsky-Y), so the sampled green at a tile's screen centre reveals the
    // sub-cell-precise Allsky-Y the painter sampled. With square cells that Y must
    // fall inside the tile's order-3 ancestor cell's true pixel band; a too-tall
    // cell pushes it `row * excess` px past the band's bottom.
    const allskyOrder = 3;
    final nbPerLine = math.sqrt(12 * (1 << (2 * allskyOrder))).floor(); // 27
    final nbRows =
        (12 * (1 << (2 * allskyOrder)) + nbPerLine - 1) ~/ nbPerLine; // 29
    const cellPx = 16;
    final allskyW = nbPerLine * cellPx;
    final allskyH = nbRows * cellPx; // square cells: cellH == cellW == 16

    // Green channel = a vertical gradient over the FULL Allsky height, so a
    // sampled green value decodes back to the exact Allsky-Y that was sampled.
    final allsky = await () async {
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      for (var y = 0; y < allskyH; y++) {
        final g = (y * 255 / (allskyH - 1)).round().clamp(0, 255);
        c.drawRect(
          Rect.fromLTWH(0, y.toDouble(), allskyW.toDouble(), 1),
          Paint()..color = Color.fromARGB(255, 40, g, 60),
        );
      }
      return rec.endRecording().toImage(allskyW, allskyH);
    }();
    addTearDown(allsky.dispose);

    const m81 = FramingTarget(
      name: 'M81',
      catalogId: 'M81',
      raHours: 9.92583,
      decDegrees: 69.0653,
    );
    final norder = HipsTileSelection.selectNorder(
      _plateScale.pixelsPerDegree(_canvasSize, 1.0),
      _props,
    );
    final visibleSet = HipsTileSelection.computeVisibleTiles(
      _plateScale,
      m81,
      _canvasSize,
      1.0,
      norder,
      _props,
      surveyId: _surveyId,
    );

    final cache = HipsTileCache(maxEntries: 8, maxBytes: 8 * 1024 * 1024);
    addTearDown(cache.dispose);
    final snapshot = _snapshotFrom(
      visibleSet: visibleSet,
      cache: cache,
      primary: const [],
      allsky: allsky,
    );
    final painter =
        HipsTileLayerPainter(snapshot: snapshot, allskyOrder: allskyOrder);

    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.drawRect(
        Offset.zero & _canvasSize, Paint()..color = const Color(0xFF000000));
    painter.paint(canvas, _canvasSize);
    final out = await rec.endRecording().toImage(
          _canvasSize.width.toInt(),
          _canvasSize.height.toInt(),
        );
    addTearDown(out.dispose);
    final bytes = (await out.toByteData(format: ui.ImageByteFormat.rawRgba))!
        .buffer
        .asUint8List();
    final w = _canvasSize.width.toInt();
    final h = _canvasSize.height.toInt();

    final shift = 2 * (norder - allskyOrder);
    final cellH = allskyH / nbRows; // correct, square (== cell width)
    var checked = 0;
    for (final tile in visibleSet.tiles) {
      // Use the centre mesh vertex: its (u, v) drives the sampled Allsky sub-cell
      // coordinate via the painter's tx=v, ty=1-u rotation, so we can predict the
      // EXACT correct sampled Allsky-Y and compare to what actually rendered.
      final mid = tile.mesh.subdivisions ~/ 2;
      final vtx = tile.mesh.vertexAt(mid, mid);
      final sx = vtx.screen.dx.round();
      final sy = vtx.screen.dy.round();
      if (sx < 2 || sx >= w - 2 || sy < 2 || sy >= h - 2) continue;

      final ancestorNpix = tile.id.npix >> shift;
      final expRow = ancestorNpix ~/ nbPerLine;
      // The painter maps mesh (u, v) -> image (tx=v, ty=1-u); for the Allsky cell
      // the sampled Allsky-Y is cellOriginY + ty * cellH, with square cells.
      final ty = 1.0 - vtx.u;
      final expectedSampledY = expRow * cellH + ty * cellH;

      // Decode the actually-sampled Allsky-Y from the green gradient.
      final g = bytes[(sy * w + sx) * 4 + 1];
      final sampledY = g * (allskyH - 1) / 255.0;

      // They must agree to a couple of px (gradient quantisation + bilinear). The
      // non-square-cell bug shifts the sampled Y by `expRow * (excessHeight)` plus
      // the within-cell stretch — several px at row 4 — which this catches.
      expect((sampledY - expectedSampledY).abs(), lessThan(2.5),
          reason:
              'Tile npix=${tile.id.npix} (ancestor row $expRow): the painter '
              'sampled Allsky-Y $sampledY but square-cell geometry requires '
              '$expectedSampledY. A mismatch is the non-square-grid bug — the '
              'Allsky cell height was derived from the grid WIDTH instead of the '
              'true row count, drifting the coarse base off the registered tiles.');
      checked++;
    }
    expect(checked, greaterThan(0),
        reason: 'At least one visible tile centre must be on-canvas to verify '
            'the Allsky cell registration.');
  });

  test('fallback tiles draw under primary tiles (both via mesh)', () async {
    final cache = HipsTileCache(maxEntries: 64, maxBytes: 64 * 1024 * 1024);
    addTearDown(cache.dispose);
    final visibleSet = _buildVisibleSet();

    final primary = visibleSet.tiles.take(2).toList();
    // A coarse fallback for the last visible (sharp) tile: its parent (one order
    // up), sampled at the sub-cell the sharp child occupies within the parent.
    final childTile = visibleSet.tiles.last;
    final coarseId = HipsTileId(
      survey: _surveyId,
      norder: visibleSet.norder - 1,
      npix: childTile.id.npix >> 2,
    );
    final fallback = [
      HipsFallbackTile.fromDescent(
        ancestorId: coarseId,
        childNorder: childTile.id.norder,
        childNpix: childTile.id.npix,
        childMesh: childTile.mesh,
      ),
    ];
    for (final tile in primary) {
      cache.put(tile.id, await _solidTile(const Color(0xFF2266AA)));
    }
    cache.put(coarseId, await _solidTile(const Color(0xFF2266AA)));

    final snapshot = _snapshotFrom(
      visibleSet: visibleSet,
      cache: cache,
      primary: primary,
      fallback: fallback,
    );
    final painter = HipsTileLayerPainter(
      snapshot: snapshot,
      allskyOrder: _props.allskyOrder,
    );
    final recorder = _RecordingCanvas();
    painter.paint(recorder, _canvasSize);

    expect(recorder.drawVerticesCount, primary.length + fallback.length,
        reason: 'Primary + fallback tiles each draw one mesh.');
  });

  test('shouldRepaint is gated on snapshot version + allsky order', () async {
    final cache = HipsTileCache(maxEntries: 64, maxBytes: 64 * 1024 * 1024);
    addTearDown(cache.dispose);
    final visibleSet = _buildVisibleSet();
    final primary = visibleSet.tiles.take(1).toList();
    cache.put(primary.first.id, await _solidTile(const Color(0xFF2266AA)));

    final v1 = _snapshotFrom(
      visibleSet: visibleSet,
      cache: cache,
      primary: primary,
      version: 1,
    );
    final v2 = _snapshotFrom(
      visibleSet: visibleSet,
      cache: cache,
      primary: primary,
      version: 2,
    );

    final p1 = HipsTileLayerPainter(snapshot: v1, allskyOrder: 3);
    final p1Same = HipsTileLayerPainter(snapshot: v1, allskyOrder: 3);
    final p2 = HipsTileLayerPainter(snapshot: v2, allskyOrder: 3);
    final p1DiffOrder = HipsTileLayerPainter(snapshot: v1, allskyOrder: 4);

    expect(p1Same.shouldRepaint(p1), isFalse,
        reason: 'Same snapshot version + same allsky order must NOT repaint.');
    expect(p2.shouldRepaint(p1), isTrue,
        reason: 'A new snapshot version (a tile arrived / view moved) must '
            'repaint exactly once.');
    expect(p1DiffOrder.shouldRepaint(p1), isTrue,
        reason: 'A survey switch changing the allsky order must repaint.');
  });

  test('torn snapshot (tile id missing from cache) never throws mid-paint', () {
    final cache = HipsTileCache(maxEntries: 64, maxBytes: 64 * 1024 * 1024);
    addTearDown(cache.dispose);
    final visibleSet = _buildVisibleSet();
    // Claim a tile is primary but DO NOT put it in the cache — a torn snapshot.
    final primary = visibleSet.tiles.take(1).toList();
    final snapshot = _snapshotFrom(
      visibleSet: visibleSet,
      cache: cache, // empty cache
      primary: primary,
    );
    final painter = HipsTileLayerPainter(
      snapshot: snapshot,
      allskyOrder: _props.allskyOrder,
    );
    final recorder = _RecordingCanvas();
    expect(() => painter.paint(recorder, _canvasSize), returnsNormally,
        reason: 'A tile whose image is not resident must be skipped, not '
            'throw — the lower layer shows through that region.');
    expect(recorder.drawVerticesCount, 0,
        reason: 'No image → no mesh drawn for that tile.');
  });
}
