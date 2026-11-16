import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
import 'package:skotiq_app/screens/sequencer/widgets/continue_run_button.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Analytics behind a router that reads its location the way the app's does,
/// over canned records.
({Widget app, GoRouter router}) historyApp({
  String location = '/analytics?tab=history',
  List<ImagingSession> sessions = const [],
  List<SequenceRun> runs = const [],
  List<DbCapturedImage> standalone = const [],
  List<DbCapturedImage> images = const [],
  List<DbTarget> targets = const [],
  Map<int, List<JournalNote>> notes = const {},
  Map<int, List<ReplayDecision>> decisions = const {},
  Stream<List<ImagingSession>>? sessionStream,
  List<Override> overrides = const [],
}) {
  final router = GoRouter(
    initialLocation: location,
    routes: [
      GoRoute(
        path: '/analytics',
        builder: (context, state) {
          final query = state.uri.queryParameters;
          return Scaffold(
            body: AnalyticsScreen(
              initialTab: AnalyticsTab.fromQuery(query['tab']),
              initialScienceView: ScienceTab.fromQuery(query['view']),
              initialSessionView: SessionView.fromQuery(query['view']),
              night: NightRef.fromQuery(query),
              nightView: NightView.fromQuery(query['view']),
              historySequenceId: int.tryParse(query['sequence'] ?? ''),
            ),
          );
        },
      ),
      GoRoute(
        path: '/darkroom',
        builder: (context, state) =>
            Scaffold(body: Text('darkroom ${state.uri.query}')),
      ),
    ],
  );
  return (
    router: router,
    app: ProviderScope(
      overrides: [
        allSessionsProvider
            .overrideWith((ref) => sessionStream ?? Stream.value(sessions)),
        sequenceRunsProvider.overrideWith((ref) => Stream.value(runs)),
        standaloneImagesProvider
            .overrideWith((ref) => Stream.value(standalone)),
        allDbImagesProvider.overrideWith((ref) => Stream.value(images)),
        allDbTargetsProvider.overrideWith((ref) => Stream.value(targets)),
        dbSessionImagesProvider.overrideWith(
          (ref, id) => Stream.value(
            [
              for (final image in images)
                if (image.sessionId == id) image
            ],
          ),
        ),
        notesForRunProvider
            .overrideWith((ref, id) => Stream.value(notes[id] ?? const [])),
        decisionsForRunProvider.overrideWith(
          (ref, id) => Stream.value(decisions[id] ?? const []),
        ),
        continuableCheckpointProvider.overrideWith((ref) async => null),
        ...overrides,
      ],
      child: MaterialApp.router(
        theme: SkotiqTheme.dark,
        routerConfig: router,
      ),
    ),
  );
}

/// Sizes the test window for the length of the test.
void useWindow(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Lets a navigation or a menu finish. The screen keeps a shimmer or a
/// loading mark running in places, so `pumpAndSettle` never returns.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
