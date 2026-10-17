/// Tests for [RollingRmsCalculator].
///
/// Verifies:
/// - RMS uses the sqrt(mean(x^2)) formula, not mean(|x|)
/// - the rolling window evicts oldest samples beyond [windowSize]
/// - mean / peak / latest / count helpers behave on empty and full windows

library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/src/rolling_rms_calculator.dart';

void main() {
  group('RollingRmsCalculator rms', () {
    test('empty window returns 0', () {
      final c = RollingRmsCalculator();
      expect(c.rms, 0);
      expect(c.isEmpty, true);
      expect(c.count, 0);
    });

    test('single value rms equals its absolute magnitude', () {
      final c = RollingRmsCalculator();
      c.add(-3.0);
      expect(c.rms, closeTo(3.0, 1e-12));
    });

    test('uses sqrt(mean(x^2)) not mean of absolute values', () {
      // For [3, 4]: RMS = sqrt((9 + 16) / 2) = sqrt(12.5) ~= 3.5355
      // mean(|x|) would be 3.5, so this distinguishes the two formulas.
      final c = RollingRmsCalculator();
      c.add(3.0);
      c.add(4.0);
      expect(c.rms, closeTo(sqrt(12.5), 1e-12));
      expect(c.rms, isNot(closeTo(3.5, 1e-6)));
    });

    test('sign of samples does not change rms', () {
      final positive = RollingRmsCalculator()
        ..add(1.0)
        ..add(2.0)
        ..add(3.0);
      final mixed = RollingRmsCalculator()
        ..add(-1.0)
        ..add(2.0)
        ..add(-3.0);
      expect(mixed.rms, closeTo(positive.rms, 1e-12));
    });
  });

  group('RollingRmsCalculator window eviction', () {
    test('drops oldest values beyond windowSize', () {
      final c = RollingRmsCalculator(windowSize: 3);
      c.add(100.0); // should be evicted
      c.add(1.0);
      c.add(2.0);
      c.add(3.0); // pushes out the 100.0
      expect(c.count, 3);
      expect(c.isFull, true);
      // RMS over [1, 2, 3] only
      expect(c.rms, closeTo(sqrt((1 + 4 + 9) / 3), 1e-12));
    });

    test('count never exceeds windowSize', () {
      final c = RollingRmsCalculator(windowSize: 5);
      for (var i = 0; i < 50; i++) {
        c.add(i.toDouble());
      }
      expect(c.count, 5);
      expect(c.latest, 49.0);
    });
  });

  group('RollingRmsCalculator helpers', () {
    test('mean computes arithmetic average over window', () {
      final c = RollingRmsCalculator()
        ..add(2.0)
        ..add(4.0)
        ..add(6.0);
      expect(c.mean, closeTo(4.0, 1e-12));
    });

    test('peak returns max absolute value', () {
      final c = RollingRmsCalculator()
        ..add(-7.0)
        ..add(3.0)
        ..add(5.0);
      expect(c.peak, 7.0);
    });

    test('mean / peak / latest are 0 on empty window', () {
      final c = RollingRmsCalculator();
      expect(c.mean, 0);
      expect(c.peak, 0);
      expect(c.latest, 0);
    });

    test('clear empties the window', () {
      final c = RollingRmsCalculator()
        ..add(1.0)
        ..add(2.0);
      c.clear();
      expect(c.isEmpty, true);
      expect(c.rms, 0);
      expect(c.count, 0);
    });
  });
}
