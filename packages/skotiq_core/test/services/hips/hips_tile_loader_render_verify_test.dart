import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:skotiq_core/src/models/framing_plate_scale.dart';
import 'package:skotiq_core/src/models/hips/hips_properties.dart';
import 'package:skotiq_core/src/providers/framing_provider.dart'
    show FramingTarget;
import 'package:skotiq_core/src/services/hips/hips_tile_cache.dart';
import 'package:skotiq_core/src/services/hips/hips_tile_fetcher.dart';
import 'package:skotiq_core/src/services/hips/hips_tile_loader.dart';
import 'package:skotiq_core/src/services/hips/hips_tile_selection.dart';

/// Visual proof of C6's *never-blank progressive streaming*: after the user
/// zooms in, the sharp (selected-order) tiles are still on the wire, but the
/// loader's snapshot exposes the already-resident coarser tiles + Allsky base as
/// fallbacks covering the exact same FOV. This render draws that snapshot the
/// way the framing painter would — fallbacks under, primary over — so a reviewer
/// can confirm the mosaic is gap-free and registered while the sharp layer
/// streams in.
///
/// Output:
///   * golden: `goldens/hips_tile_loader_progressive.png` (byte-locked)
///   * sample: repo-root `.hips_verify/hips_tile_loader_progressive.png`
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('C6 loader streams a never-blank progressive mosaic', () async {
    const surveyId = 'CDS/P/DSS2/red';
    const baseUrl = 'https://alasky.cds.unistra.fr/DSS/DSS2Merged';
    final props = HipsProperties.parse('''
hips_order        = 9
hips_order_min    = 3
hips_tile_width   = 512
hips_tile_format  = png
hips_frame        = equatorial
''');

    const canvas = ui.Size(1200, 900);
    const plateScale = FramingPlateScale(
      surveyFovWidthDeg: 1.5,
      surveyFovHeightDeg: 1.5,
      imagePixelWidth: 1200,
      imagePixelHeight: 1200,
    );
    const target = FramingTarget(name: 'M42', raHours: 5.59, decDegrees: -5.39);

    HipsViewport vp(double zoom) => HipsViewport(
      plateScale: plateScale,
      target: target,
      canvasSize: canvas,
      zoom: zoom,
      pan: ui.Offset.zero,
      rotationDegrees: 0.0,
      baseUrl: baseUrl,
      surveyId: surveyId,
      format: HipsTileFormat.png,
      props: props,
    );

    final clock = _FakeClock();
    final gate = _Gate();
    final server = MockClient((request) async {
      final url = request.url.toString();
      // Distinct colour per tile so the mosaic + LOD layering is visible.
      final seed = url.hashCode & 0x7fffffff;
      // Hold the deep (sharp) order in flight; serve coarse + allsky promptly.
      if (url.contains('/Norder8/') && url.contains('/Npix')) {
        await gate.future;
      }
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

    final cache = HipsTileCache(maxEntries: 1024, maxBytes: 128 * 1024 * 1024);
    final loader = HipsTileLoader(
      cache: cache,
      fetcher: HipsTileFetcher(httpClient: server),
      clock: clock,
      subdivisions: 4,
    );
    addTearDown(loader.dispose);

    // 1) Settle a coarse view (lower selected order) so its tiles are resident.
    loader.requestTiles(vp(0.4));
    clock.fireAll();
    await _settle();
    final coarseNorder = loader.snapshot.selectedNorder;
    expect(
      loader.snapshot.primaryTiles,
      isNotEmpty,
      reason: 'coarse view should have loaded its tiles',
    );

    // 2) Zoom in hard so the selected order jumps to 8 (held in flight). The
    //    snapshot must now show coarse fallbacks (+ Allsky) covering the FOV.
    loader.requestTiles(vp(2.4));
    clock.fireAll();
    await _settle();

    final snap = loader.snapshot;
    expect(snap.selectedNorder, greaterThan(coarseNorder));
    expect(
      snap.selectedNorder,
      8,
      reason: 'expected the zoomed view to select Norder 8',
    );
    // Sharp tiles are still on the wire, so primary may be empty, but the view
    // must NOT be blank.
    expect(snap.hasAnyImagery, isTrue, reason: 'never-blank invariant');
    expect(
      snap.fallbackTiles.isNotEmpty || snap.allsky != null,
      isTrue,
      reason:
          'coarse fallback or Allsky must cover the FOV while sharp '
          'tiles stream',
    );

    // Render the snapshot exactly as the painter layers it.
    final image = img.Image(
      width: canvas.width.toInt(),
      height: canvas.height.toInt(),
    );
    img.fill(image, color: img.ColorRgb8(6, 9, 16));

    // Allsky base (drawn as a faint full-canvas wash; the painter stretches the
    // whole-sky map, here represented as a uniform base tint to prove presence).
    if (snap.allsky != null) {
      _wash(image, img.ColorRgb8(18, 22, 34));
    }

    // Fallback (coarse) mesh fills — solid so gap-freeness is obvious.
    for (final tile in snap.fallbackTiles) {
      _fillMesh(image, tile.mesh, img.ColorRgb8(40, 70, 110));
    }
    // Primary (sharp) mesh outlines on top (empty here while in flight, but the
    // visible-set geometry proves registration).
    final vs = snap.visibleSet;
    expect(vs, isNotNull);
    for (final tile in vs!.tiles) {
      _meshOutline(image, tile.mesh, img.ColorRgb8(120, 200, 255));
    }

    // FOV rectangle registration check, drawn from the SAME plate scale.
    final fov = plateScale.drawRectFor(canvas, 2.4, ui.Offset.zero);
    _rectOutline(image, fov, img.ColorRgb8(255, 170, 60));

    // Verify the fallback mosaic actually covers the FOV center (never blank
    // there): the projected center must land inside at least one fallback mesh
    // bounds, OR the Allsky base is present.
    final center = vs.projection.raDecToScreen(
      target.raHours,
      target.decDegrees,
    );
    final centerCovered =
        snap.allsky != null ||
        snap.fallbackTiles.any((t) {
          final b = t.mesh.screenBounds;
          return b != null && b.contains(ui.Offset(center.dx, center.dy));
        });
    expect(
      centerCovered,
      isTrue,
      reason: 'FOV center must be covered by a fallback / Allsky base',
    );

    final png = Uint8List.fromList(img.encodePng(image));

    // Release the gate so the test tears down cleanly.
    gate.complete();
    await _settle();

    // Sample artifact for human inspection.
    final repoRoot = _repoRoot();
    final sampleDir = Directory('${repoRoot.path}/.hips_verify');
    sampleDir.createSync(recursive: true);
    final sample = File('${sampleDir.path}/hips_tile_loader_progressive.png');
    sample.writeAsBytesSync(png);
    // ignore: avoid_print
    print('HiPS C6 loader sample written: ${sample.absolute.path}');

    // Golden lock.
    final goldenDir = Directory('test/services/hips/goldens');
    goldenDir.createSync(recursive: true);
    final golden = File('${goldenDir.path}/hips_tile_loader_progressive.png');
    if (!golden.existsSync()) {
      golden.writeAsBytesSync(png);
      // ignore: avoid_print
      print('Golden created: ${golden.absolute.path}');
    } else {
      expect(
        png,
        golden.readAsBytesSync(),
        reason:
            'C6 loader render drifted from golden; if intentional, '
            'delete ${golden.path} to regenerate.',
      );
    }
  });
}

// Fake clock

class _FakeClock implements HipsLoaderClock {
  final List<_FakeTimer> _timers = <_FakeTimer>[];

  @override
  HipsLoaderTimer schedule(Duration delay, void Function() callback) {
    final t = _FakeTimer(callback);
    _timers.add(t);
    return t;
  }

  void fireAll() {
    for (final t in _timers.where((t) => t.isActive).toList()) {
      t.fire();
    }
  }
}

class _FakeTimer implements HipsLoaderTimer {
  final void Function() _callback;
  bool _fired = false;
  bool _cancelled = false;
  _FakeTimer(this._callback);
  @override
  void cancel() => _cancelled = true;
  @override
  bool get isActive => !_fired && !_cancelled;
  void fire() {
    if (!isActive) return;
    _fired = true;
    _callback();
  }
}

class _Gate {
  final Completer<void> _c = Completer<void>();
  Future<void> get future => _c.future;
  void complete() {
    if (!_c.isCompleted) _c.complete();
  }
}

Future<void> _settle() async {
  // Tile fetch goes through a real MockClient + a real off-thread image decode
  // (instantiateImageCodec), so give the engine a few real (tiny) ticks to
  // resolve those futures rather than only draining microtasks.
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

// Tiny raster helpers (no Flutter canvas needed for the artifact)

Uint8List _solidPng(int size, int r, int g, int b) {
  final image = img.Image(width: size, height: size);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodePng(image));
}

void _wash(img.Image image, img.Color color) {
  img.fill(image, color: color);
}

void _fillMesh(img.Image image, HipsTileMesh mesh, img.Color color) {
  final b = mesh.screenBounds;
  if (b == null) return;
  // Fill the convex-ish footprint by scan-filling each mesh cell as two
  // triangles approximated by their bounding rect (sufficient for the
  // gap-freeness visual; adjacent cells share edges so the union is seam-free).
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
