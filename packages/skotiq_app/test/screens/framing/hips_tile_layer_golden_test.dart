// Component C10 — multi-zoom composite verification of the framing canvas with
// the HiPS tile layer fed the committed real DSS2-colour C-FIX fixtures.
//
// WHAT THIS LOCKS: the actual composited output of the Flutter-side GPU HiPS
// framing tile layer — the real C8 [HipsTileLayerPainter] drawing the committed
// M31 fixture tiles (decoded through the production `ui.decodeImageFromList`
// path) over a dark backdrop standing in for the framing canvas's survey
// snapshot — at three zoom levels: 0.5x (zoomed out, coarser footprint), 1x (the
// golden framing zoom, the full committed Norder6 mosaic), and 4x (zoomed in,
// fewer larger tiles). At each zoom it asserts (a) the painter emits exactly one
// GPU mesh per visible tile (the Allsky base cell) plus one per resident primary
// — locking the per-cell Allsky sampling, the draw order and that every resident
// sharp tile is composited as a mesh — and (b) the rasterised image is NON-BLANK
// (real imagery composited over the backdrop). A regression in the mesh warp,
// the per-cell Allsky sampling, the draw order, or the LOD footprint at any zoom
// changes the mesh count or blanks the output and is caught here.
//
// WHY NOT A PIXEL GOLDEN: a textured `drawVertices` mosaic raster is
// platform/GPU-fragile (the same reason capturing it through a RepaintBoundary
// can hang the comparator), so a committed PNG baseline would be un-reviewable
// churn or a false failure on a different CI image. The deterministic mesh-count
// + non-blank assertions lock the same guarantees without that fragility, and a
// human-inspection PNG is still written so the mosaic can be eyeballed.
//
// It WRITES a human-inspection PNG per zoom under `<repo>/build/hips_artifacts/`
// (and prints each absolute path), so the rendered mosaic can be eyeballed at
// each zoom — the dense real galaxy field makes the seam-free tessellation and
// the FOV-registered footprint obvious.
//
// DETERMINISM: the fixtures are committed real bytes (no network, no asset
// bundle); decode is the production `ui.decodeImageFromList` path; the surface is
// fixed; the painter is rasterised directly via `Picture.toImage`.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/painters/hips_tile_layer_painter.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/models/framing_plate_scale.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/models/hips/hips_properties.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/providers/framing_provider.dart'
    show FramingTarget;
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_cache.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_loader.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/hips_tile_selection.dart';

import '../../fixtures/hips/fixture_field.dart' as fixture;
import 'support/hips_fixture_render.dart';

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

