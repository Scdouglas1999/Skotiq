// The Run log timeline replays a run from the records the host keeps: the run
// row, its session's frames and its decision log. It needs no linked rig.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/analytics_providers.dart';
import 'package:skotiq_app/screens/analytics/history/night_views/run_timeline.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'history_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final started = DateTime.utc(2026, 5, 25, 22);
  final theRun = run(
    1,
    name: 'Test sequence',
    start: started,
    end: started.add(const Duration(minutes: 10)),
  );

  ReplayDecision decision(int seconds, DecisionCategory category, String text) =>
      ReplayDecision(
        id: seconds,
        sequenceRunId: 1,
        timestamp: started.add(Duration(seconds: seconds)),
        category: category,
        summary: text,
        details: const {},
      );

  Widget host(Widget child, {List<Override> overrides = const []}) =>
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      );

  group('RunRecordsReplaySource', () {
    final source = RunRecordsReplaySource(
      run: theRun,
      targetName: 'M31',
      loadFrames: () async => [
        frame(1, sessionId: 4, at: started.add(const Duration(seconds: 60))),
        // A frame stamped a moment before the run row is not part of it.
        frame(2, sessionId: 4, at: started.subtract(const Duration(seconds: 1))),
      ],
      loadDecisions: () async => [
        decision(120, DecisionCategory.frameRejected, 'Rejected: trailed'),
        decision(10, DecisionCategory.schedulerPick, 'Picked M31'),
      ],
    );

    test('the run carries its frame count and target', () async {
      final detail = await source.fetchRun(1);
      expect(detail.frameCount, 1);
      expect(detail.targetName, 'M31');
      expect(detail.sequenceName, 'Test sequence');
    });

    test('decisions become events in time order, complete', () async {
      final page = await source.fetchEvents(1);
      expect(page.isPartial, isFalse);
      expect(page.items.map((e) => e.message), [
        'Picked M31',
        'Rejected: trailed',
      ]);
      expect(page.items.last.severity, 'warning');
    });

    test('only frames inside the run are replayed', () async {
      final frames = await source.fetchFrames(1);
      expect(frames.map((f) => f.id), [1]);
    });
  });

  testWidgets('a local run replays with no rig linked', (tester) async {
    await tester.pumpWidget(
      host(
        RunTimeline(run: theRun, sessionId: 4, targetName: 'M31'),
        overrides: [
          dbSessionImagesProvider.overrideWith(
            (ref, id) => Stream.value([
              frame(1, sessionId: 4, at: started.add(const Duration(seconds: 60))),
              frame(2, sessionId: 4, at: started.add(const Duration(seconds: 180))),
            ]),
          ),
          decisionsForRunProvider.overrideWith(
            (ref, id) => Stream.value([
              decision(10, DecisionCategory.schedulerPick, 'Picked M31'),
            ]),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('timeline_bar')), findsOneWidget);
    expect(find.text('Replay needs a connected rig'), findsNothing);
    expect(find.text('0 of 2'), findsOneWidget);
    expect(find.text('UP TO HERE · 0 OF 3'), findsOneWidget);
  });

  testWidgets('a run that recorded nothing says so', (tester) async {
    await tester.pumpWidget(
      host(
        RunTimeline(run: theRun, sessionId: null, targetName: null),
        overrides: [
          decisionsForRunProvider.overrideWith((ref, id) => Stream.value([])),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Nothing was recorded for this run'), findsOneWidget);
  });

  testWidgets('a failed load explains and offers Retry', (tester) async {
    await tester.pumpWidget(
      host(
        RunTimeline(
          run: theRun,
          sessionId: null,
          targetName: null,
          dataSourceOverride: _FailingSource(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('The timeline did not load'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}

class _FailingSource implements SessionReplayDataSource {
  @override
  Future<RemoteSequenceRunDetail> fetchRun(int runId) async =>
      throw Exception('boom');

  @override
  Future<RemoteReplayEventsPage> fetchEvents(int runId) async =>
      throw Exception('boom');

  @override
  Future<List<RemoteReplayFrame>> fetchFrames(int runId) async =>
      throw Exception('boom');
}
