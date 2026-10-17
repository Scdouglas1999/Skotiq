import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/your_sky/sky_atlas_format.dart';

void main() {
  group('formatIntegration', () {
    test('clamps non-positive and non-finite to 0s', () {
      expect(formatIntegration(0), '0s');
      expect(formatIntegration(-5), '0s');
      expect(formatIntegration(double.nan), '0s');
      expect(formatIntegration(double.infinity), '0s');
    });

    test('scales seconds -> minutes -> hours', () {
      expect(formatIntegration(45), '45s');
      expect(formatIntegration(600), '10m');
      expect(formatIntegration(3600 * 3.2), '3.2h');
      expect(formatIntegration(3600 * 41), '41h');
    });
  });

  group('formatRaDeg', () {
    test('converts degrees to sexagesimal hours', () {
      expect(formatRaDeg(0), '0h 00m');
      expect(formatRaDeg(15), '1h 00m');
      expect(formatRaDeg(180), '12h 00m');
    });

    test('wraps negative / over-360 RA', () {
      expect(formatRaDeg(-15), '23h 00m');
      expect(formatRaDeg(375), '1h 00m');
    });
  });

  group('formatDecDeg', () {
    test('signs and sexagesimal', () {
      expect(formatDecDeg(0), '+0° 00\'');
      expect(formatDecDeg(45.5), '+45° 30\'');
      expect(formatDecDeg(-30.25), '-30° 15\'');
    });
  });

  group('formatGrowthDelta', () {
    test('null when nothing gained', () {
      expect(
        formatGrowthDelta(recentSeconds: 0, priorSeconds: 100),
        isNull,
      );
    });

    test('first-light phrasing when no prior depth', () {
      expect(
        formatGrowthDelta(recentSeconds: 3600, priorSeconds: 0),
        '1.0h of first light',
      );
    });

    test('deeper-than phrasing with a custom period', () {
      expect(
        formatGrowthDelta(
          recentSeconds: 3600 * 4,
          priorSeconds: 3600 * 8,
          period: 'yesterday',
        ),
        '4.0h deeper than yesterday',
      );
    });
  });

  group('normalizedDepth', () {
    test('zero when no max or no depth', () {
      expect(normalizedDepth(10, 0), 0.0);
      expect(normalizedDepth(0, 100), 0.0);
    });

    test('perceptual sqrt ramp, clamped to 1', () {
      expect(normalizedDepth(100, 100), 1.0);
      expect(normalizedDepth(25, 100), closeTo(0.5, 1e-9));
      expect(normalizedDepth(200, 100), 1.0);
    });
  });

  group('formatCoverageDepth', () {
    test('formats sparse and deep coverage', () {
      expect(formatCoverageDepth(0), '0×');
      expect(formatCoverageDepth(2.4), '2.4×');
      expect(formatCoverageDepth(12.7), '13×');
    });
  });

  group('describeAtlasError', () {
    test('strips the Exception prefix', () {
      expect(describeAtlasError(Exception('boom')), 'boom');
    });
  });
}
