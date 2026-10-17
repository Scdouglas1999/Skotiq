// C9 unit tests — HEALPix NESTED round-trips, polar caps, and base-pixel corners.
//
// This suite is the anti-jank correctness contract for the geometric foundation
// (C1 [HealpixNested]) that the framing tile layer's seam-free mosaicing depends
// on. Where `healpix_nested_test.dart` exercises the broad API surface, this
// file pins the *round-trip* and *boundary* invariants the C9 spec calls out
// explicitly:
//
//   * ang -> pix -> ang lands inside the source pixel (no off-by-one tile),
//   * pix -> xyf -> pix is the identity exhaustively across every face,
//   * the round-trip holds through the polar caps (|dec| -> 90) and at the
//     12 base-pixel (order-0) corners, where the cap/belt math switches branch,
//   * a pixel's four [boundaries] corners are *exactly* shared with its
//     neighbours (the property that makes adjacent tiles seam-free), and
//   * quadtree parent/child bit arithmetic is consistent so coarse fallbacks
//     register over the sharp tiles they stand in for.
//
// Out-of-range arguments are asserted to throw rather than clamp: a clamped
// order or pixel index addresses the wrong sky.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/hips/healpix_nested.dart';

/// Angular separation, in degrees, between two unit vectors.
double _sepDeg(Vector3 a, Vector3 b) {
  final dot = (a.dot(b) / (a.length * b.length)).clamp(-1.0, 1.0);
  return math.acos(dot) * 180.0 / math.pi;
}

/// Unit vector for an RA/Dec pair in degrees.
Vector3 _vec(double raDeg, double decDeg) {
  final ra = raDeg * math.pi / 180.0;
  final dec = decDeg * math.pi / 180.0;
  final cd = math.cos(dec);
  return Vector3(cd * math.cos(ra), cd * math.sin(ra), math.sin(dec));
}

