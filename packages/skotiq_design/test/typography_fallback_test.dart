import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_design/skotiq_design.dart';

void main() {
  test(
    'text and readout styles fall back to the bundled face for the primes',
    () {
      // Guide RMS, FWHM and declinations end in ′ or ″, which neither text
      // face has; without a bundled fallback each platform substitutes its own.
      for (final style in [
        SkotiqTypography.body,
        SkotiqTypography.bodySm,
        SkotiqTypography.caption,
        SkotiqTypography.readoutLg,
        SkotiqTypography.readoutMd,
        SkotiqTypography.readoutSm,
        SkotiqTypography.monoCaption,
      ]) {
        expect(style.fontFamilyFallback, SkotiqTypography.fontFamilyFallback);
      }
      expect(SkotiqTypography.fontFamilyFallback, ['Sora']);
    },
  );
}
