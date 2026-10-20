// The Focus tab: the live V-curve with "point n of N" and its points table,
// Cancel by whoever started the run, focuser moves, temperature
// compensation and this session's runs.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart' show VCurvePoint;
import 'package:skotiq_app/screens/night_control/data/session/session_format.dart';
import 'package:skotiq_app/screens/night_control/panel/focus/focus_panel_vm.dart';
import 'package:skotiq_app/screens/night_control/panel/focus/focus_tab.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../fixtures/night_fixtures.dart';
import 'panel_test_support.dart';

Finder _button(String label) => find.bySemanticsLabel(label);

void main() {
  testWidgets('a running autofocus draws its curve and points', (tester) async {
    await pumpPanel(
      tester,
      child: const NightFocusTab(),
      overrides: panelOverrides(board: NightFixtures.autofocus()),
    );

    expect(find.text('Running · point 6 of 9'), findsOneWidget);
    expect(find.byType(VCurveChart), findsOneWidget);
    expect(find.text(nightGrouped(45559)),
        findsNWidgets(2)); // point 6 and the focuser
    expect(find.text('2.08'), findsOneWidget);
    expect(find.text('pos'), findsOneWidget);
    // No per-point star counts on this base: no stars column.
    expect(find.text('stars'), findsNothing);
    // The fit exists only once the run finishes.
    expect(find.textContaining('R²'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the stars column appears once per-point counts exist',
      (tester) async {
    await pumpPanel(
      tester,
      child: const NightFocusTab(),
      overrides: panelOverrides(
        board: NightFixtures.autofocus(),
        focus: PanelFixtures.focusRunning(
          starCounts: <int?>[980, 1040, 1090, 1102, 1166, 1131],
        ),
      ),
    );

    expect(find.text('stars'), findsOneWidget);
    expect(find.text('1131'), findsOneWidget);
  });

  test('star counts come from the V-curve points, index for index', () {
    expect(
      nightAfStarCounts(const [
        VCurvePoint(position: 100, hfr: 3.1, starCount: 812),
        VCurvePoint(position: 200, hfr: 2.4),
        VCurvePoint(position: 300, hfr: 2.9, starCount: 905),
      ]),
      <int?>[812, null, 905],
    );
    // No point has a count (an older build): no column, never zeros.
    expect(
      nightAfStarCounts(const [VCurvePoint(position: 100, hfr: 3.1)]),
      isNull,
    );
    expect(nightAfStarCounts(const []), isNull);
  });

  testWidgets('Cancel goes through the action controller for its own run',
      (tester) async {
    final api = FakeActionApi();
    final ops = FakePanelOps();
    await pumpPanel(
      tester,
      child: const NightFocusTab(),
      overrides: panelOverrides(
        board: NightFixtures.autofocus(),
        api: api,
        ops: ops,
      ),
    );

    await tester.tap(_button('Cancel autofocus'));
    await tester.pump();
    expect(api.calls, <String>['cancel']);
    expect(ops.calls, isEmpty);
  });

  testWidgets('Cancel stops a sequencer autofocus through the device',
      (tester) async {
    final api = FakeActionApi();
    final ops = FakePanelOps();
    await pumpPanel(
      tester,
      child: const NightFocusTab(),
      overrides: panelOverrides(
        board: NightFixtures.running(),
        focus: PanelFixtures.focusRunning(startedHere: false),
        api: api,
        ops: ops,
      ),
    );

    await tester.tap(_button('Cancel autofocus'));
    await tester.pump();
    expect(ops.calls, <String>['cancelAutofocus']);
    expect(api.calls, isEmpty);
  });

  testWidgets('focuser moves are off while autofocus runs; Halt is not',
      (tester) async {
    final ops = FakePanelOps();
    await pumpPanel(
      tester,
      child: const NightFocusTab(),
      overrides: panelOverrides(board: NightFixtures.autofocus(), ops: ops),
    );

    await tester.ensureVisible(_button('Move focuser in 500 steps'));
    await tester.tap(_button('Move focuser in 500 steps'));
    await tester.pump();
    expect(ops.calls, isEmpty);
    expect(
      tester.getSemantics(_button('Move focuser in 500 steps')),
      matchesSemantics(
        label: 'Move focuser in 500 steps',
        hint: 'Autofocus is running',
        isButton: true,
        hasEnabledState: true,
        hasSelectedState: true,
      ),
    );
    await tester.tap(_button('Halt the focuser'));
    await tester.pump();
    expect(ops.calls, <String>['halt']);
  });

  testWidgets('idle: Run starts autofocus through the action controller',
      (tester) async {
    final api = FakeActionApi();
    await pumpPanel(
      tester,
      child: const NightFocusTab(),
      overrides: panelOverrides(
        board: NightFixtures.ready(),
        focus: PanelFixtures.focusIdle,
        api: api,
      ),
    );

    expect(_button('Cancel autofocus'), findsNothing);
    await tester.tap(_button('Run autofocus'));
    await tester.pump();
    expect(api.calls, <String>['run autofocus']);
  });

  testWidgets('while autofocus runs, Cancel takes the place of Run',
      (tester) async {
    await pumpPanel(
      tester,
      child: const NightFocusTab(),
      overrides: panelOverrides(board: NightFixtures.autofocus()),
    );
    expect(_button('Run autofocus'), findsNothing);
    expect(_button('Cancel autofocus'), findsOneWidget);
  });

  testWidgets('idle: jog and go-to move the focuser', (tester) async {
    final ops = FakePanelOps();
    await pumpPanel(
      tester,
      child: const NightFocusTab(),
      overrides: panelOverrides(
        board: NightFixtures.ready(),
        focus: PanelFixtures.focusIdle,
        ops: ops,
      ),
    );

    expect(find.text('No autofocus run yet this session'), findsNWidgets(2));
    await tester.tap(_button('Move focuser out 100 steps'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '45 470');
    await tester.tap(_button('Move the focuser to the position'));
    await tester.pump();
    expect(ops.calls, <String>['jog 100', 'goTo 45470']);

    await tester.enterText(find.byType(TextField), '700000');
    await tester.tap(_button('Move the focuser to the position'));
    await tester.pump();
    expect(find.text('Enter 0 to ${nightGrouped(600000)}'), findsOneWidget);
    expect(ops.calls, hasLength(2));
  });

  testWidgets('temperature compensation shows only when it is on',
      (tester) async {
    await pumpPanel(
      tester,
      child: const NightFocusTab(),
      overrides: panelOverrides(board: NightFixtures.autofocus()),
    );
    await tester.scrollUntilVisible(
      find.text('Temperature compensation'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('−18 /°C'), findsOneWidget);
    expect(find.text('13.1 °C'), findsOneWidget);
    expect(find.text('+20'), findsOneWidget);
  });

  testWidgets('no compensation model hides the block', (tester) async {
    await pumpPanel(
      tester,
      child: const NightFocusTab(),
      overrides: panelOverrides(
        board: NightFixtures.ready(),
        focus: PanelFixtures.focusIdle,
      ),
    );
    expect(find.text('Temperature compensation'), findsNothing);
  });

  testWidgets('recent runs are this session\'s, newest first', (tester) async {
    await pumpPanel(
      tester,
      child: const NightFocusTab(),
      overrides: panelOverrides(board: NightFixtures.autofocus()),
    );
    await tester.scrollUntilVisible(
      find.text('21:40'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('this session'), findsOneWidget);
    final newest = tester.getTopLeft(find.text('23:10')).dy;
    final older = tester.getTopLeft(find.text('21:40')).dy;
    expect(newest, lessThan(older));
    expect(find.text('1.98'), findsOneWidget);
  });

  testWidgets('a finished run states its fit and minimum', (tester) async {
    await pumpPanel(
      tester,
      child: const NightFocusTab(),
      overrides: panelOverrides(
        board: NightFixtures.running(),
        focus: const NightFocusPanelVm(
          canCommand: true,
          runLive: true,
          status: NightAutofocusStatus.done,
          points: PanelFixtures.sixPoints,
          bestPosition: 45470,
          bestHfr: 1.97,
          fitQuality: 0.994,
          focuserConnected: true,
          position: 45470,
        ),
      ),
    );

    expect(find.text('Done'), findsOneWidget);
    expect(find.text('fit R² 0.994 · min ≈ ${nightGrouped(45470)} · 1.97'),
        findsOneWidget);
    // Nothing running: Run takes Cancel's place.
    expect(_button('Cancel autofocus'), findsNothing);
    expect(_button('Run autofocus'), findsOneWidget);
  });
}
