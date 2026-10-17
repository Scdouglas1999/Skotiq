import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Probes the device-class TIER family ([Responsive.isMobile] / [isTablet] /
/// [isDesktop] / [isDesktopLarge] / [isUltraWide]).
///
/// Branching the tier family on the raw window WIDTH reports desktop-class for
/// a landscape phone or a foldable cover screen (long edge >= 768, e.g. the
/// Galaxy Z Fold 6 cover at 905x369) and hands it the desktop split layout. On
/// a mobile OS the tier keys off the SHORTEST side so the classification is
/// orientation-stable, matching [Responsive.isPhone]. On desktop the live width
/// still drives the tier.
Future<
  ({
    bool isMobile,
    bool isTablet,
    bool isDesktop,
    bool isDesktopLarge,
    bool isUltraWide,
  })
>
_probe(
  WidgetTester tester,
  Size size, {
  TargetPlatform platform = TargetPlatform.android,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  debugDefaultTargetPlatformOverride = platform;
  addTearDown(tester.view.reset);

  late bool isMobile;
  late bool isTablet;
  late bool isDesktop;
  late bool isDesktopLarge;
  late bool isUltraWide;

  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          isMobile = Responsive.isMobile(context);
          isTablet = Responsive.isTablet(context);
          isDesktop = Responsive.isDesktop(context);
          isDesktopLarge = Responsive.isDesktopLarge(context);
          isUltraWide = Responsive.isUltraWide(context);
          return const SizedBox.shrink();
        },
      ),
    ),
  );

  // Clear the override before the framework's end-of-body foundation-vars
  // invariant runs (it fires before tearDowns).
  debugDefaultTargetPlatformOverride = null;

  return (
    isMobile: isMobile,
    isTablet: isTablet,
    isDesktop: isDesktop,
    isDesktopLarge: isDesktopLarge,
    isUltraWide: isUltraWide,
  );
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('mobile-OS tier classification (shortest-side, orientation-stable)', () {
    testWidgets('905x369 Fold cover screen classifies as mobile, not desktop', (
      tester,
    ) async {
      // 905 >= 768, so a width-based isMobile reads false and every isMobile
      // branch renders the desktop split. Short edge 369 < 600 => mobile tier.
      final r = await _probe(tester, const Size(905, 369));
      expect(
        r.isMobile,
        isTrue,
        reason: 'short edge 369 < 768 must keep it in the mobile tier',
      );
      expect(r.isTablet, isFalse);
      expect(r.isDesktop, isFalse);
      expect(r.isDesktopLarge, isFalse);
      expect(r.isUltraWide, isFalse);
    });

    testWidgets('844x390 rotated phone classifies as mobile', (tester) async {
      final r = await _probe(tester, const Size(844, 390));
      expect(r.isMobile, isTrue);
      expect(r.isDesktop, isFalse);
    });

    testWidgets('360x640 portrait phone classifies as mobile', (tester) async {
      final r = await _probe(tester, const Size(360, 640));
      expect(r.isMobile, isTrue);
      expect(r.isDesktop, isFalse);
    });

    testWidgets('768x1024 tablet portrait is the tablet tier, not mobile', (
      tester,
    ) async {
      // Short edge 768 is exactly the tablet breakpoint, so not mobile.
      final r = await _probe(tester, const Size(768, 1024));
      expect(r.isMobile, isFalse);
      expect(r.isTablet, isTrue);
      expect(r.isDesktop, isFalse);
    });

    testWidgets(
      '1024x768 tablet landscape stays tablet tier (short edge drives it)',
      (tester) async {
        // Long edge is 1024 (desktop breakpoint) but the short edge 768 keeps it
        // a tablet, orientation-stable with the portrait case above.
        final r = await _probe(tester, const Size(1024, 768));
        expect(r.isMobile, isFalse);
        expect(r.isTablet, isTrue);
        expect(r.isDesktop, isFalse);
      },
    );
  });

  group('desktop tier classification (live width drives reflow, preserved)', () {
    testWidgets('905x369 desktop window classifies as tablet tier by width', (
      tester,
    ) async {
      // Contrast the mobile case: on desktop the actual width (905) decides the
      // tier, so a short wide window is tablet-class, not mobile.
      final r = await _probe(
        tester,
        const Size(905, 369),
        platform: TargetPlatform.windows,
      );
      expect(r.isMobile, isFalse);
      expect(r.isTablet, isTrue);
      expect(r.isDesktop, isFalse);
    });

    testWidgets('600x900 narrow desktop window reflows to mobile tier', (
      tester,
    ) async {
      final r = await _probe(
        tester,
        const Size(600, 900),
        platform: TargetPlatform.macOS,
      );
      expect(r.isMobile, isTrue);
    });

    testWidgets('1440x900 desktop window is desktop + desktop-large', (
      tester,
    ) async {
      final r = await _probe(
        tester,
        const Size(1440, 900),
        platform: TargetPlatform.windows,
      );
      expect(r.isDesktop, isTrue);
      expect(r.isDesktopLarge, isTrue);
      expect(r.isUltraWide, isFalse);
    });

    testWidgets('1920x1080 desktop window is ultra-wide', (tester) async {
      final r = await _probe(
        tester,
        const Size(1920, 1080),
        platform: TargetPlatform.macOS,
      );
      expect(r.isDesktop, isTrue);
      expect(r.isUltraWide, isTrue);
    });
  });
}
