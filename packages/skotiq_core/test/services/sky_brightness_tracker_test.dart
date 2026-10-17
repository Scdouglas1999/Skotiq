import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/sky_brightness_tracker.dart';

double _aduForMag(double mag) {
  return 10.0 * math.pow(10.0, (21.5 - mag) / 2.5).toDouble();
}

void main() {
  group('SkyBrightnessTracker', () {
    test(
      'retains session samples beyond the live rate window for summaries',
      () {
        final tracker = SkyBrightnessTracker();
        final now = DateTime.now();

        tracker.setCalibration(aduPerSec: 10.0, magPerArcsec2: 21.5);
        tracker.addSample(
          adu: _aduForMag(20.0),
          exposureTime: 1.0,
          timestamp: now.subtract(const Duration(minutes: 6)),
        );

        final retained = tracker.magSamplesSince(
          now.subtract(const Duration(minutes: 10)),
        );
        expect(retained, hasLength(1));
        expect(retained.single, closeTo(20.0, 0.01));
      },
    );
  });
}
