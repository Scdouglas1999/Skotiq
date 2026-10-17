import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/imaging/widgets/capture_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// A frame shaped like the ones the ad-hoc Snapshot/Loop path produces: real,
/// on disk, persisted as a standalone row, and with no database session.
CapturedImage _frame(int index) => CapturedImage(
      id: 'frame-$index',
      filePath: '/captures/frame_$index.fits',
      capturedAt: DateTime.utc(2026, 7, 29, 15, index),
      settings: const ExposureSettings(
        exposureTime: 3.0,
        gain: 100,
        offset: 10,
      ),
      stats: const ImageStats(hfr: 2.5, starCount: 39),
    );

({GoRouter router, ValueNotifier<String?> visited}) _router() {
  final visited = ValueNotifier<String?>(null);
  final router = GoRouter(
    initialLocation: '/imaging',
    routes: [
      GoRoute(
        path: '/imaging',
        builder: (_, __) => Scaffold(
          body: Builder(
            builder: (context) =>
                CapturePanel(colors: SkotiqColors.of(context)),
          ),
        ),
      ),
      GoRoute(
        path: '/analytics',
        builder: (_, state) {
          visited.value = state.uri.toString();
          return const Scaffold(body: Text('QUICK CAPTURE LIST'));
        },
      ),
      GoRoute(
        path: '/session-review',
        builder: (_, state) {
          visited.value = state.uri.toString();
          return const Scaffold(body: Text('SESSION REVIEW'));
        },
      ),
    ],
  );
  return (router: router, visited: visited);
}

Widget _app(GoRouter router, ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(
      theme: SkotiqTheme.dark,
      routerConfig: router,
    ),
  );
}

class _SeededSessionState extends SessionStateNotifier {
  _SeededSessionState(super.ref, SessionState seed) {
    state = seed;
  }
}

SkotiqButton _galleryButton(WidgetTester tester) {
  return tester
      .widgetList<SkotiqButton>(find.byType(SkotiqButton))
      .firstWhere(
        (button) =>
            button.label == 'View gallery' ||
            button.label == 'View quick captures',
      );
}

void main() {
  testWidgets(
      'ad-hoc frames with no db session reach Quick Capture instead of being '
      'denied', (tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container =
        ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(container.dispose);

    // Exactly what the manual Loop path does: frames land in the in-memory
    // session list and integration accrues, but startSession is never called
    // so dbSessionId stays null.
    for (var i = 1; i <= 11; i++) {
      container.read(sessionImagesProvider.notifier).addImage(_frame(i));
      container
          .read(sessionStateProvider.notifier)
          .recordExposureComplete(exposureTime: 3.0);
    }
    expect(container.read(sessionStateProvider).dbSessionId, isNull);
    expect(container.read(recentSessionFramesProvider), hasLength(11));

    final h = _router();
    addTearDown(h.router.dispose);
    addTearDown(h.visited.dispose);

    await tester.pumpWidget(_app(h.router, container));
    await tester.pumpAndSettle();

    // The counter and the button must never disagree: 11 frames means the
    // review affordance is live.
    expect(find.text('11'), findsWidgets);
    final button = _galleryButton(tester);
    expect(button.onPressed, isNotNull);
    expect(button.label, 'View quick captures');

    await tester.tap(find.text('View quick captures'));
    await tester.pumpAndSettle();

    // It must land on the view that actually holds these frames, and must not
    // claim the session does not exist.
    expect(h.visited.value, '/analytics?tab=session');
    expect(find.text('QUICK CAPTURE LIST'), findsOneWidget);
    expect(find.textContaining('No active session'), findsNothing);
  });

  testWidgets('with no frames and no session the button is disabled, not lying',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container =
        ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(container.dispose);
    expect(container.read(recentSessionFramesProvider), isEmpty);

    final h = _router();
    addTearDown(h.router.dispose);
    addTearDown(h.visited.dispose);

    await tester.pumpWidget(_app(h.router, container));
    await tester.pumpAndSettle();

    expect(find.text('0'), findsWidgets);
    expect(_galleryButton(tester).onPressed, isNull);

    await tester.tap(find.text('View quick captures'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(h.visited.value, isNull);
    expect(find.textContaining('No active session'), findsNothing);
  });

  testWidgets('a real sequencer session still routes to session review',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        // A sequencer run is the only thing that sets dbSessionId; seed the
        // state directly rather than standing up SessionService + a database.
        sessionStateProvider.overrideWith(
          (ref) => _SeededSessionState(
            ref,
            const SessionState(
              isActive: true,
              dbSessionId: 46,
              completedExposures: 1,
              totalIntegrationSecs: 3.0,
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    container.read(sessionImagesProvider.notifier).addImage(_frame(1));
    expect(container.read(sessionStateProvider).dbSessionId, 46);

    final h = _router();
    addTearDown(h.router.dispose);
    addTearDown(h.visited.dispose);

    await tester.pumpWidget(_app(h.router, container));
    await tester.pumpAndSettle();

    expect(_galleryButton(tester).label, 'View gallery');

    await tester.tap(find.text('View gallery'));
    await tester.pumpAndSettle();

    expect(h.visited.value, '/session-review?session=46');
  });
}
