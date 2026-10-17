// HARD VALIDATION of the HiPS framing tile-image texture convention, against the
// committed REAL DSS2 fixture tiles (the M31 field).
//
// Why this exists: geometry registration alone (mesh vertex positions) does NOT
// catch a wrong per-tile TEXTURE convention — the map from a mesh `(u,v)` to the
// tile image pixel `(tx,ty)`. With the vertex mesh pixel-perfect, a wrong texture
// map still slides/shears the actual imagery inside each correctly-placed quad, so
// an extended object (a galaxy) develops diagonal content seams and stars look
// oval/displaced (worst at high declination, where the HEALPix diamonds are most
// skewed). A registration test that checks only vertex geometry passes while the
// visible result is wrong.
//
// The decisive, projection-free, render-free ground truth is SEAM CONTINUITY: two
// HEALPix diamonds that share a sky edge must show byte-identical real content
// along that shared edge. Measuring the edge-content correlation of the committed
// real DSS2 tiles across every candidate `(u,v) -> (tx,ty)` map uniquely picks the
// correct convention — and it must be the one the painter uses
// (`HipsTileLayerPainter._emitVertex`): `tx = v, ty = u` (a pure transpose, no
// flip). A `ty = 1 - u` flip scores far worse here and tears the rendered M31
// mosaic visibly; the committed
// `test/fixtures/hips/goldens/hips_fixture_m31_mosaic.png` byte-golden locks the
// correct render of the real painter as the painter-coupled guard.
//
// Determinism: committed real bytes, production decode path, no network.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/hips/healpix_nested.dart';

import '../../fixtures/hips/fixture_field.dart' as fx;
import 'support/hips_fixture_render.dart';

