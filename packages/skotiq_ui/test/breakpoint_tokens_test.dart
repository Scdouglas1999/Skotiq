import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  group('BreakpointTokens constants', () {
    test('match documented values', () {
      expect(BreakpointTokens.breakpointPhone, 600.0);
      expect(BreakpointTokens.breakpointTablet, 768.0);
      expect(BreakpointTokens.breakpointDesktop, 1024.0);
      expect(BreakpointTokens.breakpointDesktopWide, 1280.0);
    });
  });

  group('BreakpointTokens classification', () {
    test('phone band: [0, 600)', () {
      expect(BreakpointTokens.isPhone(0), isTrue);
      expect(BreakpointTokens.isPhone(599.999), isTrue);
      expect(BreakpointTokens.isPhone(600), isFalse);
    });

    test('tablet band: [600, 768)', () {
      expect(BreakpointTokens.isTablet(599.999), isFalse);
      expect(BreakpointTokens.isTablet(600), isTrue);
      expect(BreakpointTokens.isTablet(700), isTrue);
      expect(BreakpointTokens.isTablet(767.999), isTrue);
      expect(BreakpointTokens.isTablet(768), isFalse);
    });

    test('desktop band: [768, 1024)', () {
      expect(BreakpointTokens.isDesktop(767.999), isFalse);
      expect(BreakpointTokens.isDesktop(768), isTrue);
      expect(BreakpointTokens.isDesktop(1023.999), isTrue);
      expect(BreakpointTokens.isDesktop(1024), isFalse);
    });

    test('desktopWide band: [1024, 1280)', () {
      expect(BreakpointTokens.isDesktopWide(1023.999), isFalse);
      expect(BreakpointTokens.isDesktopWide(1024), isTrue);
      expect(BreakpointTokens.isDesktopWide(1279.999), isTrue);
      expect(BreakpointTokens.isDesktopWide(1280), isFalse);
    });

    test('ultraWide: w >= 1280', () {
      expect(BreakpointTokens.isUltraWide(1279.999), isFalse);
      expect(BreakpointTokens.isUltraWide(1280), isTrue);
      expect(BreakpointTokens.isUltraWide(2560), isTrue);
    });

    test('isAtLeastDesktop: w >= 768', () {
      expect(BreakpointTokens.isAtLeastDesktop(767.999), isFalse);
      expect(BreakpointTokens.isAtLeastDesktop(768), isTrue);
      expect(BreakpointTokens.isAtLeastDesktop(2000), isTrue);
    });

    test(
      'exactly one band predicate is true for any width in (-inf, +inf)',
      () {
        for (final w in [
          0.0,
          300.0,
          599.0,
          600.0,
          700.0,
          767.0,
          768.0,
          900.0,
          1024.0,
          1100.0,
          1280.0,
          1920.0,
        ]) {
          final hits = [
            BreakpointTokens.isPhone(w),
            BreakpointTokens.isTablet(w),
            BreakpointTokens.isDesktop(w),
            BreakpointTokens.isDesktopWide(w),
            BreakpointTokens.isUltraWide(w),
          ].where((b) => b).length;
          expect(
            hits,
            1,
            reason: 'width $w should land in exactly one band, got $hits hits',
          );
        }
      },
    );
  });
}
