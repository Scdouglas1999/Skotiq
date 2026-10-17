import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<
  ({
    bool isPhone,
    bool isCompactPhone,
    bool isMobile,
    bool isLandscape,
    bool isPhoneLandscape,
    bool isPhonePortrait,
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

  late bool isPhone;
  late bool isCompactPhone;
  late bool isMobile;
  late bool isLandscape;
  late bool isPhoneLandscape;
  late bool isPhonePortrait;

  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          isPhone = Responsive.isPhone(context);
          isCompactPhone = Responsive.isCompactPhone(context);
          isMobile = Responsive.isMobile(context);
          isLandscape = Responsive.isLandscape(context);
          isPhoneLandscape = Responsive.isPhoneLandscape(context);
          isPhonePortrait = Responsive.isPhonePortrait(context);
          return const SizedBox.shrink();
        },
      ),
    ),
  );

  // The build has run and captured the values above; clear the platform
  // override now so the framework's end-of-body foundation-vars invariant
  // (which runs before tearDowns) sees it unset.
  debugDefaultTargetPlatformOverride = null;

  return (
    isPhone: isPhone,
    isCompactPhone: isCompactPhone,
    isMobile: isMobile,
    isLandscape: isLandscape,
    isPhoneLandscape: isPhoneLandscape,
    isPhonePortrait: isPhonePortrait,
  );
}

void main() {
  // Each test sets debugDefaultTargetPlatformOverride via _probe; reset it
  // after every test so the framework's foundation-vars invariant holds.
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('mobile device-class detection (orientation-independent)', () {
    testWidgets('360x640 is a compact phone in portrait', (tester) async {
      final r = await _probe(tester, const Size(360, 640));
      expect(r.isPhone, isTrue);
      expect(r.isCompactPhone, isTrue);
      expect(r.isMobile, isTrue);
      expect(r.isPhonePortrait, isTrue);
      expect(r.isPhoneLandscape, isFalse);
    });

    testWidgets('390x844 is a (compact) phone in portrait', (tester) async {
      final r = await _probe(tester, const Size(390, 844));
      expect(r.isPhone, isTrue);
      expect(r.isCompactPhone, isTrue); // 390 < 480
      expect(r.isPhonePortrait, isTrue);
    });

    testWidgets('540x900 is a phone but not compact', (tester) async {
      final r = await _probe(tester, const Size(540, 900));
      expect(r.isPhone, isTrue);
      expect(r.isCompactPhone, isFalse); // 540 >= 480
    });

    // A rotated phone's WIDTH is its long edge (>= 600), so a width-based
    // isPhone reads false and the screen falls through to the tablet/desktop
    // layout. Device-class detection keeps it a phone.
    testWidgets('844x390 rotated phone IS a phone in landscape', (
      tester,
    ) async {
      final r = await _probe(tester, const Size(844, 390));
      expect(r.isPhone, isTrue);
      expect(r.isLandscape, isTrue);
      expect(r.isPhoneLandscape, isTrue);
      expect(r.isPhonePortrait, isFalse);
      // Landscape gives plenty of width, so dense rows need not tighten.
      expect(r.isCompactPhone, isFalse);
    });

    testWidgets('905x412 large-phone landscape IS a phone', (tester) async {
      final r = await _probe(tester, const Size(905, 412));
      expect(r.isPhone, isTrue);
      expect(r.isPhoneLandscape, isTrue);
    });

    testWidgets('932x430 (iPhone Pro Max) landscape IS a phone', (
      tester,
    ) async {
      final r = await _probe(tester, const Size(932, 430));
      expect(r.isPhone, isTrue);
      expect(r.isPhoneLandscape, isTrue);
    });

    testWidgets('768x1024 tablet is NOT a phone (either orientation)', (
      tester,
    ) async {
      final portrait = await _probe(tester, const Size(768, 1024));
      expect(portrait.isPhone, isFalse);
      final landscape = await _probe(tester, const Size(1024, 768));
      expect(landscape.isPhone, isFalse);
    });
  });

  group('desktop window-size detection (width-driven reflow preserved)', () {
    testWidgets('590-wide desktop window is a phone (narrow reflow)', (
      tester,
    ) async {
      final r = await _probe(
        tester,
        const Size(590, 900),
        platform: TargetPlatform.windows,
      );
      expect(r.isPhone, isTrue);
    });

    testWidgets('844-wide desktop window is NOT a phone', (tester) async {
      final r = await _probe(
        tester,
        const Size(844, 390),
        platform: TargetPlatform.windows,
      );
      // On desktop, width drives the tier — a wide window is not a phone even
      // when short. (Contrast the mobile 844x390 case above.)
      expect(r.isPhone, isFalse);
    });

    testWidgets('maximized desktop is not a phone', (tester) async {
      final r = await _probe(
        tester,
        const Size(1920, 1080),
        platform: TargetPlatform.macOS,
      );
      expect(r.isPhone, isFalse);
    });
  });

  test('phone/compact thresholds match BreakpointTokens', () {
    expect(Responsive.phoneMaxWidth, BreakpointTokens.breakpointPhone);
    expect(Responsive.compactPhoneMaxWidth, 480.0);
  });
}
