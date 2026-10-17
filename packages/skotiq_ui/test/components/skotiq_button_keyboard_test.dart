// SkotiqButton is operable from the keyboard.
//
// A `Semantics > MouseRegion > GestureDetector` stack owns no focus node, so
// the design system's primary button — used on essentially every screen —
// falls out of Tab traversal and cannot be activated by Enter or Space.
//
// Measured in the 13-step first-run wizard at 1400x900: the only control Tab
// reaches is the header's "Skip onboarding" TextButton, three consecutive Tab
// presses produce a pixel-identical frame (0 differing pixels), and Return
// abandons setup rather than advancing, so the wizard cannot be completed
// without a mouse.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _host(List<Widget> children) => MaterialApp(
  theme: SkotiqTheme.dark,
  home: Scaffold(
    body: Column(mainAxisSize: MainAxisSize.min, children: children),
  ),
);

void main() {
  testWidgets('Tab reaches the button and Enter activates it', (tester) async {
    var pressed = 0;
    await tester.pumpWidget(
      _host([SkotiqButton(label: 'Next', onPressed: () => pressed++)]),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();

    expect(
      Focus.of(tester.element(find.text('Next')), scopeOk: true).hasFocus,
      isTrue,
      reason: 'Tab must be able to land on the button at all',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(pressed, 1, reason: 'Enter must activate the focused button');
  });

  testWidgets('Space activates the focused button', (tester) async {
    var pressed = 0;
    await tester.pumpWidget(
      _host([SkotiqButton(label: 'Save', onPressed: () => pressed++)]),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();

    expect(pressed, 1);
  });

  testWidgets('Tab walks through every button in order', (tester) async {
    final order = <String>[];
    await tester.pumpWidget(
      _host([
        SkotiqButton(label: 'Back', onPressed: () => order.add('Back')),
        SkotiqButton(label: 'Skip', onPressed: () => order.add('Skip')),
        SkotiqButton(label: 'Next', onPressed: () => order.add('Next')),
      ]),
    );

    // Three tabs, activating each stop, must visit all three buttons — the
    // property the wizard needed and did not have.
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
    }

    expect(order, ['Back', 'Skip', 'Next']);
  });

  testWidgets('a disabled button is skipped by Tab', (tester) async {
    var pressed = 0;
    await tester.pumpWidget(
      _host([
        const SkotiqButton(label: 'Disabled', onPressed: null),
        SkotiqButton(label: 'Enabled', onPressed: () => pressed++),
      ]),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(
      pressed,
      1,
      reason:
          'the first Tab stop must be the enabled button, not the '
          'disabled one, and a disabled button must never fire',
    );
  });
}
