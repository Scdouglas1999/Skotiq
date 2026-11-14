// Tonight's keys: Alt+1–6 pick a panel tab, Alt+S/L/F run the action and
// show its tab, Alt+P pauses or resumes under the header's own gating, and
// typing in a field triggers nothing.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/night_control/night_control_shortcuts.dart';

import 'fixtures/night_fixtures.dart';
import 'left/night_widget_test_support.dart';

Future<void> _alt(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  await tester.pump();
}

Future<NightHarness> _pump(WidgetTester tester, NightRunPhase phase) async {
  final harness = NightHarness(
    board: phase == NightRunPhase.notSetUp
        ? NightFixtures.ready()
        : NightFixtures.running(),
    header: headerFor(phase),
  );
  await harness.pump(
    tester,
    const NightControlShortcuts(
      child: SizedBox(width: 300, child: TextField()),
    ),
  );
  return harness;
}

void main() {
  testWidgets('Alt+digits pick the panel tabs', (tester) async {
    final harness = await _pump(tester, NightRunPhase.running);
    await _alt(tester, LogicalKeyboardKey.digit3);
    expect(harness.container.read(nightPanelTabProvider), NightPanelTab.focus);
    await _alt(tester, LogicalKeyboardKey.digit6);
    expect(harness.container.read(nightPanelTabProvider), NightPanelTab.solve);
  });

  testWidgets('Alt+S, Alt+L and Alt+F run the action and show its tab',
      (tester) async {
    final harness = await _pump(tester, NightRunPhase.running);
    await _alt(tester, LogicalKeyboardKey.keyS);
    await _alt(tester, LogicalKeyboardKey.keyL);
    await _alt(tester, LogicalKeyboardKey.keyF);
    expect(harness.api.calls, <String>[
      'run:${ManualActionId.snapshot}',
      'run:${ManualActionId.loop}',
      'run:${ManualActionId.autofocus}',
    ]);
    expect(harness.container.read(nightPanelTabProvider), NightPanelTab.focus);
  });

  testWidgets('Alt+P pauses a running run and resumes a paused one',
      (tester) async {
    final running = await _pump(tester, NightRunPhase.running);
    await _alt(tester, LogicalKeyboardKey.keyP);
    expect(running.actions!.calls, <String>['pause']);
  });

  testWidgets('Alt+P resumes a run the operator paused', (tester) async {
    final paused = await _pump(tester, NightRunPhase.pausedByUser);
    await _alt(tester, LogicalKeyboardKey.keyP);
    expect(paused.actions!.calls, <String>['resume']);
  });

  testWidgets('Alt+P does nothing without a run to pause', (tester) async {
    final idle = await _pump(tester, NightRunPhase.notSetUp);
    await _alt(tester, LogicalKeyboardKey.keyP);
    expect(idle.actions?.calls ?? const <String>[], isEmpty);
  });

  testWidgets('plain letters typed in a field stay in the field',
      (tester) async {
    final harness = await _pump(tester, NightRunPhase.running);
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'slfp');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.pump();
    expect(find.text('slfp'), findsOneWidget);
    expect(harness.api.calls, isEmpty);
  });
}
