// The session review builds no masters of its own: its build action is a
// shortcut into the Darkroom's guided build for the session's target, which
// combines every night of that target and registers what it writes.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/session_review/narrative_view.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart';

/// A controller that publishes a fixed state and records whether the disabled
/// action was ever able to fire.
class _FixedStateController extends SessionReviewController {
  _FixedStateController(super.ref, super.scope, this._seed);

  final SessionReviewState _seed;
  int reIntegrateCalls = 0;

  @override
  Future<void> loadSmartData({bool recomputeNightReport = false}) async {
    state = _seed;
  }

  @override
  Future<PostSessionIntegrationOutcome?> reIntegrate(
    IntegrationSettings settings,
  ) async {
    reIntegrateCalls++;
    return null;
  }

  @override
  Future<void> refresh() async {}
}

DbCapturedImage _light({required int id, required bool accepted}) =>
    DbCapturedImage(
      id: id,
      filePath: '/lights/l$id.fits',
      fileName: 'l$id.fits',
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 60,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 7, 28, 14, id),
      createdAt: DateTime.utc(2026, 7, 28, 14, id),
      isAccepted: accepted,
      isPlateSolved: false,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  const scope = SessionReviewScope.session(1);

  setUp(() => db = mockDatabase());
  tearDown(() async => db.close());

  Future<(_FixedStateController, GoRouter)> pump(
    WidgetTester tester,
    SessionReviewState seed, {
    bool remoteClient = false,
  }) async {
    late _FixedStateController controller;
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final router = GoRouter(
      initialLocation: '/session-review',
      routes: [
        GoRoute(
          path: '/session-review',
          builder: (context, state) => Scaffold(
            backgroundColor: SkotiqColors.dark.background,
            body: const NarrativeView(scope: scope),
          ),
        ),
        GoRoute(
          path: '/darkroom',
          builder: (context, state) =>
              const Scaffold(body: Text('darkroom stands in here')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sessionReviewControllerProvider(scope).overrideWith((ref) {
            controller = _FixedStateController(ref, scope, seed);
            return controller;
          }),
          if (remoteClient) remoteClientLaunchProvider.overrideWithValue(true),
        ],
        child: MaterialApp.router(
          theme: SkotiqTheme.dark,
          debugShowCheckedModeBanner: false,
          routerConfig: router,
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    return (controller, router);
  }

  testWidgets(
      'the build action opens the target\'s framing check and integrates '
      'nothing here', (tester) async {
    final (controller, router) = await pump(
      tester,
      SessionReviewState(
        loading: false,
        targetName: 'NGC 891',
        subs: [_light(id: 1, accepted: true)],
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('No finished master yet'), findsOneWidget);
    expect(find.text('Integrate now'), findsNothing);
    expect(find.text('Re-integrate'), findsNothing);

    await tester.tap(find.text('Build masters in the Darkroom'));
    await tester.pumpAndSettle();

    final uri = router.routerDelegate.currentConfiguration.uri;
    expect(uri.path, '/darkroom');
    expect(uri.queryParameters, {
      'tab': 'targets',
      'target': 'NGC 891',
      'view': 'framing',
    });
    expect(controller.reIntegrateCalls, 0);
  });

  testWidgets('a session with no target opens the Darkroom target list',
      (tester) async {
    final (_, router) = await pump(
      tester,
      const SessionReviewState(loading: false, subs: []),
    );

    await tester.tap(find.text('Build masters in the Darkroom'));
    await tester.pumpAndSettle();

    expect(
      router.routerDelegate.currentConfiguration.uri.queryParameters,
      {'tab': 'targets'},
    );
  });

  testWidgets('a remote client is told where masters are built',
      (tester) async {
    final (_, router) = await pump(
      tester,
      const SessionReviewState(loading: false, targetName: 'NGC 891'),
      remoteClient: true,
    );

    final semantics = tester.ensureSemantics();
    expect(
      find.bySemanticsLabel(
        RegExp('^Build masters in the Darkroom — The Darkroom works on the '
            'imaging host'),
      ),
      findsOneWidget,
    );
    semantics.dispose();

    await tester.tap(
      find.text('Build masters in the Darkroom'),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(
      router.routerDelegate.currentConfiguration.uri.path,
      '/session-review',
    );
  });
}
