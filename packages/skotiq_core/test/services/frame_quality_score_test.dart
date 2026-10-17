import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Measured in the running desktop app 2026-08-09, after a clean ten-frame
/// sequencer run:
///
/// ```
/// sqlite> select hfr, star_count, quality_score from captured_images limit 1;
///         2.2388  35  NULL
///
/// Analytics -> Captured Images:  Good: 0   Needs Review: 10   Poor: 0
/// ```
///
/// Every sequencer frame stored a NULL score, so
/// `FrameQualityAssessmentService` assessed its `?? 75.0` fallback rather than
/// the frame. The "65" on every tile was a property of that constant, and any
/// consumer ranking frames by quality was ranking the same number ten times.
void main() {
  group('computeFrameQualityScore', () {
    test('the live-rig frame scores from its own measurements', () {
      // The first frame of that run. With HFR and star count present the score
      // is those two components renormalised — a real number, not the fallback.
      final score = computeFrameQualityScore(hfr: 2.2388, starCount: 35);

      expect(score.isNaN, isFalse);
      expect(score, greaterThan(0));
      expect(score, lessThan(100));
      expect(
        score,
        isNot(closeTo(75.0, 0.001)),
        reason:
            'a real score must not coincide with the null-fallback constant',
      );
    });

    test('a sharper frame with more stars outscores a soft one', () {
      // The property that actually matters: the score has to discriminate.
      // While the column was NULL every frame assessed identically, so stack
      // selection and auto-reject were ranking a constant.
      final good = computeFrameQualityScore(hfr: 1.8, starCount: 220);
      final soft = computeFrameQualityScore(hfr: 4.5, starCount: 22);

      expect(good, greaterThan(soft));
    });

    test('a missing background component is omitted, not scored zero', () {
      // The sequencer's frame event carries no mean/stdDev. Counting the
      // absent 30% as zero would punish every sequencer frame for a number
      // nobody measured — the same class of mistake as the NULL score.
      final withoutBackground = computeFrameQualityScore(
        hfr: 1.5,
        starCount: 500,
      );

      expect(
        withoutBackground,
        closeTo(100.0, 0.001),
        reason:
            'a perfect HFR and star count with no background measurement '
            'is a perfect score over the components that exist',
      );
    });

    test('a perfectly uniform background still counts when supplied', () {
      final withBackground = computeFrameQualityScore(
        hfr: 1.5,
        starCount: 500,
        mean: 1000.0,
        stdDev: 50.0, // cv 0.05 -> 100
      );

      expect(withBackground, closeTo(100.0, 0.001));
    });

    test('a frame with nothing measurable returns NaN rather than a number', () {
      // Stored as NULL, which is honest: the assessment service's fallback then
      // applies to a frame that genuinely could not be measured.
      expect(
        computeFrameQualityScore(hfr: null, starCount: null).isNaN,
        isTrue,
      );
      expect(computeFrameQualityScore(hfr: 0.0, starCount: null).isNaN, isTrue);
    });

    test('the score stays inside 0..100 for absurd inputs', () {
      for (final (hfr, stars) in const [
        (0.001, 100000),
        (99.0, 0),
        (12.0, 1),
      ]) {
        final s = computeFrameQualityScore(hfr: hfr, starCount: stars);
        expect(
          s,
          inInclusiveRange(0.0, 100.0),
          reason: 'hfr=$hfr stars=$stars',
        );
      }
    });
  });
}
