// Dashboard ▸ Last night ▸ "Open last run" must land on the run. The card body
// around that button deep-links the same run to `/session-review?session=<id>`,
// so a button that lands on the empty Sequence BUILDER — 0 nodes, 0 frames —
// promises strictly less than the card it sits in.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/dashboard/widgets/standby/last_night_recap_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

SequenceRun _run() => SequenceRun(
      id: 1,
      sequenceName: 'New Sequence',
      startedAt: DateTime.now().subtract(const Duration(hours: 1)),
      endedAt: DateTime.now(),
      status: 'completed',
      statsJson: '',
    );

GoRouter _router() => GoRouter(
      initialLocation: '/dashboard',
      routes: [
        GoRoute(
          path: '/dashboard',
          builder: (_, __) => const Scaffold(
            body: LastNightRecapCard(colors: SkotiqColors.dark),
          ),
        ),
        GoRoute(path: '/sequencer', builder: (_, __) => const Text('BUILDER')),
        GoRoute(
          path: '/session-review',
          builder: (_, __) => const Text('SESSION REVIEW'),
        ),
      ],
    );

Future<GoRouter> _pump(WidgetTester tester, {required int? sessionId}) async {
  final router = _router();
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sequenceRunsProvider.overrideWith((ref) => Stream.value([_run()])),
        sequenceRunSessionIdProvider(1).overrideWith((ref) async => sessionId),
      ],
      child: MaterialApp.router(
        theme: SkotiqTheme.dark,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  testWidgets('Open last run opens the run it is describing', (tester) async {
    final router = await _pump(tester, sessionId: 77);

    await tester.tap(find.byType(SkotiqButton));
    await tester.pumpAndSettle();

    expect(
      router.routerDelegate.currentConfiguration.uri.toString(),
      '/session-review?session=77',
    );
    expect(find.text('BUILDER'), findsNothing);
  });

  testWidgets('a run with no session opens History, never the builder',
      (tester) async {
    // The counter-input: not every run has a session row (a run that failed
    // before its first frame). The fallback must still not be the builder,
    // which is the one destination that shows nothing about any run.
    final router = await _pump(tester, sessionId: null);

    await tester.tap(find.byType(SkotiqButton));
    await tester.pumpAndSettle();

    expect(
      router.routerDelegate.currentConfiguration.uri.toString(),
      '/sequencer?tab=history',
    );
  });
}