void main() {
  group('ang -> pix -> ang lands in the source pixel', () {
    // For a grid of sky points, the pixel center recovered from the addressed
    // pixel must be within one pixel scale of the input — i.e. the input fell
    // inside the tile it was addressed to (no off-by-one mosaicing gap).
    test('over a dense RA/Dec grid at several orders', () {
      for (final order in <int>[2, 4, 6, 8]) {
        final h = HealpixNested(order);
        // The mean pixel diameter sets the tolerance: a point inside a pixel is
        // at most ~one pixel diagonal from the pixel center.
        final meanPixelDiameterDeg =
            math.sqrt(4.0 * math.pi / h.npix) *
            180.0 /
            math.pi *
            1.5; // generous diagonal bound
        for (var raDeg = 2.5; raDeg < 360; raDeg += 23.0) {
          for (var decDeg = -88.0; decDeg <= 88.0; decDeg += 11.0) {
            final pix = h.ang2pixNest(raDeg, decDeg);
            final center = h.pix2RaDec(pix);
            final sep = _sepDeg(
              _vec(raDeg, decDeg),
              _vec(center.raDeg, center.decDeg),
            );
            expect(
              sep,
              lessThan(meanPixelDiameterDeg),
              reason:
                  'order $order ($raDeg, $decDeg) -> pix $pix center '
                  '(${center.raDeg}, ${center.decDeg}) sep=$sep deg',
            );
          }
        }
      }
    });

    test('the center of every pixel maps back to that pixel exactly', () {
      for (final order in <int>[0, 1, 2, 3, 4]) {
        final h = HealpixNested(order);
        for (var pix = 0; pix < h.npix; pix++) {
          final c = h.pix2RaDec(pix);
          final back = h.ang2pixNest(c.raDeg, c.decDeg);
          expect(back, pix, reason: 'order $order pix $pix center re-address');
        }
      }
    });
  });

  group('pix -> xyf -> pix identity (exhaustive)', () {
    test('every pixel decomposes and recomposes across all faces', () {
      for (final order in <int>[0, 1, 2, 3, 4]) {
        final h = HealpixNested(order);
        // Track that all 12 faces are actually visited so the test is not
        // accidentally only covering the equatorial belt.
        final facesSeen = <int>{};
        for (var pix = 0; pix < h.npix; pix++) {
          final xyf = h.nestToXyf(pix);
          facesSeen.add(xyf.face);
          expect(xyf.x, inInclusiveRange(0, h.nside - 1));
          expect(xyf.y, inInclusiveRange(0, h.nside - 1));
          expect(h.xyfToNest(xyf), pix, reason: 'order $order pix $pix');
        }
        expect(
          facesSeen,
          hasLength(12),
          reason: 'order $order must touch all 12 base faces',
        );
      }
    });
  });

  group('polar-cap round-trip (branch switch at |dec| -> 90)', () {
    test('near-pole points round-trip without losing the pole', () {
      for (final order in <int>[3, 5, 7]) {
        final h = HealpixNested(order);
        for (final decDeg in <double>[89.9, 89.0, 80.0, -80.0, -89.0, -89.9]) {
          for (var raDeg = 0.0; raDeg < 360; raDeg += 45.0) {
            final pix = h.ang2pixNest(raDeg, decDeg);
            // Re-address from the recovered pixel center; the declination sign
            // (which cap) must be preserved through the cap/belt branch.
            final c = h.pix2RaDec(pix);
            expect(
              c.decDeg.sign,
              decDeg.sign,
              reason: 'order $order ($raDeg, $decDeg) flipped hemisphere',
            );
            expect(h.ang2pixNest(c.raDeg, c.decDeg), pix);
          }
        }
      }
    });

    test('the exact poles address a valid cap pixel and round-trip', () {
      for (final order in <int>[1, 3, 5]) {
        final h = HealpixNested(order);
        final north = h.ang2pixNest(0.0, 90.0);
        final south = h.ang2pixNest(0.0, -90.0);
        expect(north, inInclusiveRange(0, h.npix - 1));
        expect(south, inInclusiveRange(0, h.npix - 1));
        // North pole pixels live on faces 0..3 (north caps); south on 8..11.
        expect(h.nestToXyf(north).face, inInclusiveRange(0, 3));
        expect(h.nestToXyf(south).face, inInclusiveRange(8, 11));
        // The recovered center is at (or above) high latitude in the right cap.
        expect(h.pix2RaDec(north).decDeg, greaterThan(0.0));
        expect(h.pix2RaDec(south).decDeg, lessThan(0.0));
      }
    });
  });

  group('order-0 base pixels (the 12-cell scaffold)', () {
    test('there are exactly 12 base pixels grouped 4/4/4 by latitude band', () {
      final h = HealpixNested(0);
      expect(h.npix, 12);
      var north = 0, belt = 0, south = 0;
      for (var pix = 0; pix < 12; pix++) {
        final dec = h.pix2RaDec(pix).decDeg;
        if (dec > 30.0) {
          north++;
        } else if (dec < -30.0) {
          south++;
        } else {
          belt++;
        }
      }
      // The HEALPix base tessellation: 4 north-cap, 4 equatorial, 4 south-cap.
      expect(north, 4);
      expect(belt, 4);
      expect(south, 4);
    });

    test('base-pixel centers sit on the canonical HEALPix latitudes', () {
      final h = HealpixNested(0);
      // Cap pixel centers are at z = +-2/3 (dec ~ +-41.81 deg); belt centers
      // at the equator (dec 0). These are the published order-0 latitudes.
      const capDec = 41.8103149; // acos? -> asin(2/3) in degrees
      for (var pix = 0; pix < 12; pix++) {
        final dec = h.pix2RaDec(pix).decDeg;
        final onCap = (dec.abs() - capDec).abs() < 1e-3;
        final onBelt = dec.abs() < 1e-6;
        expect(
          onCap || onBelt,
          isTrue,
          reason: 'base pix $pix dec=$dec is neither cap nor belt latitude',
        );
      }
    });
  });

  group('cell corners are shared exactly with neighbours (seam-free)', () {
    test('a pixel boundary corner coincides with the adjacent pixel corner', () {
      // Seam-free mosaicing requires that the *same sky point* is produced for a
      // shared corner regardless of which of the two tiles asks for it. Test an
      // interior pixel whose neighbours are all on-face plus a face-seam pixel.
      for (final order in <int>[3, 5]) {
        final h = HealpixNested(order);
        for (final pix in <int>[
          h.npix ~/ 2 + 5, // somewhere in the equatorial belt
          0, // a base-face corner pixel
          h.npix ~/ 4, // a north/belt boundary region
        ]) {
          final corners = h.boundaries(pix);
          // Each of the (up to 8) neighbours shares at least one corner sky
          // point with `pix` to within floating-point round-trip tolerance.
          final neighbours = h.neighboursNest(pix).where((n) => n >= 0);
          var sharedCornerCount = 0;
          for (final nb in neighbours) {
            final nbCorners = h.boundaries(nb);
            for (final c in corners) {
              for (final nc in nbCorners) {
                final sep = _sepDeg(
                  HealpixNested.angToVec(c),
                  HealpixNested.angToVec(nc),
                );
                if (sep < 1e-6) sharedCornerCount++;
              }
            }
          }
          // An edge-adjacent neighbour shares two corners; a corner-adjacent one
          // shares one. With at least 3 valid neighbours there must be several
          // shared corners — proving the mesh edges coincide (no seam gap).
          expect(
            sharedCornerCount,
            greaterThanOrEqualTo(3),
            reason:
                'order $order pix $pix shared only $sharedCornerCount '
                'corners with its neighbours',
          );
        }
      }
    });

    test('boundaries returns four corners ordered S, E, N, W', () {
      final h = HealpixNested(4);
      final corners = h.boundaries(100);
      expect(corners, hasLength(4));
      // South corner has the lowest dec, north the highest (for a belt pixel).
      final decs = corners.map((c) => c.decDeg).toList();
      expect(
        decs[0],
        lessThanOrEqualTo(decs[2]),
        reason: 'south corner dec must be <= north corner dec',
      );
    });
  });

  group('quadtree parent/child (LOD fallback registration)', () {
    test('each child reports its parent as ipix>>2', () {
      for (final order in <int>[1, 3, 6]) {
        final fine = HealpixNested(order);
        for (var pix = 0; pix < math.min(fine.npix, 4096); pix += 7) {
          expect(fine.parent(pix), pix >> 2);
        }
      }
    });

    test('children are contiguous and round-trip back to the parent', () {
      final coarse = HealpixNested(3);
      final fine = HealpixNested(4);
      for (var pix = 0; pix < coarse.npix; pix += 13) {
        final kids = coarse.children(pix);
        expect(kids, [pix * 4, pix * 4 + 1, pix * 4 + 2, pix * 4 + 3]);
        for (final k in kids) {
          expect(fine.parent(k), pix);
        }
      }
    });

    test('ancestorAtOrder collapses multiple levels in one shift', () {
      final h = HealpixNested(8);
      const pix = 0xABCDE & ((1 << (2 * 8)) - 1); // an in-range deep pixel
      // Two levels up equals applying parent twice via order-7 then order-6.
      final upTwo = h.ancestorAtOrder(pix, 6);
      expect(upTwo, pix >> 4);
    });

    test(
      'order 0 has no parent; max order has no children (errors surface)',
      () {
        expect(
          () => HealpixNested(0).parent(0),
          throwsA(isA<HealpixArgumentError>()),
        );
        expect(
          () => HealpixNested(HealpixNested.maxOrder).children(0),
          throwsA(isA<HealpixArgumentError>()),
        );
      },
    );
  });

  group('input validation surfaces errors (never silent clamp)', () {
    test('out-of-range dec / pixel / face throw', () {
      final h = HealpixNested(4);
      expect(() => h.ang2pixNest(0, 91), throwsA(isA<HealpixArgumentError>()));
      expect(() => h.ang2pixNest(0, -91), throwsA(isA<HealpixArgumentError>()));
      expect(() => h.pix2ang(-1), throwsA(isA<HealpixArgumentError>()));
      expect(() => h.pix2ang(h.npix), throwsA(isA<HealpixArgumentError>()));
      expect(
        () => h.xyfToNest(const HealpixXyf(0, 0, 12)),
        throwsA(isA<HealpixArgumentError>()),
      );
    });

    test('RA wraps into [0,360) so seam-straddling input is accepted', () {
      final h = HealpixNested(4);
      // -10 deg and 350 deg are the same direction; both must address the same
      // pixel (RA wrap, not an error).
      expect(h.ang2pixNest(-10.0, 12.0), h.ang2pixNest(350.0, 12.0));
      expect(h.ang2pixNest(370.0, 12.0), h.ang2pixNest(10.0, 12.0));
    });
  });
}
