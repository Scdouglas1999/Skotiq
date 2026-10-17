import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:skotiq_core/src/models/framing_plate_scale.dart';
import 'package:skotiq_core/src/models/hips/hips_properties.dart';
import 'package:skotiq_core/src/providers/framing_provider.dart'
    show FramingTarget, SurveySource;
import 'package:skotiq_core/src/providers/hips_framing_provider.dart';
import 'package:skotiq_core/src/services/hips/hips_tile_cache.dart';
import 'package:skotiq_core/src/services/hips/hips_tile_fetcher.dart';
import 'package:skotiq_core/src/services/hips/hips_tile_loader.dart';
import 'package:skotiq_core/src/services/hips/hips_tile_selection.dart';

/// End-to-end visual proof that the **C7 provider wiring** drives the full
/// HiPS pipeline: a widget calls `setSurvey` + `requestViewport` on the
/// resident-tiles notifier (the only API the framing widget uses), and the
/// versioned snapshot exposed by `hipsResidentTilesProvider` carries a
/// FOV-registered, gap-free tile mosaic. The render below draws that snapshot
/// the way the framing painter would, and overlays the FOV rectangle derived
/// from the SAME [FramingPlateScale] to prove tiles stay registered to the
/// overlay — this path never touches the planetarium renderer.
///
/// Output:
///   * golden: `goldens/hips_framing_provider_registered.png` (byte-locked)
///   * sample: repo-root `.hips_verify/hips_framing_provider_registered.png`
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('C7 providers drive a registered, gap-free framing tile mosaic', () async {
    const canvas = ui.Size(1200, 900);
    const plateScale = FramingPlateScale(
      surveyFovWidthDeg: 1.5,
      surveyFovHeightDeg: 1.5,
      imagePixelWidth: 1200,
      imagePixelHeight: 1200,
    );
    const target = FramingTarget(name: 'M42', raHours: 5.59, decDegrees: -5.39);
    final props = HipsProperties.parse('''
hips_order        = 9
hips_order_min    = 3
hips_tile_width   = 512
hips_tile_format  = png
hips_frame        = equatorial
''');

    final server = MockClient((request) async {
      final url = request.url.toString();
      final seed = url.hashCode & 0x7fffffff;
      return http.Response.bytes(
        _solidPng(
          64,
          80 + seed % 120,
          80 + (seed ~/ 120) % 120,
          100 + (seed ~/ 14400) % 120,
        ),
        200,
      );
    });

    final container = ProviderContainer(
      overrides: [
        hipsTileFetcherProvider.overrideWithValue(
          HipsTileFetcher(httpClient: server),
        ),
        hipsTileCacheProvider.overrideWithValue(
          HipsTileCache(maxEntries: 1024, maxBytes: 128 * 1024 * 1024),
        ),
        hipsTileLoaderProvider.overrideWith((ref) {
          final loader = HipsTileLoader(
            cache: ref.watch(hipsTileCacheProvider),
            fetcher: ref.watch(hipsTileFetcherProvider),
            debounce: Duration.zero,
            subdivisions: 4,
            ownsFetcher: true,
          );
          ref.onDispose(loader.dispose);
          return loader;
        }),
      ],
    );
    addTearDown(container.dispose);

    // Keep the autoDispose pipeline alive for the test, mirroring a mounted
    // widget that watches the snapshot (otherwise the loader's pending recompute
    // timer is cancelled when the synchronous read returns).
    final sub = container.listen<HipsResidentSnapshot>(
      hipsResidentTilesProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(sub.close);

    // The capability gate must say DSS is active.
    expect(
      container.read(hipsFramingActiveProvider(SurveySource.dss2Red)),
      isTrue,
    );

    final notifier = container.read(hipsResidentTilesProvider.notifier);
    notifier.setSurvey(SurveySource.dss2Red);
    notifier.requestViewport(
      plateScale: plateScale,
      target: target,
      canvasSize: canvas,
      zoom: 1.4,
      pan: ui.Offset.zero,
      rotationDegrees: 0.0,
      format: HipsTileFormat.png,
      props: props,
    );
    await _settle();

    final snap = container.read(hipsResidentTilesProvider);
    expect(snap.version, greaterThan(0));
    expect(snap.hasAnyImagery, isTrue, reason: 'never-blank invariant');
    final vs = snap.visibleSet;
    expect(vs, isNotNull);

    // Render the snapshot the way the painter layers it.
    final image = img.Image(
      width: canvas.width.toInt(),
      height: canvas.height.toInt(),
    );
    img.fill(image, color: img.ColorRgb8(6, 9, 16));

    if (snap.allsky != null) {
      img.fill(image, color: img.ColorRgb8(18, 22, 34));
    }
    // Resident primary + fallback meshes filled so gap-freeness is obvious.
    for (final tile in snap.fallbackTiles) {
      _fillMesh(image, tile.mesh, img.ColorRgb8(40, 70, 110));
    }
    for (final tile in snap.primaryTiles) {
      _fillMesh(image, tile.mesh, img.ColorRgb8(70, 120, 180));
    }
    // Visible-set geometry outlined on top to prove the full mosaic footprint.
    for (final tile in vs!.tiles) {
      _meshOutline(image, tile.mesh, img.ColorRgb8(120, 200, 255));
    }
    // FOV rectangle from the SAME plate scale + zoom => registration proof.
    final fov = plateScale.drawRectFor(canvas, 1.4, ui.Offset.zero);
    _rectOutline(image, fov, img.ColorRgb8(255, 170, 60));

    // The projected FOV center must be covered (never blank there).
    final center = vs.projection.raDecToScreen(
      target.raHours,
      target.decDegrees,
    );
    final coveringMeshes = <HipsTileMesh>[
      ...snap.primaryTiles.map((t) => t.mesh),
      ...snap.fallbackTiles.map((t) => t.mesh),
    ];
    final centerCovered =
        snap.allsky != null ||
        coveringMeshes.any((mesh) {
          final b = mesh.screenBounds;
          return b != null && b.contains(ui.Offset(center.dx, center.dy));
        });
    expect(
      centerCovered,
      isTrue,
      reason: 'FOV center must be covered by a resident tile / Allsky base',
    );

    final png = Uint8List.fromList(img.encodePng(image));

    final repoRoot = _repoRoot();
    final sampleDir = Directory('${repoRoot.path}/.hips_verify');
    sampleDir.createSync(recursive: true);
    final sample = File(
      '${sampleDir.path}/hips_framing_provider_registered.png',
    );
    sample.writeAsBytesSync(png);
    // ignore: avoid_print
    print('HiPS C7 provider sample written: ${sample.absolute.path}');

    final goldenDir = Directory('test/providers/goldens');
    goldenDir.createSync(recursive: true);
    final golden = File(
      '${goldenDir.path}/hips_framing_provider_registered.png',
    );
    if (!golden.existsSync()) {
      golden.writeAsBytesSync(png);
      // ignore: avoid_print
      print('Golden created: ${golden.absolute.path}');
    } else {
      expect(
        png,
        golden.readAsBytesSync(),
        reason:
            'C7 provider render drifted from golden; if intentional, '
            'delete ${golden.path} to regenerate.',
      );
    }
  });
}

