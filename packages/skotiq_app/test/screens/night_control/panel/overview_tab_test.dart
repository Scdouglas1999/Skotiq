// The Overview tab against the running and ready boards: the last frame,
// session, equipment, conditions and log during a run; "Before you start"
// in their place before one, and its row actions.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/night_control/panel/overview/overview_tab.dart';

import '../fixtures/night_fixtures.dart';
import 'panel_test_support.dart';

void main() {
  testWidgets('a running night shows the frame, session, gear, sky and log',
      (tester) async {
    await pumpPanel(
      tester,
      child: const NightOverviewTab(),
      overrides: panelOverrides(board: NightFixtures.running()),
    );

    expect(find.text('Last frame · #43'), findsOneWidget);
    expect(find.text('vs night median'), findsOneWidget);
    expect(find.text('2.13'), findsOneWidget);
    expect(find.text('Session'), findsOneWidget);
    expect(find.textContaining('87 frames'), findsOneWidget);
    expect(find.text('Equipment'), findsOneWidget);
    expect(find.text('−10.0 °C · 20% · g139 o21 · 1×1'), findsOneWidget);
    // The rotator is not in the profile.
    expect(find.text('none'), findsOneWidget);
    expect(find.text('Safe'), findsOneWidget);
    expect(find.text('Before you start'), findsNothing);

    await tester.scrollUntilVisible(
      find.text('#43 Ha accepted · HFR 2.13'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('23:49'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('before a run the checklist replaces frame and session',
      (tester) async {
    await pumpPanel(
      tester,
      child: const NightOverviewTab(),
      overrides: panelOverrides(board: NightFixtures.ready()),
    );

    expect(find.text('Before you start'), findsOneWidget);
    expect(find.text('2 to look at'), findsOneWidget);
    expect(find.text('PHD2 connected, not looping'), findsOneWidget);
    expect(find.text('Last frame'), findsNothing);
    expect(find.text('Session'), findsNothing);
    // The state mark is a glyph; its meaning is read out.
    expect(
      find.bySemanticsLabel(
          'Guider, needs a look, PHD2 connected, not looping'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('no weather source says so in the Conditions header',
      (tester) async {
    await pumpPanel(
      tester,
      child: const NightOverviewTab(),
      overrides: panelOverrides(board: NightFixtures.ready()),
    );

    expect(find.text('no weather source'), findsOneWidget);
    expect(find.text('Safe'), findsNothing);
    // Only what the app knows without a source is listed.
    expect(find.text('set 23:09'), findsOneWidget);
    expect(find.text('Clouds'), findsNothing);
  });

  testWidgets('a forecast-only source is labeled as one', (tester) async {
    await pumpPanel(
      tester,
      child: const NightOverviewTab(),
      overrides: panelOverrides(
        board: NightFixtures.running(),
        conditions: const NightConditionsVm(
          source: ConditionsSource.forecast,
          metrics: <MetricVm>[
            MetricVm(
              label: NightText('nightSessionCloudsForecast'),
              value: '20%',
            ),
          ],
        ),
      ),
    );

    expect(find.text('forecast only'), findsOneWidget);
    expect(find.text('Clouds (forecast)'), findsOneWidget);
    expect(find.text('Safe'), findsNothing);
  });

  testWidgets('a checklist route action navigates', (tester) async {
    final router = await pumpPanel(
      tester,
      child: const NightOverviewTab(),
      overrides: panelOverrides(board: NightFixtures.ready()),
    );

    await tester.tap(find.bySemanticsLabel('Add, Weather'));
    await tester.pumpAndSettle();
    expect(routerLocation(router), '/settings?section=weather-safety');
  });

  testWidgets('the guider row loops PHD2 and opens the Guide tab',
      (tester) async {
    final ops = FakePanelOps();
    final container = ProviderContainer(
      overrides: panelOverrides(board: NightFixtures.ready(), ops: ops),
    );
    addTearDown(container.dispose);
    await pumpPanel(
      tester,
      child: const NightOverviewTab(),
      overrides: const <Override>[],
      container: container,
    );

    await tester.tap(find.bySemanticsLabel('Loop, Guider'));
    await tester.pump();
    expect(ops.calls, <String>['guiderLoop']);
    expect(container.read(nightPanelTabProvider), NightPanelTab.guide);
  });

  testWidgets('a failed loop stays on Overview and says why', (tester) async {
    final ops = FakePanelOps()..failWith = Exception('PHD2 is not running');
    final container = ProviderContainer(
      overrides: panelOverrides(board: NightFixtures.ready(), ops: ops),
    );
    addTearDown(container.dispose);
    await pumpPanel(
      tester,
      child: const NightOverviewTab(),
      overrides: const <Override>[],
      container: container,
    );

    await tester.tap(find.bySemanticsLabel('Loop, Guider'));
    await tester.pump();
    expect(
      find.text('PHD2 did not start looping: PHD2 is not running'),
      findsOneWidget,
    );
    expect(container.read(nightPanelTabProvider), NightPanelTab.overview);
    await settleToasts(tester);
  });
}
