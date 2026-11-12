// SY-24 (sync night 2026-11-03): the run's warnings (the tracking-limit
// stop, "did not flip early", a centering that missed) were in the host's
// run stats and on neither machine's Tonight.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/run_warnings_banner.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

const _center = 'Center: Failed to center within 5.0" after 5 attempts.';
const _limit = 'Mount tracking stopped 33 min before the meridian.';
const _early = 'The mount did not flip early.';

SequenceRunStats _stats(List<String> warnings) =>
    SequenceRunStats.fromRemoteVitals(
      SequencerRunVitals(
        startTime: DateTime(2026, 11, 3, 20, 21),
        framesCaptured: 11,
        framesRejected: 1,
        integrationSecs: 600,
        triggerFires: 2,
        autofocusRuns: 1,
        meridianFlips: 0,
        ditherCount: 3,
        warningMessages: warnings,
      ),
    );

Future<ProviderContainer> _pump(
  WidgetTester tester,
  SequenceRunStats? stats, {
  double width = 1316,
}) async {
  final container = ProviderContainer(
    overrides: [liveSequenceStatsProvider.overrideWith((ref) => stats)],
  );
  addTearDown(container.dispose);
  tester.view.physicalSize = Size(width, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: NightRunWarningsBanner()),
      ),
    ),
  );
  return container;
}

void main() {
  testWidgets('no run or no warnings: nothing shows', (tester) async {
    await _pump(tester, null);
    expect(find.byType(Container), findsNothing);
    await _pump(tester, _stats(const []));
    expect(find.textContaining('run warning'), findsNothing);
  });

  testWidgets('the count and the newest warning show on one line',
      (tester) async {
    await _pump(tester, _stats(const [_center, _limit, _early]));
    expect(find.text('3 run warnings'), findsOneWidget);
    expect(find.text(_early), findsOneWidget);
    expect(find.text(_center), findsNothing);
  });

  testWidgets('Show all lists every warning, newest first', (tester) async {
    await _pump(tester, _stats(const [_center, _limit, _early]));
    await tester.tap(find.text('Show all'));
    await tester.pump();
    final texts = [
      for (final w in const [_early, _limit, _center])
        tester.getTopLeft(find.text(w)).dy,
    ];
    expect(texts, orderedEquals([...texts]..sort()));
    expect(find.text('Show less'), findsOneWidget);
  });

  testWidgets('hidden until the run records another warning', (tester) async {
    final container = await _pump(tester, _stats(const [_center, _limit]));
    await tester.tap(find.byTooltip('Hide until the next warning'));
    await tester.pump();
    expect(find.textContaining('run warning'), findsNothing);

    container.read(runRecordProvider.notifier).setStats(_stats(const [_center, _limit]));
    await tester.pump();
    expect(find.textContaining('run warning'), findsNothing,
        reason: 'the same warnings again stay hidden');

    container.read(runRecordProvider.notifier).setStats(_stats(const [_center, _limit, _early]));
    await tester.pump();
    expect(find.text('3 run warnings'), findsOneWidget);
    expect(find.text(_early), findsOneWidget);
  });

  testWidgets('hiding it outlasts leaving Tonight and reaches the link',
      (tester) async {
    final container = await _pump(tester, _stats(const [_center, _limit]));
    await tester.tap(find.byTooltip('Hide until the next warning'));
    await tester.pump();

    // The hidden list is shared state, not the widget's: the noticeAcks
    // runtime channel carries it to the other end of a link.
    final acks = container.read(noticeAcknowledgmentsProvider);
    expect(acks.runWarnings?.covers(null, const [_center, _limit]), isTrue);

    // Leaving Tonight disposes the banner; coming back must not show it.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: SizedBox()),
        ),
      ),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: NightRunWarningsBanner()),
        ),
      ),
    );
    expect(find.textContaining('run warning'), findsNothing);
  });

  testWidgets('hidden on the other end of a link hides it here',
      (tester) async {
    final container = await _pump(tester, _stats(const [_center]));
    expect(find.text('1 run warning'), findsOneWidget);
    container.read(noticeAcknowledgmentsProvider.notifier).state =
        const NoticeAcknowledgments().hidingRunWarnings(null, const [_center]);
    await tester.pump();
    expect(find.textContaining('run warning'), findsNothing);
  });

  testWidgets('fits a phone width', (tester) async {
    await _pump(tester, _stats(const [_center, _limit, _early]), width: 390);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Show all'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
