import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Accessibility guideline coverage for the shared components.
///
/// There was none anywhere in the repo, which matters more than usual here:
/// tablet/phone control is a headline feature, so these widgets are driven by
/// touch on small screens, and Flutter ships the checks for free.
///
/// [androidTapTargetGuideline] wants >=48x48 logical pixels, [iOSTapTargetGuideline]
/// >=44x44, [labeledTapTargetGuideline] wants every tappable node to carry a
/// label a screen reader can announce, and [textContrastGuideline] is WCAG AA.
void main() {
  Widget host(Widget child) => MaterialApp(
    theme: SkotiqTheme.dark,
    home: Scaffold(
      backgroundColor: const Color(0xFF0B0E14),
      body: Center(child: child),
    ),
  );

  group('SkotiqButton', () {
    for (final size in ButtonSize.values) {
      testWidgets('$size meets the Android 48px tap target', (tester) async {
        await tester.pumpWidget(
          host(SkotiqButton(label: 'Start', size: size, onPressed: () {})),
        );
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      });

      testWidgets('$size meets the iOS 44px tap target', (tester) async {
        await tester.pumpWidget(
          host(SkotiqButton(label: 'Start', size: size, onPressed: () {})),
        );
        await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      });
    }

    for (final variant in ButtonVariant.values) {
      testWidgets('$variant is announceable by a screen reader', (
        tester,
      ) async {
        await tester.pumpWidget(
          host(
            SkotiqButton(
              label: 'Start sequence',
              variant: variant,
              onPressed: () {},
            ),
          ),
        );
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      });

      testWidgets('$variant label meets WCAG AA contrast', (tester) async {
        await tester.pumpWidget(
          host(
            SkotiqButton(
              label: 'Start sequence',
              variant: variant,
              onPressed: () {},
            ),
          ),
        );
        await expectLater(tester, meetsGuideline(textContrastGuideline));
      });
    }

    /// Desktop density must NOT change: growing every button to 48px would
    /// re-flow the dense panels for no gain, because a mouse does not have the
    /// imprecision the touch guideline exists to absorb.
    testWidgets('desktop keeps the compact visual sizes', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: SkotiqTheme.dark.copyWith(platform: TargetPlatform.linux),
          home: Scaffold(
            body: Center(
              child: SkotiqButton(
                label: 'Go',
                size: ButtonSize.small,
                onPressed: () {},
              ),
            ),
          ),
        ),
      );
      final rect = tester.getRect(find.byType(SkotiqButton));
      expect(
        rect.height,
        lessThan(kMinInteractiveDimension),
        reason: 'desktop small buttons should stay compact',
      );
    });

    /// An icon-only button has no visible text, so its semantics are the ONLY
    /// thing a screen-reader user has. This is the case most likely to ship
    /// unlabelled.
    testWidgets('an icon-only button is still labelled', (tester) async {
      await tester.pumpWidget(
        host(
          SkotiqButton(label: 'Abort', icon: Icons.stop, onPressed: () {}),
        ),
      );
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    });
  });
}
