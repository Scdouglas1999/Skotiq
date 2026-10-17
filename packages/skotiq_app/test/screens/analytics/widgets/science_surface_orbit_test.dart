import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_surface_explorer.dart';

void main() {
  group('surfaceOrbitDelta', () {
    test('a full-width drag is one revolution of yaw at any plot size', () {
      for (final plot in const [
        Size(320, 180),
        Size(640, 360),
        Size(2560, 1440),
      ]) {
        final orbit = surfaceOrbitDelta(Offset(plot.width, 0), plot);
        expect(orbit.yaw, closeTo(2 * math.pi, 1e-9),
            reason: 'full-width drag on $plot');
        expect(orbit.pitch, 0.0);
      }
    });

    test('a full-height drag is a half-turn of pitch at any plot size', () {
      for (final plot in const [
        Size(320, 180),
        Size(640, 360),
        Size(2560, 1440),
      ]) {
        final orbit = surfaceOrbitDelta(Offset(0, plot.height), plot);
        expect(orbit.pitch, closeTo(math.pi, 1e-9),
            reason: 'full-height drag on $plot');
        expect(orbit.yaw, 0.0);
      }
    });

    // Dragging the same FRACTION of the plot has to rotate the surface by the
    // same angle whatever the window is. A fixed radians-per-pixel rate makes a
    // wide desktop plot several times as twitchy.
    test('the same fractional drag rotates equally on a small and wide plot',
        () {
      const small = Size(600, 340);
      const wide = Size(2400, 1360);
      final onSmall = surfaceOrbitDelta(const Offset(150, 85), small);
      final onWide = surfaceOrbitDelta(const Offset(600, 340), wide);
      expect(onWide.yaw, closeTo(onSmall.yaw, 1e-9));
      expect(onWide.pitch, closeTo(onSmall.pitch, 1e-9));
    });

    test('a degenerate plot never yields a non-finite rotation', () {
      for (final plot in const [
        Size.zero,
        Size(0, 200),
        Size(200, 0),
        Size(double.nan, double.nan),
      ]) {
        final orbit = surfaceOrbitDelta(const Offset(10, 10), plot);
        expect(orbit.yaw.isFinite, isTrue, reason: '$plot');
        expect(orbit.pitch.isFinite, isTrue, reason: '$plot');
      }
    });
  });
}
