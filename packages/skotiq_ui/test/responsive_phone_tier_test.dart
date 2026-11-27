import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<({bool isPhone, bool isMobile, bool isLandscape, bool isPhoneLandscape})>
_probe(
  WidgetTester tester,
  Size size, {
  TargetPlatform platform = TargetPlatform.android,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  late bool isPhone;
  late bool isMobile;
  late bool isLandscape;
  late bool isPhoneLandscape;

  final touch =
      platform == TargetPlatform.android || platform == TargetPlatform.iOS;
  await tester.pumpWidget(
    ShellLayoutScope(
      touchDevice: touch,
      drawsWindowFrame: !touch,
      child: MaterialApp(
        home: Builder(
          builder: (context) {
            isPhone = Responsive.isPhone(context);
            isMobile = Responsive.isMobile(context);
            isLandscape = Responsive.isLandscape(context);
            isPhoneLandscape = Responsive.isPhoneLandscape(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );

  return (
    isPhone: isPhone,
    isMobile: isMobile,
    isLandscape: isLandscape,
    isPhoneLandscape: isPhoneLandscape,
  );
}

void main() {
  group('mobile device-class detection (orientation-independent)', () {
    testWidgets('360x640 is a phone in portrait', (tester) async {
      final r = await _probe(tester, const Size(360, 640));
      expect(r.isPhone, isTrue);
      expect(r.isMobile, isTrue);
      expect(r.isPhoneLandscape, isFalse);
    });

    testWidgets('390x844 is a phone in portrait', (tester) async {
      final r = await _probe(tester, const Size(390, 844));
      expect(r.isPhone, isTrue);
    });

    testWidgets('540x900 is a phone', (tester) async {
      final r = await _probe(tester, const Size(540, 900));
      expect(r.isPhone, isTrue);
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

  group('desktop window-size detection', () {
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

    testWidgets('844x700 desktop window is NOT a phone', (tester) async {
      final r = await _probe(
        tester,
        const Size(844, 700),
        platform: TargetPlatform.windows,
      );
      expect(r.isPhone, isFalse);
    });

    testWidgets('a desktop window shorter than 600 is a phone on its side', (
      tester,
    ) async {
      final r = await _probe(
        tester,
        const Size(844, 390),
        platform: TargetPlatform.windows,
      );
      expect(r.isPhone, isTrue);
      expect(r.isPhoneLandscape, isTrue);
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

  test('the phone threshold matches BreakpointTokens', () {
    expect(Responsive.phoneMaxWidth, BreakpointTokens.breakpointPhone);
  });
}