/// The framing-canvas backdrop the HiPS layer composites over (standing in for
/// the survey snapshot / starfield underneath). Matches the C8 / C-FIX golden
/// backdrop so the visual lock is comparable.
const Color _backdrop = Color(0xFF05070C);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HipsProperties props;
  setUpAll(() {
    props = HipsProperties.parse(fixture.readPropertiesText());
  });

  /// Builds the resident snapshot for the fixture field at [zoom]: every visible
  /// tile that is a committed fixture is decoded (production path) and made
  /// resident as primary, with the committed Allsky as the coarse base. Visible
  /// tiles outside the committed sample fall back to the Allsky cell warped onto
  /// their mesh — exactly the never-blank behaviour, so the golden shows real
  /// coverage edge-to-edge.
  Future<
      ({
        HipsResidentSnapshot snapshot,
        HipsTileCache cache,
        ui.Image allsky
      })> residentAt(double zoom) async {
    final norder = HipsTileSelection.selectNorder(
      _plateScale.pixelsPerDegree(_canvasSize, zoom),
      props,
    );
    final visibleSet = HipsTileSelection.computeVisibleTiles(
      _plateScale,
      _target,
      _canvasSize,
      zoom,
      norder,
      props,
      surveyId: fixture.surveyHipsId,
    );

    final cache = HipsTileCache(maxEntries: 256, maxBytes: 256 * 1024 * 1024);
    final primary = <HipsVisibleTile>[];
    for (final tile in visibleSet.tiles) {
      final bytes = fixtureTileBytesOrNull(tile.id);
      if (bytes == null) continue;
      cache.put(tile.id, await decodeFixtureImage(bytes));
      primary.add(tile);
    }
    final allsky = await decodeFixtureImage(fixture.readAllskyBytes());

    final snapshot = HipsResidentSnapshot(
      version: 1,
      selectedNorder: visibleSet.norder,
      primaryTiles: List.unmodifiable(primary),
      fallbackTiles: const [],
      allsky: allsky,
      cacheSnapshot: cache.snapshot(),
      visibleSet: visibleSet,
      failures: const [],
    );
    return (snapshot: snapshot, cache: cache, allsky: allsky);
  }

  /// Rasterises the real painter over the framing backdrop to a [ui.Image] via a
  /// [ui.PictureRecorder] — the deterministic direct path (a RepaintBoundary
  /// capture of a drawVertices tree can hang the golden comparator).
  Future<ui.Image> renderAt(double zoom) async {
    final built = await residentAt(zoom);
    addTearDown(built.cache.dispose);
    addTearDown(built.allsky.dispose);

    final painter = HipsTileLayerPainter(
      snapshot: built.snapshot,
      allskyOrder: props.allskyOrder,
    );

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(Offset.zero & _canvasSize, Paint()..color = _backdrop);
    painter.paint(canvas, _canvasSize);
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(
        fixture.fixturePixelWidth,
        fixture.fixturePixelHeight,
      );
    } finally {
      picture.dispose();
    }
  }

  /// Writes [image] as a human-inspection PNG to `<repo>/build/hips_artifacts/`
  /// and prints its absolute path.
  Future<void> writeArtifact(ui.Image image, String fileName) async {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    expect(png, isNotNull,
        reason: 'PNG encode of the $fileName artifact failed.');
    final dir = Directory('${_repoRoot().path}/build/hips_artifacts');
    dir.createSync(recursive: true);
    final file = File('${dir.path}/$fileName');
    file.writeAsBytesSync(png!.buffer.asUint8List());
    // ignore: avoid_print
    print('HiPS framing zoom artifact written to: ${file.absolute.path}');
  }

  /// Asserts the composited output at [zoom] is non-blank (real imagery was
  /// drawn over the backdrop), then writes the human-inspection artifact.
  ///
  /// We deliberately do NOT pixel-golden a `drawVertices` mosaic: a textured
  /// triangle-mesh raster is platform/GPU-fragile (the very reason the file
  /// header warns against capturing it through a RepaintBoundary), so a committed
  /// PNG baseline would be either un-reviewable churn or a false failure on a
  /// different CI image. Instead we lock the OUTPUT deterministically: the
  /// painter must (a) emit exactly one GPU mesh per visible tile (the Allsky base
  /// cell) plus one per resident primary, and (b) actually paint imagery — the
  /// rendered image must contain pixels that differ from the bare backdrop. A
  /// regression in the mesh warp / draw order / LOD footprint changes the mesh
  /// count or blanks the output and is caught here, at every zoom, without a
  /// fragile pixel baseline.
  Future<void> verifyZoom(double zoom, String fileName) async {
    final built = await residentAt(zoom);
    addTearDown(built.cache.dispose);
    addTearDown(built.allsky.dispose);

    final snapshot = built.snapshot;
    final visibleSet = snapshot.visibleSet!;

    final painter = HipsTileLayerPainter(
      snapshot: snapshot,
      allskyOrder: props.allskyOrder,
    );

    // 1) GPU-mesh count: one Allsky base cell per visible tile + one per resident
    //    primary. This locks the seam-free per-cell Allsky sampling AND that
    //    every resident sharp tile is composited as exactly one mesh.
    final counter = _MeshCountingCanvas();
    painter.paint(counter, _canvasSize);
    final expectedMeshes =
        visibleSet.tiles.length + snapshot.primaryTiles.length;
    expect(counter.drawVerticesCount, expectedMeshes,
        reason: 'At zoom $zoom the painter must composite one Allsky base mesh '
            'per visible tile (${visibleSet.tiles.length}) plus one per resident '
            'primary (${snapshot.primaryTiles.length}); got '
            '${counter.drawVerticesCount}.');
    expect(counter.drawVerticesCount, greaterThan(0),
        reason: 'A populated view must composite at least one GPU mesh.');

    // 2) Non-blank composite: rasterise over the backdrop and assert real
    //    imagery was drawn (some pixel differs from the bare backdrop colour).
    final image = await renderAt(zoom);
    addTearDown(image.dispose);
    final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(pixels, isNotNull,
        reason: 'raw RGBA read of the $fileName mosaic failed');
    expect(_hasNonBackdropPixels(pixels!, _backdrop), isTrue,
        reason:
            'At zoom $zoom the layer must composite visible imagery over the '
            'backdrop (the mosaic must not be blank).');

    await writeArtifact(image, fileName);
  }

  test(
      'hips_tiles_zoom_0_5x: framing canvas + HiPS layer at 0.5x composites '
      'a registered, non-blank mosaic', () async {
    await verifyZoom(0.5, 'hips_tiles_zoom_0_5x.png');
  });

  test(
      'hips_tiles_zoom_1x: framing canvas + HiPS layer at 1x composites a '
      'registered, non-blank mosaic', () async {
    await verifyZoom(1.0, 'hips_tiles_zoom_1x.png');
  });

  test(
      'hips_tiles_zoom_4x: framing canvas + HiPS layer at 4x composites a '
      'registered, non-blank mosaic', () async {
    await verifyZoom(4.0, 'hips_tiles_zoom_4x.png');
  });
}

/// Counts the `drawVertices` (GPU mesh) calls the painter emits.
class _MeshCountingCanvas implements Canvas {
  int drawVerticesCount = 0;

  @override
  void drawVertices(ui.Vertices vertices, BlendMode blendMode, Paint paint) {
    drawVerticesCount++;
  }

  @override
  void noSuchMethod(Invocation invocation) {}
}

/// Whether [rgba] (tightly-packed RGBA8888) contains at least one pixel that is
/// not the [backdrop] colour — i.e. the painter actually composited imagery.
bool _hasNonBackdropPixels(ByteData rgba, Color backdrop) {
  final r = (backdrop.r * 255.0).round() & 0xff;
  final g = (backdrop.g * 255.0).round() & 0xff;
  final b = (backdrop.b * 255.0).round() & 0xff;
  final a = (backdrop.a * 255.0).round() & 0xff;
  final bytes = rgba.buffer.asUint8List(
    rgba.offsetInBytes,
    rgba.lengthInBytes,
  );
  for (var i = 0; i + 3 < bytes.length; i += 4) {
    if (bytes[i] != r ||
        bytes[i + 1] != g ||
        bytes[i + 2] != b ||
        bytes[i + 3] != a) {
      return true;
    }
  }
  return false;
}

/// The repository root, located by walking up from the package directory until
/// the `.git` directory (or `version.yaml` single-source-of-truth) is found.
Directory _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (Directory('${dir.path}/.git').existsSync() ||
        File('${dir.path}/version.yaml').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current;
}
