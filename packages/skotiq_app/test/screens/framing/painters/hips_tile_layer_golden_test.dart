// Tagged "golden" so the perceptual/pixel-diff golden gate is excluded by
// `melos run test` (Linux CI + default local runs) and opt-in via
// `melos run test:golden`. Baselines are host-specific; see
// docs/testing/golden-tests.md.
@Tags(['golden'])
library;

// Component C8 — visual golden + sample render for the HiPS framing tile mosaic.
//
// This locks the actual composited output of [HipsTileLayerPainter] so a
// regression in the mesh warp, the per-cell Allsky sampling, the draw order, or
// the registration to the shared framing projection is caught visually — not
// only via the geometry assertions in the painter test.
//
// It also WRITES a human-inspectable sample PNG under `<repo>/.hips_verify/` so
// the rendered mosaic can be eyeballed (distinct per-tile tints make the
// seam-free tessellation and the FOV-registered footprint obvious). The absolute
// path is printed.
//
// Determinism: tiles are tiny in-memory `ui.Image`s (PictureRecorder), the
// meshes are the real C3 output for a fixed plate scale / target / canvas size,
// and the surface is fixed — no network, no asset bundle.

import 'dart:io';
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

const HipsProperties _props = HipsProperties(
  hipsOrder: 9,
  hipsOrderMin: 3,
  tileWidth: 512,
  tileWidthWasDefaulted: false,
  tileFormats: [HipsTileFormat.jpeg],
  frame: HipsFrame.equatorial,
);

const String _surveyId = 'CDS/P/DSS2/red';

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

const Size _canvasSize = Size(640, 512);

/// A tile image tinted by [hue] with a 1px-ish dark border so the mosaic's
/// tessellation is visible in the sample render. Content is otherwise flat.
Future<ui.Image> _tintedTile(double hue) async {
  const size = 32;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final color = HSVColor.fromAHSV(1.0, hue % 360.0, 0.55, 0.85).toColor();
  canvas.drawRect(
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    Paint()..color = color,
  );
  // Inner highlight so a warped tile shows its orientation.
  canvas.drawRect(
    const Rect.fromLTWH(2, 2, size - 4, size - 4),
    Paint()..color = color.withValues(alpha: 0.55),
  );
  return recorder.endRecording().toImage(size, size);
}

/// Builds the resident snapshot (every visible tile tinted + resident) and the
/// painter for the standard view.
Future<HipsTileLayerPainter> _buildPainter(HipsTileCache cache) async {
  final norder = HipsTileSelection.selectNorder(
    _plateScale.pixelsPerDegree(_canvasSize, 1.0),
    _props,
  );
  final visibleSet = HipsTileSelection.computeVisibleTiles(
    _plateScale,
    _target,
    _canvasSize,
    1.0,
    norder,
    _props,
    subdivisions: 4,
    surveyId: _surveyId,
  );

  // Make every visible tile resident with a distinct tint so the mosaic reads.
  final primary = <HipsVisibleTile>[];
  var i = 0;
  for (final tile in visibleSet.tiles) {
    cache.put(tile.id, await _tintedTile(i * 37.0));
    primary.add(tile);
    i++;
  }

  final snapshot = HipsResidentSnapshot(
    version: 1,
    selectedNorder: visibleSet.norder,
    primaryTiles: List.unmodifiable(primary),
    fallbackTiles: const [],
    allsky: null,
    cacheSnapshot: cache.snapshot(),
    visibleSet: visibleSet,
    failures: const [],
  );

  return HipsTileLayerPainter(
    snapshot: snapshot,
    allskyOrder: _props.allskyOrder,
  );
}

/// Renders the mosaic painter (over a dark backdrop standing in for the framing
/// canvas's survey snapshot / starfield this layer composites over) to a
/// [ui.Image] via a [ui.PictureRecorder]. This direct rasterisation path is used
/// instead of a `RepaintBoundary` capture because the golden comparator can hang
/// rasterising a `drawVertices` layer tree offscreen; a `Picture.toImage` of the
/// same painter is deterministic and fast.
Future<ui.Image> _renderMosaic(HipsTileLayerPainter painter) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Offset.zero & _canvasSize,
    Paint()..color = const Color(0xFF05070C),
  );
  painter.paint(canvas, _canvasSize);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(
      _canvasSize.width.round(),
      _canvasSize.height.round(),
    );
  } finally {
    picture.dispose();
  }
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('hips_tile_mosaic_golden: composited HiPS mosaic renders stably',
      () async {
    final cache = HipsTileCache(maxEntries: 256, maxBytes: 256 * 1024 * 1024);
    addTearDown(cache.dispose);

    final painter = await _buildPainter(cache);
    final image = await _renderMosaic(painter);
    addTearDown(image.dispose);

    // Write a human-inspectable sample PNG to <repo>/.hips_verify/ and print its
    // absolute path, so the verified rendering can be eyeballed.
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    expect(png, isNotNull, reason: 'PNG encode of the mosaic must succeed.');
    final outDir = Directory('${_repoRoot().path}/.hips_verify');
    outDir.createSync(recursive: true);
    final outFile = File('${outDir.path}/hips_tile_mosaic_sample.png');
    outFile.writeAsBytesSync(png!.buffer.asUint8List());
    // ignore: avoid_print
    print('HiPS tile mosaic sample written to: ${outFile.absolute.path}');

    // Lock the rendered mosaic as a golden via the direct ui.Image form (the
    // RepaintBoundary capture path can hang the comparator on a drawVertices
    // layer; rasterising the painter to an image is deterministic).
    await expectLater(
      image,
      matchesGoldenFile('goldens/hips_tile_mosaic.png'),
    );
  });
}