/// Tightly-packed RGBA8888 + dims of a [ui.Image].
Future<({Uint8List px, int w, int h})> _rgba(ui.Image im) async {
  final bd = (await im.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  return (px: bd.buffer.asUint8List(), w: im.width, h: im.height);
}

double _lum(Uint8List px, int w, int x, int y) {
  final i = (y * w + x) * 4;
  return (px[i] + px[i + 1] + px[i + 2]) / 3.0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'SEAM CONTINUITY: adjacent real DSS2 tiles agree along their shared sky '
      'edge only under the painter texture convention (tx=v, ty=u)', () async {
    final hp = HealpixNested(fx.primaryNorder);

    // Decode every committed primary tile.
    final imgs = <int, ({Uint8List px, int w, int h})>{};
    for (final id in fx.primaryTiles) {
      final bytes = fixtureTileBytesOrNull(id);
      if (bytes == null) continue;
      imgs[id.npix] = await _rgba(await decodeFixtureImage(bytes));
    }
    expect(imgs.length, greaterThan(8),
        reason: 'Need a decent set of committed tiles to find shared edges.');

    // The convention the painter uses: mesh (u,v) -> image (tx=v, ty=u).
    (double, double) painterConv(double u, double v) => (v, u);
    // The two strongest WRONG alternatives — a flip (the previously-shipped bug)
    // and the other transpose — which must both score strictly worse.
    (double, double) flipConv(double u, double v) => (v, 1 - u);
    (double, double) otherTranspose(double u, double v) => (u, v);

    List<(double, double)> skyCorners(int npix) {
      final xyf = hp.nestToXyf(npix);
      final ix = xyf.x, iy = xyf.y, f = xyf.face;
      return [
        for (final c in const [
          [0.0, 0.0],
          [1.0, 0.0],
          [1.0, 1.0],
          [0.0, 1.0],
        ])
          () {
            final a = hp.xyfToAng(HealpixXyf(ix + c[0], iy + c[1], f));
            return (a.raDeg, a.decDeg);
          }(),
      ];
    }

    bool sameSky((double, double) p, (double, double) q) =>
        (p.$1 - q.$1).abs() < 1e-6 && (p.$2 - q.$2).abs() < 1e-6;

    // The intra-tile (u,v) parameter of a given shared sky corner for [npix].
    (double, double) paramOf(int npix, (double, double) sky) {
      final xyf = hp.nestToXyf(npix);
      final ix = xyf.x, iy = xyf.y, f = xyf.face;
      for (final c in const [
        [0.0, 0.0],
        [1.0, 0.0],
        [1.0, 1.0],
        [0.0, 1.0],
      ]) {
        final a = hp.xyfToAng(HealpixXyf(ix + c[0], iy + c[1], f));
        if ((a.raDeg - sky.$1).abs() < 1e-6 &&
            (a.decDeg - sky.$2).abs() < 1e-6) {
          return (c[0], c[1]);
        }
      }
      return (-1.0, -1.0);
    }

    double sampleLum(
        ({Uint8List px, int w, int h}) im, double px01, double py01) {
      final x = (px01 * (im.w - 1)).clamp(0.0, im.w - 1.0).round();
      final y = (py01 * (im.h - 1)).clamp(0.0, im.h - 1.0).round();
      return _lum(im.px, im.w, x, y);
    }

    double corr(List<double> a, List<double> b) {
      final n = a.length;
      var ma = 0.0, mb = 0.0;
      for (var i = 0; i < n; i++) {
        ma += a[i];
        mb += b[i];
      }
      ma /= n;
      mb /= n;
      var num = 0.0, da = 0.0, db = 0.0;
      for (var i = 0; i < n; i++) {
        final x = a[i] - ma, y = b[i] - mb;
        num += x * y;
        da += x * x;
        db += y * y;
      }
      if (da <= 0 || db <= 0) return 0;
      return num / (math.sqrt(da) * math.sqrt(db));
    }

    double meanEdgeCorr((double, double) Function(double, double) conv) {
      final samples = <double>[];
      final npixList = imgs.keys.toList();
      for (var i = 0; i < npixList.length; i++) {
        for (var j = i + 1; j < npixList.length; j++) {
          final a = npixList[i], b = npixList[j];
          final ca = skyCorners(a), cb = skyCorners(b);
          final shared = <(double, double)>[];
          for (final p in ca) {
            for (final q in cb) {
              if (sameSky(p, q)) shared.add(p);
            }
          }
          if (shared.length != 2) continue; // not edge-adjacent
          final a0 = paramOf(a, shared[0]), a1 = paramOf(a, shared[1]);
          final b0 = paramOf(b, shared[0]), b1 = paramOf(b, shared[1]);
          if (a0.$1 < 0 || b0.$1 < 0) continue;
          final imA = imgs[a]!, imB = imgs[b]!;
          final lumA = <double>[], lumB = <double>[];
          for (var s = 0; s <= 48; s++) {
            final t = s / 48.0;
            final ua =
                conv(a0.$1 + (a1.$1 - a0.$1) * t, a0.$2 + (a1.$2 - a0.$2) * t);
            final ub =
                conv(b0.$1 + (b1.$1 - b0.$1) * t, b0.$2 + (b1.$2 - b0.$2) * t);
            lumA.add(sampleLum(imA, ua.$1, ua.$2));
            lumB.add(sampleLum(imB, ub.$1, ub.$2));
          }
          samples.add(corr(lumA, lumB));
        }
      }
      expect(samples, isNotEmpty,
          reason: 'No edge-adjacent committed tile pairs were found.');
      return samples.reduce((a, b) => a + b) / samples.length;
    }

    final painterScore = meanEdgeCorr(painterConv);
    final flipScore = meanEdgeCorr(flipConv);
    final otherScore = meanEdgeCorr(otherTranspose);

    expect(painterScore, greaterThan(flipScore + 0.1),
        reason:
            'The painter convention (tx=v, ty=u) must join real neighbouring '
            'tiles strictly better than the flipped (tx=v, ty=1-u) map — got '
            'painter=$painterScore vs flip=$flipScore. A flip re-opens the '
            'diagonal content seams that shear stars at high declination.');
    expect(painterScore, greaterThan(otherScore + 0.1),
        reason: 'The painter convention must beat the other transpose '
            '(tx=u, ty=v) — got painter=$painterScore vs other=$otherScore.');
    expect(painterScore, greaterThan(0.4),
        reason: 'Adjacent real-tile edges should correlate well under the '
            'correct convention; got $painterScore.');
  });
}
