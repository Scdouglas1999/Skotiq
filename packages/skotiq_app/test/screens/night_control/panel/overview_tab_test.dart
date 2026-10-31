// Overview shows readiness before a run and the current operation during it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_app/screens/night_control/panel/overview/overview_sections.dart';
import 'package:skotiq_app/screens/night_control/panel/overview/overview_tab.dart';

import '../fixtures/night_fixtures.dart';
import 'panel_test_support.dart';

/// The log's lines, for the scroll tests to add to.
final _logLines = StateProvider<List<NightLogEntryVm>>((ref) => const []);

List<NightLogEntryVm> _lines(int from, int count) => <NightLogEntryVm>[
      // Newest first: line [from + count - 1] down to line [from].
      for (var i = from + count - 1; i >= from; i--)
        NightLogEntryVm(
          at: DateTime(2026, 10, 20, 22).add(Duration(minutes: i)),
          message: NightText.literal('line $i'),
        ),
    ];

Future<ProviderContainer> _pumpLog(WidgetTester tester) async {
  final container = ProviderContainer(overrides: [
    _logLines.overrideWith((ref) => _lines(0, 40)),
  ]);
  addTearDown(container.dispose);
  await pumpPanel(
    tester,
    container: container,
    overrides: const [],
    child: Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        height: 220,
        child: Consumer(
          builder: (context, ref, _) =>
              NightLogSection(entries: ref.watch(_logLines)),
        ),
      ),
    ),
  );
  return container;
}

void main() {
  group('log', () {
    testWidgets('at the top, a new line shows above the last', (tester) async {
      final container = await _pumpLog(tester);
      expect(find.text('line 39'), findsOneWidget);
      container.read(_logLines.notifier).state = [
        ..._lines(40, 2),
        ...container.read(_logLines),
      ];
      await tester.pump();
      expect(find.text('line 41'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('line 41')).dy,
        lessThan(tester.getTopLeft(find.text('line 40')).dy),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('scrolled away to read, the lines being read hold still',
        (tester) async {
      final container = await _pumpLog(tester);
      await tester.drag(find.byType(ListView), const Offset(0, -150));
      await tester.pumpAndSettle();
      expect(find.text('line 39'), findsNothing);
      final reading = find.text('line 25');
      expect(reading, findsOneWidget);
      final before = tester.getTopLeft(reading);

      container.read(_logLines.notifier).state = [
        ..._lines(40, 3),
        ...container.read(_logLines),
      ];
      await tester.pump();
      expect(tester.getTopLeft(reading), before);
      expect(find.text('line 42'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets(
      'a running night shows the operation, frame, session, sky and log',
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
    expect(find.text('Equipment'), findsNothing);
    expect(find.text('Capturing'), findsWidgets);
    expect(find.text('139'), findsOneWidget);
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
    expect(find.text('Equipment'), findsNothing);
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
