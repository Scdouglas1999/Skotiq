// The guider step must not overprint itself.
//
// A fixed 240 px box for the device picker is less than the picker's own chrome
// (heading, subtitle, Scan-again row, per-backend status row, footnote) needs:
// on a virgin install at 1400x900 with no guider hardware the list slot
// collapses and the "No devices found" empty state paints straight through the
// "No matching device? You can skip this step..." footnote below it — two
// sentences on one line, both unreadable.
//
// Pinned here: no overflow and no overprint at the window sizes the wizard has
// to survive.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/onboarding/steps/guider_step.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/pump_app_screen.dart';

class _EmptyDiscoveryNotifier extends UnifiedDiscoveryNotifier {
  _EmptyDiscoveryNotifier(super.ref);

  @override
  Future<void> discoverAll({
    bool includeIndi = true,
    bool includeAlpaca = true,
  }) async {}
}

const _emptyStateText = 'Make sure the device is connected and powered on, '
    'then scan again.';
const _footnoteText =
    'No matching device? You can skip this step and add it later from the '
    'Equipment screen.';

Future<void> _pumpGuiderStep(WidgetTester tester, Size size) async {
  await pumpAppScreen(
    tester,
    const OnboardingGuiderStep(),
    size: size,
    extraOverrides: [
      unifiedDiscoveryProvider.overrideWith(_EmptyDiscoveryNotifier.new),
    ],
    settle: false,
  );
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  for (final size in const [
    Size(1400, 900),
    Size(1000, 700),
    Size(800, 600),
  ]) {
    testWidgets(
        'guider step lays out cleanly at '
        '${size.width.toInt()}x${size.height.toInt()}', (tester) async {
      await _pumpGuiderStep(tester, size);

      // No RenderFlex overflow: the step scrolls rather than spilling.
      expect(
        tester.takeException(),
        isNull,
        reason: 'guider step overflowed at ${size.width}x${size.height}',
      );

      final empty = find.text(_emptyStateText);
      final footnote = find.text(_footnoteText);
      expect(empty, findsOneWidget, reason: 'empty state should be built');
      expect(footnote, findsOneWidget);

      // The two lines the user saw stacked on top of each other.
      expect(
        tester.getRect(empty).overlaps(tester.getRect(footnote)),
        isFalse,
        reason: 'empty state ${tester.getRect(empty)} overprints the footnote '
            '${tester.getRect(footnote)} at ${size.width}x${size.height}',
      );
    });
  }

  testWidgets('the picker box is tall enough for its own chrome',
      (tester) async {
    // The direct cause of the overprint was a box shorter than the content it
    // had to hold. Pin the ordering rather than the constant: the empty state
    // must sit above the footnote with real space between them.
    await _pumpGuiderStep(tester, const Size(1400, 900));

    final emptyRect = tester.getRect(find.text(_emptyStateText));
    final footnoteRect = tester.getRect(find.text(_footnoteText));
    expect(
      emptyRect.bottom,
      lessThan(footnoteRect.top),
      reason: 'the empty state must end before the footnote begins',
    );
  });
}
