import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/cockpit_session_vitals.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _wrap(List<Override> overrides) {
  return ProviderScope(
    overrides: [...overrides],
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: const Scaffold(body: CockpitSessionVitals()),
    ),
  );
}

void main() {
  testWidgets('idle (no live stats) renders the slim idle row without throwing',
      (tester) async {
    await tester.pumpWidget(_wrap([
      liveSequenceStatsProvider.overrideWith((ref) => null),
    ]));
    await tester.pump();

    expect(
      find.text('No active session — vitals appear during a run.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('active run renders efficiency + counters', (tester) async {
    // Build a stats object with a known integration/overhead split and a few
    // counters. wallClockSecs is derived from startTime → now, so set a start
    // time well in the past and an integration just under it.
    final stats = SequenceRunStats()
      ..framesCaptured = 12
      ..framesRejected = 3
      ..autofocusRuns = 2
      ..meridianFlips = 1
      ..ditherCount = 5
      ..triggerFires = 4
      ..integrationSecs = 600;

    await tester.pumpWidget(_wrap([
      liveSequenceStatsProvider.overrideWith((ref) => stats),
    ]));
    await tester.pump();

    // Header present, no exception.
    expect(find.text('SESSION VITALS'), findsOneWidget);
    // Counters surfaced (tabular figures, raw values).
    expect(find.text('12'), findsOneWidget); // captured
    expect(find.text('3'), findsOneWidget); // rejected
    expect(find.text('2'), findsOneWidget); // autofocus
    expect(find.text('5'), findsOneWidget); // dithers
    // An "NN% efficient" readout renders.
    expect(find.textContaining('% efficient'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rejected counter is error-tinted when > 0', (tester) async {
    final stats = SequenceRunStats()
      ..framesCaptured = 8
      ..framesRejected = 2
      ..integrationSecs = 100;

    await tester.pumpWidget(_wrap([
      liveSequenceStatsProvider.overrideWith((ref) => stats),
    ]));
    await tester.pump();

    final rejectedText = tester.widget<Text>(find.text('2'));
    expect(rejectedText.style!.color, SkotiqColors.dark.error);
  });
}
