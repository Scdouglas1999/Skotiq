import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/your_sky/sky_atlas_format.dart';
import 'package:skotiq_core/errors.dart' show userFacingError;

void main() {
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
        '1h of first light',
      );
    });

    test('deeper-than phrasing with a custom period', () {
      expect(
        formatGrowthDelta(
          recentSeconds: 3600 * 4,
          priorSeconds: 3600 * 8,
          period: 'yesterday',
        ),
        '4h deeper than yesterday',
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
      expect(userFacingError(Exception('boom')), 'boom');
    });
  });
}
