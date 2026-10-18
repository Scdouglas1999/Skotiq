// Responsive widget tests for WeatherScreen.
//
// Verifies the weather radar surface lays out without RenderFlex overflow at
// the three reference phone sizes in BOTH orientations (per the mobile
// responsive standard, docs/plans/2026-06-01-mobile-responsive-standard.md),
// and that the screen identity (the "Weather Radar" header) is present.
//
// The screen runs a 5-minute refresh timer and a fade animation, so we pump
// with settle: false and a couple of fixed-step frames rather than
// pumpAndSettle (which would hang on the periodic timer).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_app/screens/weather/weather_screen.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

/// The three reference phone sizes, portrait, from the standard.
const _phonePortraitSizes = <Size>[
  Size(360, 640), // small phone
  Size(390, 844), // modern phone
  Size(430, 932), // large phone
];

/// Pump [WeatherScreen] at [size], drain a few frames, and assert no overflow.
Future<void> _pumpAndCheck(WidgetTester tester, Size size) async {
  final handle = await pumpAppScreen(
    tester,
    const WeatherScreen(),
    size: size,
    settle: false,
    // The screen owns the teardown here: the weather-safety evaluator it shows
    // runs a 5-minute periodic timer that is cancelled when its provider is
    // disposed, and the harness's own tearDown runs AFTER the binding's
    // pending-timer check.
    registerTearDown: false,
  );
  // Drain the fade-in + initial post-frame fetch without waiting on the
  // 5-minute periodic refresh timer.
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }

  expect(
    tester.takeException(),
    isNull,
    reason: 'WeatherScreen must not overflow at ${size.width}x${size.height}',
  );
  expect(find.text('Weather'), findsOneWidget,
      reason: 'Weather header identity must be present at '
          '${size.width}x${size.height}');

  await tester.pumpWidget(const SizedBox.shrink());
  handle.container.dispose();
  // Drift schedules a zero-duration close timer when its query streams go; one
  // more frame lets it run before the binding checks for pending timers.
  await tester.pump(Duration.zero);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final size in _phonePortraitSizes) {
    testWidgets(
      'WeatherScreen lays out without overflow at '
      '${size.width.toInt()}x${size.height.toInt()} (portrait)',
      (tester) async {
        await _pumpAndCheck(tester, size);
      },
    );

    final landscape = Size(size.height, size.width);
    testWidgets(
      'WeatherScreen lays out without overflow at '
      '${landscape.width.toInt()}x${landscape.height.toInt()} (landscape)',
      (tester) async {
        await _pumpAndCheck(tester, landscape);
      },
    );
  }

  // Live at 1920x1080 the safety chip, refresh and settings sat at x ~= 900:
  // a Flexible chip split the header's free space with the title's Expanded.
  testWidgets('the header actions sit at the right edge on a desktop window',
      (tester) async {
    const size = Size(1920, 1080);
    final handle = await pumpAppScreen(
      tester,
      const WeatherScreen(),
      size: size,
      settle: false,
      registerTearDown: false,
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final settings = tester.getRect(find.byTooltip('Weather settings'));
    final refresh = tester.getRect(find.byTooltip('Refresh radar data'));
    final chip = tester.getRect(find.byType(SkotiqChip).first);
    expect(settings.right, greaterThan(size.width - 2 * SkotiqTokens.space3xl));
    expect(refresh.right, lessThan(settings.left));
    expect(chip.right, lessThan(refresh.left));
    expect(refresh.left - chip.right, lessThan(SkotiqTokens.spaceLg),
        reason: 'the chip is one of the actions, not a mid-header island');

    await tester.pumpWidget(const SizedBox.shrink());
    handle.container.dispose();
    await tester.pump(Duration.zero);
  });
}