Future<void> _settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

Uint8List _solidPng(int size, int r, int g, int b) {
  final image = img.Image(width: size, height: size);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodePng(image));
}

void _fillMesh(img.Image image, HipsTileMesh mesh, img.Color color) {
  final b = mesh.screenBounds;
  if (b == null) return;
  final n = mesh.subdivisions;
  for (var row = 0; row < n; row++) {
    for (var col = 0; col < n; col++) {
      final a = mesh.vertexAt(row, col).screen;
      final bb = mesh.vertexAt(row, col + 1).screen;
      final c = mesh.vertexAt(row + 1, col).screen;
      final d = mesh.vertexAt(row + 1, col + 1).screen;
      final minX = [a.dx, bb.dx, c.dx, d.dx].reduce((p, q) => p < q ? p : q);
      final maxX = [a.dx, bb.dx, c.dx, d.dx].reduce((p, q) => p > q ? p : q);
      final minY = [a.dy, bb.dy, c.dy, d.dy].reduce((p, q) => p < q ? p : q);
      final maxY = [a.dy, bb.dy, c.dy, d.dy].reduce((p, q) => p > q ? p : q);
      img.fillRect(
        image,
        x1: minX.round(),
        y1: minY.round(),
        x2: maxX.round(),
        y2: maxY.round(),
        color: color,
      );
    }
  }
}

void _meshOutline(img.Image image, HipsTileMesh mesh, img.Color color) {
  final n = mesh.subdivisions;
  for (var row = 0; row <= n; row++) {
    for (var col = 0; col < n; col++) {
      _line(
        image,
        mesh.vertexAt(row, col).screen,
        mesh.vertexAt(row, col + 1).screen,
        color,
      );
    }
  }
  for (var col = 0; col <= n; col++) {
    for (var row = 0; row < n; row++) {
      _line(
        image,
        mesh.vertexAt(row, col).screen,
        mesh.vertexAt(row + 1, col).screen,
        color,
      );
    }
  }
}

void _rectOutline(img.Image image, ui.Rect rect, img.Color color) {
  final corners = <ui.Offset>[
    rect.topLeft,
    rect.topRight,
    rect.bottomRight,
    rect.bottomLeft,
  ];
  for (var i = 0; i < 4; i++) {
    _line(image, corners[i], corners[(i + 1) % 4], color);
  }
}

void _line(img.Image image, ui.Offset a, ui.Offset b, img.Color color) {
  img.drawLine(
    image,
    x1: a.dx.round(),
    y1: a.dy.round(),
    x2: b.dx.round(),
    y2: b.dy.round(),
    color: color,
  );
}

Directory _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/version.yaml').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current.parent.parent;
}
