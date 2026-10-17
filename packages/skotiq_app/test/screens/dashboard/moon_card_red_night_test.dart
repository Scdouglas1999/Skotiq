// Red night mode must not put a bluish-white flare on the screen the app opens
// on.
//
// Measured live with Theme = Red night: the Dashboard Moon card painted a
// ~50 px filled disc at RGB(214,220,226) — luminance 219 — on a background of
// RGB(10,0,0), the brightest pixel anywhere in the 1920x1200 frame, while every
// other element was correctly red-shifted. The lit limb was a fixed
// `Color(0xFFD6DCE2)` handed to the painter regardless of theme. Red night is a
// WAVELENGTH constraint, so an off-white fill is not merely off-palette: it is
// the dark adaptation the mode exists to protect, spent in one glance.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/standby/moon_card.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

/// The painter the card built, plus the container that owns the planetarium
/// minute timer. That timer belongs to the PROVIDER, so the tree has to be torn
/// down and the container disposed INSIDE the test body — the binding checks
/// `!timersPending` before any tearDown runs.
typedef _PumpedMoon = ({MoonPainter painter, ProviderContainer container});

Future<_PumpedMoon> _pumpMoon(
  WidgetTester tester, {
  required ThemeData theme,
  required SkotiqColors colors,
}) async {
  final handle = await pumpAppScreen(
    tester,
    MoonCard(colors: colors),
    theme: theme,
    size: const Size(600, 600),
    settle: false,
  );
  await tester.pump(const Duration(milliseconds: 50));

  final painters = tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .map((c) => c.painter)
      .whereType<MoonPainter>()
      .toList();
  expect(painters, hasLength(1));

  return (painter: painters.single, container: handle.container);
}

Future<void> _teardown(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  container.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('red night does not paint the moon in off-white', (tester) async {
    final pumped = await _pumpMoon(
      tester,
      theme: SkotiqTheme.redNight,
      colors: SkotiqColors.redNight,
    );
    final painter = pumped.painter;

    expect(
      painter.litColor,
      isNot(moonLitGrey),
      reason: 'the disc must follow the theme like everything else',
    );
    // Red night tolerates red light, not blue-white light.
    expect(
      painter.litColor.g,
      lessThan(painter.litColor.r),
      reason: 'red must dominate the largest fill on the screen',
    );
    expect(painter.litColor.b, lessThan(painter.litColor.r));
    expect(
      painter.litColor.computeLuminance(),
      lessThan(moonLitGrey.computeLuminance()),
      reason: 'measured luminance 219 out of 255 was the brightest pixel in '
          'the whole frame',
    );

    await _teardown(tester, pumped.container);
  });

  testWidgets('every other theme keeps the neutral lunar grey', (tester) async {
    final pumped = await _pumpMoon(
      tester,
      theme: SkotiqTheme.dark,
      colors: SkotiqColors.dark,
    );
    expect(pumped.painter.litColor, moonLitGrey);

    await _teardown(tester, pumped.container);
  });
}
