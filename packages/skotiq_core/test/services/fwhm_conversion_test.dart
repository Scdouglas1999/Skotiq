import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/utils/fwhm_conversion.dart';

/// The derived-FWHM factor, pinned against the physics and against the native
/// measurement path.
///
/// This was 2.3548 in four Dart call sites — the sigma -> FWHM factor, applied
/// to a RADIUS. Since HFR = sigma * sqrt(2 ln 2), that overstated every derived
/// FWHM by 17.7%, and it disagreed with the app's own measured FWHM: the native
/// star detector already uses 2.0 (`FWHM_TO_HFR_RATIO` in `imaging/src/stats.rs`
/// carries the same derivation in its comment). So one session's exported CSV
/// and its FITS headers reported different FWHM for the same frames.
void main() {
  group('kFwhmPerHfr', () {
    test('is the Gaussian FWHM/HFR ratio, derived from sigma', () {
      // HFR = sigma * sqrt(2 ln 2); FWHM = 2 * sigma * sqrt(2 ln 2).
      const sigma = 1.7;
      const hfr = sigma * 1.1774100225154747; // sqrt(2 ln 2)
      const fwhm = 2 * sigma * 1.1774100225154747;

      expect(fwhm / hfr, closeTo(kFwhmPerHfr, 1e-12));
      expect(kFwhmPerHfr, closeTo(2.0, 1e-12));
    });

    test('is not the sigma->FWHM factor, which is what the bug applied', () {
      // 2.3548 is FWHM/sigma. Applying it to an HFR inflates by ~17.7%, which
      // is the exact error this constant exists to prevent.
      const wrong = 2.3548;
      expect(kFwhmPerHfr, isNot(closeTo(wrong, 0.01)));
      expect(wrong / kFwhmPerHfr, closeTo(1.177, 0.001));
    });

    test('a 2.0 px HFR star is a 4.0 px FWHM star', () {
      expect(2.0 * kFwhmPerHfr, closeTo(4.0, 1e-12));
      // The Gaussian sigma factor 2.3548 would report 4.71 px for the same
      // star; HFR is a radius, so the conversion is a doubling.
      expect(2.0 * 2.3548, closeTo(4.7096, 1e-4));
    });
  });
}
