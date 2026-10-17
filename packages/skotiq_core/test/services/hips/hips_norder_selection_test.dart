// C9 unit tests — HiPS Norder level-of-detail selection sweep + clamp.
//
// `selectNorder` is the single decision that keeps the framing tile layer crisp
// without over-fetching: pick the HiPS resolution level whose native texel scale
// is the first one at least as fine as the current screen arcsec/px, clamped to
// the survey's published [hips_order_min, hips_order] range. Mis-levelling here
// is a smoothness bug (soft imagery, or a 4x tile-count blow-up), so this suite
// pins the rule precisely:
//
//   * a monotone sweep across the full zoom range never decreases the selected
//     order as the view zooms in (finer screen scale -> equal-or-higher order),
//   * the result is clamped into the survey range at both ends and never escapes
//     it for any finite positive scale,
//   * the tilepix reference scales linearly with the survey's tile width (a
//     1024-px survey reaches a given order one step earlier than a 512-px one),
//   * the literal spec formula `clamp(ceil(log2(ref/arcsecpp)), min, max)` is
//     reproduced bit-for-bit, and
//   * a degenerate (non-positive / non-finite) scale surfaces as an error rather
//     than silently guessing an order.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/hips/hips_properties.dart';
import 'package:skotiq_core/src/services/hips/hips_tile_selection.dart';

HipsProperties _props({int order = 9, int orderMin = 3, int tileWidth = 512}) =>
    HipsProperties.parse('''
hips_order        = $order
hips_order_min    = $orderMin
hips_tile_width   = $tileWidth
hips_tile_format  = jpeg
hips_frame        = equatorial
''');

/// The reference formula the implementation must reproduce, parameterised by the
/// survey tile width exactly as the production code rescales the 512-px constant.
int _expected(double pxPerDeg, HipsProperties props) {
  final arcsecPerPx = 3600.0 / pxPerDeg;
  final ref =
      HipsTileSelection.tilepixReferenceArcsec *
      (props.tileWidth / HipsTileSelection.referenceTileWidth);
  final raw = (math.log(ref / arcsecPerPx) / math.ln2).ceil();
  return raw.clamp(props.hipsOrderMin, props.hipsOrder);
}

void main() {
  group('literal tilepix formula', () {
    test(
      'matches clamp(ceil(log2(ref/arcsecpp)), min, max) for 512-px tiles',
      () {
        final props = _props();
        for (final pxPerDeg in <double>[
          10,
          37,
          120,
          360,
          1000,
          3600,
          12000,
          48000,
          200000,
        ]) {
          expect(
            HipsTileSelection.selectNorder(pxPerDeg, props),
            _expected(pxPerDeg, props),
            reason: 'pxPerDeg=$pxPerDeg',
          );
        }
      },
    );
  });

  group('monotone zoom sweep', () {
    test('order is non-decreasing as the screen scale gets finer', () {
      // Sweep px/deg from very coarse to very fine (zoom in). The selected order
      // must never go *down* as we zoom in — that would be a soft-imagery bug.
      final props = _props(order: 12, orderMin: 0);
      var previous = -1;
      for (var pxPerDeg = 5.0; pxPerDeg <= 500000.0; pxPerDeg *= 1.3) {
        final n = HipsTileSelection.selectNorder(pxPerDeg, props);
        expect(
          n,
          greaterThanOrEqualTo(previous),
          reason: 'order decreased while zooming in at pxPerDeg=$pxPerDeg',
        );
        previous = n;
      }
    });

    test(
      'a 2x zoom step raises the order by exactly one in the linear regime',
      () {
        // Within the unclamped middle of the range, doubling px/deg halves
        // arcsec/px, which advances ceil(log2(...)) by exactly 1.
        final props = _props(order: 20, orderMin: 0, tileWidth: 512);
        // Choose a base that sits comfortably inside the range.
        const base = 4000.0;
        final n1 = HipsTileSelection.selectNorder(base, props);
        final n2 = HipsTileSelection.selectNorder(base * 2.0, props);
        expect(n2 - n1, 1);
      },
    );
  });

  group('clamping to the survey range', () {
    test('an extreme zoom-out clamps to hips_order_min', () {
      final props = _props(order: 9, orderMin: 3);
      // A whole-sky FOV (tiny px/deg) would compute a negative raw order; it
      // must clamp up to the survey minimum, not go below it.
      final n = HipsTileSelection.selectNorder(0.1, props);
      expect(n, props.hipsOrderMin);
    });

    test('an extreme zoom-in clamps to hips_order', () {
      final props = _props(order: 9, orderMin: 3);
      // A pathologically fine scale would compute an order beyond the survey's
      // deepest published level; it must clamp down to hips_order.
      final n = HipsTileSelection.selectNorder(5.0e7, props);
      expect(n, props.hipsOrder);
    });

    test('the result is always within the published range for any scale', () {
      final props = _props(order: 7, orderMin: 2);
      for (var pxPerDeg = 1.0; pxPerDeg <= 1.0e8; pxPerDeg *= 1.7) {
        final n = HipsTileSelection.selectNorder(pxPerDeg, props);
        expect(n, inInclusiveRange(props.hipsOrderMin, props.hipsOrder));
      }
    });

    test('a single-order survey always returns that order', () {
      final props = _props(order: 5, orderMin: 5);
      for (final pxPerDeg in <double>[1, 100, 10000, 1000000]) {
        expect(HipsTileSelection.selectNorder(pxPerDeg, props), 5);
      }
    });
  });

  group('tile-width scaling of the reference', () {
    test(
      'a 1024-px survey reaches a given order one step earlier than 512-px',
      () {
        // The reference arcsec scales linearly with tile width, so at the SAME
        // screen scale a wider-tile survey selects an order one higher (it
        // resolves more finely per order).
        final p512 = _props(order: 20, orderMin: 0, tileWidth: 512);
        final p1024 = _props(order: 20, orderMin: 0, tileWidth: 1024);
        const pxPerDeg = 6000.0;
        final n512 = HipsTileSelection.selectNorder(pxPerDeg, p512);
        final n1024 = HipsTileSelection.selectNorder(pxPerDeg, p1024);
        expect(n1024 - n512, 1);
      },
    );

    test('matches the rescaled formula for non-512 tile widths', () {
      for (final width in <int>[256, 512, 1024]) {
        final props = _props(order: 18, orderMin: 0, tileWidth: width);
        for (final pxPerDeg in <double>[200, 2000, 20000]) {
          expect(
            HipsTileSelection.selectNorder(pxPerDeg, props),
            _expected(pxPerDeg, props),
            reason: 'tileWidth=$width pxPerDeg=$pxPerDeg',
          );
        }
      }
    });
  });

  group('degenerate scale surfaces an error', () {
    test('zero, negative, NaN, and infinite px/deg throw', () {
      final props = _props();
      for (final bad in <double>[
        0.0,
        -1.0,
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(
          () => HipsTileSelection.selectNorder(bad, props),
          throwsA(isA<HipsTileSelectionError>()),
          reason: 'pxPerDeg=$bad must surface, not guess an order',
        );
      }
    });
  });
}
