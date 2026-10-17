import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/dashboard/widgets/cockpit_morning_report.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

SequenceRun _run() {
  return SequenceRun(
    id: 41,
    sequenceId: 7,
    sequenceName: 'Rosette',
    startedAt: DateTime.utc(2026, 7, 14, 1),
    endedAt: DateTime.utc(2026, 7, 14, 5),
    status: 'completed',
    statsJson: '{"framesCaptured":12,"framesRejected":2}',
  );
}

Widget _app({required int? sessionId}) {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => const Scaffold(body: CockpitMorningReport()),
      ),
      GoRoute(
        path: '/session-review',
        builder: (_, state) => Scaffold(
          body: Text('review ${state.uri.queryParameters['session']}'),
        ),
      ),
      GoRoute(
        path: '/sequencer',
        builder: (_, state) => Scaffold(
          body: Text('sequencer ${state.uri.queryParameters['tab']}'),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);

  return ProviderScope(
    overrides: [
      sequenceRunsProvider.overrideWith((ref) => Stream.value([_run()])),
      sequenceRunSessionIdProvider.overrideWith(
        (ref, runId) async => sessionId,
      ),
    ],
    child: MaterialApp.router(
      theme: SkotiqTheme.dark,
      routerConfig: router,
    ),
  );
}

void main() {
  testWidgets('opens the session resolved for the run, not the run id',
      (tester) async {
    await tester.pumpWidget(_app(sessionId: 73));
    await tester.pumpAndSettle();

    expect(find.text('Open morning report'), findsOneWidget);
    await tester.tap(find.text('Open morning report'));
    await tester.pumpAndSettle();

    expect(find.text('review 73'), findsOneWidget);
    expect(find.text('review 41'), findsNothing);
  });

  testWidgets('a run without a safe session match opens exact run history',
      (tester) async {
    await tester.pumpWidget(_app(sessionId: null));
    await tester.pumpAndSettle();

    expect(find.text('No matching session — open run history'), findsOneWidget);
    await tester.tap(find.text('No matching session — open run history'));
    await tester.pumpAndSettle();

    expect(find.text('sequencer history'), findsOneWidget);
  });
}
