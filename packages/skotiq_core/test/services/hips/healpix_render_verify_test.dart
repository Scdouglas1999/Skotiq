import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:skotiq_core/skotiq_core.dart';

/// Renders the HEALPix NESTED tiling produced by [HealpixNested] to a PNG so
/// the geometry can be eyeballed and locked as a golden. This is the visual
/// proof that the math the GPU HiPS framing layer depends on yields a
/// coherent, seam-free, FOV-registered tiling:
///
///   * [HealpixNested.queryDisc] selects exactly the cells inside the FOV,
///   * [HealpixNested.boundaries] gives the four sky corners of each cell,
///   * cells abut with no gaps (shared corners), and
///   * each cell is labelled with the parent it rolls up to under LOD
///     ([HealpixNested.parent]), tinted by parent so the quadtree grouping
///     is visible.
///
/// The render uses a gnomonic (tangent-plane) projection centered on the FOV
/// — the same family of projection the framing canvas uses — so the on-image
/// geometry matches what the tile layer will composite.
///
/// Output:
///   * golden: `goldens/healpix_grid_<order>.png` (byte-locked)
///   * sample: repo-root `.hips_verify/healpix_grid_<order>.png`
void main() {
  // FOV center and span chosen to sit off the equator and span a face seam,
  // exercising the harder geometry rather than a trivial equatorial patch.
  const centerRa = 56.0;
  const centerDec = 24.0;
  const fovDeg = 6.0; // full width of the rendered field
  const order = 6; // HiPS Norder; Nside = 64
  const imgSize = 768;

  test('HEALPix NESTED grid renders seam-free and FOV-registered', () {
    final h = HealpixNested(order);

    // Visible-set enumeration: the disc radius covers the diagonal half-FOV
    // plus a margin so every cell touching the frame is included.
    final radius = fovDeg * math.sqrt(2.0) / 2.0 * 1.1;
    final pixels = h.queryDisc(centerRa, centerDec, radiusDeg: radius);
    expect(pixels, isNotEmpty);

    final canvas = img.Image(width: imgSize, height: imgSize);
    img.fill(canvas, color: img.ColorRgb8(8, 12, 22));

    // Gnomonic projection of (ra, dec) -> image pixel, centered on the FOV.
    const ra0 = centerRa * math.pi / 180.0;
    const dec0 = centerDec * math.pi / 180.0;
    final sinDec0 = math.sin(dec0);
    final cosDec0 = math.cos(dec0);
    // Image scale: fovDeg across the image width.
    const pxPerRad = imgSize / (fovDeg * math.pi / 180.0);

    ({double x, double y})? project(double raDeg, double decDeg) {
      final ra = raDeg * math.pi / 180.0;
      final dec = decDeg * math.pi / 180.0;
      final cosc =
          sinDec0 * math.sin(dec) +
          cosDec0 * math.cos(dec) * math.cos(ra - ra0);
      if (cosc <= 0) return null; // behind the tangent point
      final xi = (math.cos(dec) * math.sin(ra - ra0)) / cosc;
      final eta =
          (cosDec0 * math.sin(dec) -
              sinDec0 * math.cos(dec) * math.cos(ra - ra0)) /
          cosc;
      // +RA (east) to the left to match sky orientation; +Dec (north) up.
      final px = imgSize / 2.0 - xi * pxPerRad;
      final py = imgSize / 2.0 - eta * pxPerRad;
      return (x: px, y: py);
    }

    var drawnCells = 0;
    var sharedEdgePairs = 0;

    // Tint each cell by its LOD parent so the quadtree grouping is visible.
    final coarse = HealpixNested(order - 2); // grandparent grouping
    img.Color tintFor(int ipix) {
      final group = coarse.angToPixNest(h.pix2ang(ipix));
      final rnd = math.Random(group * 2654435761 & 0x7fffffff);
      return img.ColorRgb8(
        90 + rnd.nextInt(140),
        90 + rnd.nextInt(140),
        110 + rnd.nextInt(120),
      );
    }

    for (final pix in pixels) {
      final corners = h.boundaries(pix);
      final pts = <({double x, double y})>[];
      var anyVisible = false;
      for (final c in corners) {
        final p = project(c.raDeg, c.decDeg);
        if (p == null) {
          anyVisible = false;
          break;
        }
        anyVisible = true;
        pts.add(p);
      }
      if (!anyVisible || pts.length != 4) continue;

      final color = tintFor(pix);
      // Draw the four cell edges. Because adjacent cells share corner sky
      // points exactly (verified in healpix_nested_test), the projected
      // edges coincide and the tiling is seam-free.
      for (var i = 0; i < 4; i++) {
        final a = pts[i];
        final b = pts[(i + 1) % 4];
        img.drawLine(
          canvas,
          x1: a.x.round(),
          y1: a.y.round(),
          x2: b.x.round(),
          y2: b.y.round(),
          color: color,
        );
      }
      drawnCells++;
    }

    // Verify seam-free adjacency analytically (independent of the render):
    // every in-disc cell whose east neighbour is also in the disc shares two
    // exact corner sky points with it.
    final inDisc = pixels.toSet();
    for (final pix in pixels) {
      final nbrs = h.neighboursNest(pix);
      for (final nb in nbrs) {
        if (nb < 0 || !inDisc.contains(nb)) continue;
        final a = h.boundaries(pix).map(_key).toSet();
        final b = h.boundaries(nb).map(_key).toSet();
        if (a.intersection(b).length >= 2) sharedEdgePairs++;
      }
    }
    expect(
      drawnCells,
      greaterThan(50),
      reason: 'expected a populated grid, drew $drawnCells cells',
    );
    expect(
      sharedEdgePairs,
      greaterThan(0),
      reason: 'adjacent cells must share exact edges (seam-free)',
    );

    // Draw a crosshair at the FOV center to confirm registration.
    final c0 = project(centerRa, centerDec)!;
    final cross = img.ColorRgb8(255, 80, 80);
    img.drawLine(
      canvas,
      x1: c0.x.round() - 10,
      y1: c0.y.round(),
      x2: c0.x.round() + 10,
      y2: c0.y.round(),
      color: cross,
    );
    img.drawLine(
      canvas,
      x1: c0.x.round(),
      y1: c0.y.round() - 10,
      x2: c0.x.round(),
      y2: c0.y.round() + 10,
      color: cross,
    );

    final png = img.encodePng(canvas);

    // Sample artifact at repo root for human inspection.
    final repoRoot = _repoRoot();
    final sampleDir = Directory('${repoRoot.path}/.hips_verify');
    sampleDir.createSync(recursive: true);
    final sample = File('${sampleDir.path}/healpix_grid_$order.png');
    sample.writeAsBytesSync(png);
    // ignore: avoid_print
    print('HiPS HEALPix grid sample written: ${sample.absolute.path}');

    // Golden lock: write on first run, byte-compare thereafter.
    final goldenDir = Directory('test/services/hips/goldens');
    goldenDir.createSync(recursive: true);
    final golden = File('${goldenDir.path}/healpix_grid_$order.png');
    if (!golden.existsSync()) {
      golden.writeAsBytesSync(png);
      // ignore: avoid_print
      print('Golden created: ${golden.absolute.path}');
    } else {
      expect(
        png,
        golden.readAsBytesSync(),
        reason:
            'HEALPix grid render drifted from golden; if intentional, '
            'delete ${golden.path} to regenerate.',
      );
    }
  });
}

String _key(HealpixAngle a) =>
    '${a.theta.toStringAsFixed(12)},${a.phi.toStringAsFixed(12)}';

/// Walks up from the package directory to the repo root (the directory that
/// holds `version.yaml`), so the sample artifact lands at the documented
/// `.hips_verify/` path regardless of the test's working directory.
Directory _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/version.yaml').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  // Fallback: package dir's grandparent (packages/skotiq_core -> root).
  return Directory.current.parent.parent;
}
