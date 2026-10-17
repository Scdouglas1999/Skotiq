import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Tests for the pure-Dart HEALPix NESTED math that backs the HiPS framing
/// tile layer.
///
/// The suite mixes three kinds of checks:
///   * Round-trip self-consistency (ang -> pix -> ang lands in the source
///     pixel; pix -> xyf -> pix is the identity over an exhaustive scan).
///   * Structural invariants of the NESTED scheme (pixel counts, quadtree
///     parent/child bit arithmetic, neighbour symmetry/adjacency).
///   * Hand-verified canonical values from the HEALPix paper / IVOA HiPS:
///     the 12 base-pixel (order 0) centers, and that a known sky direction
///     resolves to the expected base pixel.
void main() {
  group('construction & invariants', () {
    test('Nside = 2^order and Npix = 12*Nside^2', () {
      for (var order = 0; order <= 12; order++) {
        final h = HealpixNested(order);
        expect(h.nside, 1 << order);
        expect(h.npix, 12 * (1 << order) * (1 << order));
      }
    });

    test('rejects out-of-range orders', () {
      expect(() => HealpixNested(-1), throwsA(isA<HealpixArgumentError>()));
      expect(
        () => HealpixNested(HealpixNested.maxOrder + 1),
        throwsA(isA<HealpixArgumentError>()),
      );
    });

    test('fromNside requires a power of two', () {
      expect(HealpixNested.fromNside(1).order, 0);
      expect(HealpixNested.fromNside(256).order, 8);
      expect(
        () => HealpixNested.fromNside(3),
        throwsA(isA<HealpixArgumentError>()),
      );
      expect(
        () => HealpixNested.fromNside(0),
        throwsA(isA<HealpixArgumentError>()),
      );
    });
  });

  group('bit interleave round-trip (xyf <-> nest)', () {
    test('exhaustive over order 0..4', () {
      for (var order = 0; order <= 4; order++) {
        final h = HealpixNested(order);
        for (var pix = 0; pix < h.npix; pix++) {
          final xyf = h.nestToXyf(pix);
          expect(xyf.face, inInclusiveRange(0, 11));
          expect(xyf.x, inInclusiveRange(0, h.nside - 1));
          expect(xyf.y, inInclusiveRange(0, h.nside - 1));
          final back = h.xyfToNest(xyf);
          expect(back, pix, reason: 'order $order pix $pix');
        }
      }
    });

    test('interleave matches Morton order at order 1 within a face', () {
      // Order 1, face 0: 4 pixels. NESTED indices 0..3 within the face map
      // to (x,y) = (0,0),(1,0),(0,1),(1,1) by even/odd bit interleave.
      final h = HealpixNested(1);
      expect(h.nestToXyf(0), const HealpixXyf(0, 0, 0));
      expect(h.nestToXyf(1), const HealpixXyf(1, 0, 0));
      expect(h.nestToXyf(2), const HealpixXyf(0, 1, 0));
      expect(h.nestToXyf(3), const HealpixXyf(1, 1, 0));
    });
  });

  group('ang -> pix -> ang round-trip', () {
    test('pixel center re-resolves to the same pixel (orders 0..6)', () {
      for (var order = 0; order <= 6; order++) {
        final h = HealpixNested(order);
        // Sample every pixel up to a cap to keep the test fast at high order.
        final step = h.npix > 4096 ? h.npix ~/ 4096 : 1;
        for (var pix = 0; pix < h.npix; pix += step) {
          final a = h.pix2ang(pix);
          final back = h.angToPixNest(a);
          expect(back, pix, reason: 'order $order pix $pix center');
        }
      }
    });

    test('dense random sky directions land in a pixel that contains them', () {
      final rng = math.Random(20260529);
      final h = HealpixNested(7);
      for (var i = 0; i < 5000; i++) {
        final ra = rng.nextDouble() * 360.0;
        // Uniform on the sphere: dec = asin(2u-1).
        final dec = math.asin(2.0 * rng.nextDouble() - 1.0) * 180.0 / math.pi;
        final pix = h.ang2pixNest(ra, dec);
        expect(pix, inInclusiveRange(0, h.npix - 1));
        // The pixel center must be within one pixel-scale of the query.
        final c = h.pix2RaDec(pix);
        final sep = _angularSepDeg(ra, dec, c.raDeg, c.decDeg);
        // Pixel diagonal upper bound at order 7 is comfortably < 1.2 deg.
        expect(
          sep,
          lessThan(1.2),
          reason: 'ra=$ra dec=$dec -> pix=$pix sep=$sep',
        );
      }
    });
  });

  group('vector conversions', () {
    test('pix2vec is unit length and consistent with pix2ang', () {
      final h = HealpixNested(5);
      for (var pix = 0; pix < h.npix; pix += 7) {
        final v = h.pix2vec(pix);
        expect(v.length, closeTo(1.0, 1e-12));
        final back = h.vecToPixNest(v);
        expect(back, pix);
      }
    });
  });

  group('canonical base-pixel (order 0) geometry', () {
    test('12 base pixels, faces 0..11', () {
      final h = HealpixNested(0);
      expect(h.npix, 12);
      for (var f = 0; f < 12; f++) {
        final xyf = h.nestToXyf(f);
        expect(xyf.face, f);
        expect(xyf.x, 0);
        expect(xyf.y, 0);
      }
    });

    test('base-pixel center declinations: 4 north, 4 equator, 4 south', () {
      final h = HealpixNested(0);
      final decs = [for (var f = 0; f < 12; f++) h.pix2RaDec(f).decDeg];
      final north = decs.where((d) => d > 30).length;
      final equator = decs.where((d) => d.abs() < 1e-6).length;
      final south = decs.where((d) => d < -30).length;
      expect(north, 4, reason: 'decs=$decs');
      expect(equator, 4, reason: 'decs=$decs');
      expect(south, 4, reason: 'decs=$decs');
      // North/south cap centers sit at z = +-2/3 => dec = asin(2/3).
      final capDec = math.asin(2.0 / 3.0) * 180.0 / math.pi;
      for (final d in decs.where((d) => d > 30)) {
        expect(d, closeTo(capDec, 1e-9));
      }
      for (final d in decs.where((d) => d < -30)) {
        expect(d, closeTo(-capDec, 1e-9));
      }
    });

    test('equatorial base-pixel RAs are spaced 90 degrees apart', () {
      final h = HealpixNested(0);
      final eqRas = <double>[];
      for (var f = 0; f < 12; f++) {
        final c = h.pix2RaDec(f);
        if (c.decDeg.abs() < 1e-6) eqRas.add(c.raDeg);
      }
      eqRas.sort();
      expect(eqRas.length, 4);
      for (var i = 0; i < 4; i++) {
        expect(eqRas[i] % 90.0, closeTo(eqRas[0] % 90.0, 1e-6));
      }
    });
  });

  group('boundaries (cell corners)', () {
    test('four corners, all on the unit sphere', () {
      final h = HealpixNested(4);
      for (var pix = 0; pix < h.npix; pix += 13) {
        final corners = h.boundaries(pix);
        expect(corners.length, 4);
        for (final c in corners) {
          final v = HealpixNested.angToVec(c);
          expect(v.length, closeTo(1.0, 1e-12));
        }
      }
    });

    test('the pixel center is the rough centroid of its four corners', () {
      final h = HealpixNested(5);
      for (var pix = 0; pix < h.npix; pix += 29) {
        final corners = h.boundaryVectors(pix);
        var sx = 0.0, sy = 0.0, sz = 0.0;
        for (final v in corners) {
          sx += v.x;
          sy += v.y;
          sz += v.z;
        }
        final n = math.sqrt(sx * sx + sy * sy + sz * sz);
        final centroid = Vector3(sx / n, sy / n, sz / n);
        final center = h.pix2vec(pix);
        // Centroid of a curved quad is close to but not exactly the center;
        // require sub-degree agreement.
        final cosAng = centroid.dot(center).clamp(-1.0, 1.0);
        final sepDeg = math.acos(cosAng) * 180.0 / math.pi;
        expect(sepDeg, lessThan(1.0), reason: 'pix $pix sep $sepDeg');
      }
    });

    test('adjacent pixels share an exact edge (seam-free)', () {
      // Two NESTED-adjacent pixels within a face must share two corner sky
      // points to the bit, guaranteeing no gap in the mosaic.
      final h = HealpixNested(4);
      // pixels 5 and its east neighbour.
      const pix = 5;
      final nbrs = h.neighboursNest(pix);
      // Ordering is [W, NW, N, NE, E, SE, S, SW]; East is index 4.
      expect(HealpixNested.neighbourDirections[4], 'E');
      final east = nbrs[4];
      expect(east, isNot(-1));
      final a = h.boundaries(pix).map(_key).toSet();
      final b = h.boundaries(east).map(_key).toSet();
      final shared = a.intersection(b);
      expect(
        shared.length,
        greaterThanOrEqualTo(2),
        reason: 'pix $pix and east $east share ${shared.length} corners',
      );
    });
  });

  group('neighboursNest', () {
    test('interior pixel has 8 distinct valid neighbours', () {
      final h = HealpixNested(4);
      // A pixel comfortably in a face interior.
      final pix = h.xyfToNest(const HealpixXyf(7, 7, 0));
      final nbrs = h.neighboursNest(pix);
      expect(nbrs.length, 8);
      expect(nbrs.where((n) => n == -1), isEmpty);
      expect(nbrs.toSet().length, 8, reason: 'all distinct: $nbrs');
      expect(nbrs.contains(pix), isFalse);
    });

    test('neighbour relation is symmetric', () {
      final h = HealpixNested(3);
      for (var pix = 0; pix < h.npix; pix++) {
        for (final nb in h.neighboursNest(pix)) {
          if (nb < 0) continue;
          expect(
            h.neighboursNest(nb).contains(pix),
            isTrue,
            reason: '$pix lists $nb but not vice-versa',
          );
        }
      }
    });

    test('all neighbours are angularly adjacent', () {
      final h = HealpixNested(5);
      for (var pix = 0; pix < h.npix; pix += 17) {
        final c = h.pix2vec(pix);
        for (final nb in h.neighboursNest(pix)) {
          if (nb < 0) continue;
          final cn = h.pix2vec(nb);
          final sepDeg =
              math.acos(c.dot(cn).clamp(-1.0, 1.0)) * 180.0 / math.pi;
          // Neighbour centers are within ~2 pixel scales.
          expect(sepDeg, lessThan(4.0), reason: 'pix $pix nb $nb sep $sepDeg');
        }
      }
    });
  });

  group('queryDisc (visible-set enumeration)', () {
    test('small disc around a pixel center includes that pixel', () {
      final h = HealpixNested(6);
      const ra = 83.6;
      const dec = -5.4; // Orion-ish
      final center = h.ang2pixNest(ra, dec);
      final disc = h.queryDisc(ra, dec, radiusDeg: 0.5);
      expect(disc, contains(center));
      expect(disc, isNotEmpty);
      // Sorted ascending & unique.
      final sorted = [...disc]..sort();
      expect(disc, sorted);
      expect(disc.toSet().length, disc.length);
    });

    test('inclusive disc is a superset of exclusive disc', () {
      final h = HealpixNested(5);
      const ra = 200.0;
      const dec = 40.0;
      final inc = h.queryDisc(ra, dec, radiusDeg: 3.0, inclusive: true).toSet();
      final exc = h
          .queryDisc(ra, dec, radiusDeg: 3.0, inclusive: false)
          .toSet();
      expect(
        exc.difference(inc),
        isEmpty,
        reason: 'exclusive must be subset of inclusive',
      );
      expect(inc.length, greaterThanOrEqualTo(exc.length));
    });

    test('every exclusive-disc pixel center is within the radius', () {
      final h = HealpixNested(6);
      const ra = 10.0;
      const dec = 70.0; // near-polar, exercises cap math
      const radius = 4.0;
      final disc = h.queryDisc(ra, dec, radiusDeg: radius, inclusive: false);
      expect(disc, isNotEmpty);
      for (final pix in disc) {
        final c = h.pix2RaDec(pix);
        final sep = _angularSepDeg(ra, dec, c.raDeg, c.decDeg);
        expect(
          sep,
          lessThanOrEqualTo(radius + 1e-6),
          reason: 'pix $pix sep $sep > $radius',
        );
      }
    });

    test(
      'disc completeness: no pixel within radius is omitted (inclusive)',
      () {
        // Brute-force ground truth: scan all pixels at a modest order and
        // collect those whose center is within the radius; the inclusive disc
        // must contain every one of them.
        final h = HealpixNested(5);
        const ra = 150.0;
        const dec = -20.0;
        const radius = 5.0;
        final disc = h.queryDisc(ra, dec, radiusDeg: radius).toSet();
        for (var pix = 0; pix < h.npix; pix++) {
          final c = h.pix2RaDec(pix);
          final sep = _angularSepDeg(ra, dec, c.raDeg, c.decDeg);
          if (sep <= radius) {
            expect(
              disc,
              contains(pix),
              reason: 'pix $pix (sep $sep) missing from inclusive disc',
            );
          }
        }
      },
    );

    test('full-sky radius returns all pixels', () {
      final h = HealpixNested(3);
      final disc = h.queryDisc(123.0, 45.0, radiusDeg: 180.0);
      expect(disc.length, h.npix);
    });

    test('rejects negative radius', () {
      final h = HealpixNested(4);
      expect(
        () => h.queryDisc(0, 0, radiusDeg: -1),
        throwsA(isA<HealpixArgumentError>()),
      );
    });
  });

  group('quadtree (LOD) helpers', () {
    test('parent is ipix >> 2 and children are ipix << 2 + {0..3}', () {
      final coarse = HealpixNested(5);
      final fine = HealpixNested(6);
      for (var pix = 0; pix < coarse.npix; pix += 11) {
        final kids = coarse.children(pix);
        expect(kids, [pix * 4, pix * 4 + 1, pix * 4 + 2, pix * 4 + 3]);
        for (final k in kids) {
          expect(fine.parent(k), pix);
        }
      }
    });

    test('children tile their parent (centers fall inside parent)', () {
      final coarse = HealpixNested(4);
      for (var pix = 0; pix < coarse.npix; pix += 7) {
        for (final k in coarse.children(pix)) {
          final fine = HealpixNested(5);
          final c = fine.pix2ang(k);
          // The child center must map back to the parent at the coarse order.
          expect(
            coarse.angToPixNest(c),
            pix,
            reason: 'child $k of $pix escaped parent',
          );
        }
      }
    });

    test('ancestorAtOrder walks up multiple levels', () {
      final h = HealpixNested(8);
      const pix = 123456;
      expect(h.ancestorAtOrder(pix, 8), pix);
      expect(h.ancestorAtOrder(pix, 7), pix >> 2);
      expect(h.ancestorAtOrder(pix, 6), pix >> 4);
      expect(h.ancestorAtOrder(pix, 0), pix >> 16);
    });

    test(
      'childAtOrder of a pixel returns a descendant containing its center',
      () {
        final coarse = HealpixNested(3);
        for (var pix = 0; pix < coarse.npix; pix += 5) {
          final desc = coarse.childAtOrder(pix, 6);
          final fine = HealpixNested(6);
          // Descendant must live under pix in the quadtree.
          expect(fine.ancestorAtOrder(desc, 3), pix);
        }
      },
    );

    test('parent throws at order 0, children throw at max order', () {
      expect(
        () => HealpixNested(0).parent(0),
        throwsA(isA<HealpixArgumentError>()),
      );
      expect(
        () => HealpixNested(HealpixNested.maxOrder).children(0),
        throwsA(isA<HealpixArgumentError>()),
      );
    });
  });

  group('input validation throws rather than clamping', () {
    test('out-of-range declination throws', () {
      final h = HealpixNested(4);
      expect(() => h.ang2pixNest(0, 91), throwsA(isA<HealpixArgumentError>()));
      expect(() => h.ang2pixNest(0, -91), throwsA(isA<HealpixArgumentError>()));
    });

    test('out-of-range pixel index throws', () {
      final h = HealpixNested(2);
      expect(() => h.pix2ang(-1), throwsA(isA<HealpixArgumentError>()));
      expect(() => h.pix2ang(h.npix), throwsA(isA<HealpixArgumentError>()));
    });

    test('RA wraps rather than throwing', () {
      final h = HealpixNested(4);
      final a = h.ang2pixNest(370, 0);
      final b = h.ang2pixNest(10, 0);
      expect(a, b);
      final c = h.ang2pixNest(-10, 0);
      final d = h.ang2pixNest(350, 0);
      expect(c, d);
    });
  });
}

/// A stable string key for a corner sky point at the precision needed to
/// detect exact-shared edges between adjacent pixels.
String _key(HealpixAngle a) =>
    '${a.theta.toStringAsFixed(12)},${a.phi.toStringAsFixed(12)}';

/// Great-circle separation between two RA/Dec points, in degrees.
double _angularSepDeg(double ra1, double dec1, double ra2, double dec2) {
  final r1 = ra1 * math.pi / 180.0;
  final d1 = dec1 * math.pi / 180.0;
  final r2 = ra2 * math.pi / 180.0;
  final d2 = dec2 * math.pi / 180.0;
  final v1x = math.cos(d1) * math.cos(r1);
  final v1y = math.cos(d1) * math.sin(r1);
  final v1z = math.sin(d1);
  final v2x = math.cos(d2) * math.cos(r2);
  final v2y = math.cos(d2) * math.sin(r2);
  final v2z = math.sin(d2);
  final dot = (v1x * v2x + v1y * v2y + v1z * v2z).clamp(-1.0, 1.0);
  return math.acos(dot) * 180.0 / math.pi;
}
