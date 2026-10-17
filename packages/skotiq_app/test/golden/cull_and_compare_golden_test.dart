@Tags(['golden'])
library;

// Renders the two workbench culling/compare panels — [SubCullRail] and
// [AbComparePanel] — to inspectable review PNGs under `docs/design/goldens/`.
//
// Both panels are controller-backed, so this seeds a real
// [SessionReviewController] over an in-memory database + a fake post-session
// seam (mirroring `test/screens/session_review/session_review_smart_data_test`)
// and captures each panel mounted under that provider scope. These are review
// artifacts a reviewer eyeballs, not pixel-diff guards: the assertions only
// check a real, non-empty image was produced.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';
import 'package:skotiq_app/screens/session_review/widgets/ab_compare_panel.dart';
import 'package:skotiq_app/screens/session_review/widgets/sub_cull_rail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../harness/mock_database.dart';
import 'surface_golden_harness.dart';

/// Minimal fake seam: the panels only need the controller to *construct* and
/// publish settings; no integration is actually run in the golden.
class _FakeSeam implements PostSessionSeam {
  @override
  Stream<({String phase, double fraction})> integrationProgress() =>
      const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      '${invocation.memberName} not stubbed in golden');
}

void main() {
  setUpAll(SurfaceGoldenHarness.ensureFonts);

  late SkotiqDatabase db;
  late int sessionId;
  late SessionReviewScope scope;

  setUp(() async {
    db = mockDatabase();
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      postSessionSeamProvider.overrideWithValue(_FakeSeam()),
    ]);
    final sessions = container.read(sessionsDaoProvider);
    final images = container.read(imagesDaoProvider);
    sessionId = await sessions.createSession(
      ImagingSessionsCompanion.insert(startTime: DateTime.now()),
    );
    for (var i = 0; i < 8; i++) {
      await images.createImage(
        CapturedImagesCompanion.insert(
          filePath: 'C:/subs/s$i.fits',
          fileName: 's$i.fits',
          sessionId: Value(sessionId),
          exposureDuration: 120,
          frameType: const Value('light'),
          filter: const Value('Ha'),
          hfr: Value(2.2 + (i % 4) * 0.4),
          starCount: Value(900 - i * 30),
          // Reject the worst two so the rail shows a mix of states.
          isAccepted: Value(i < 6),
          capturedAt: DateTime.now().add(Duration(minutes: i)),
        ),
      );
    }
    container.dispose();
    scope = SessionReviewScope.session(sessionId);
  });

  tearDown(() async {
    await db.close();
  });

  Future<ProviderScope> scopedSurface(Widget child) async {
    return ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        postSessionSeamProvider.overrideWithValue(_FakeSeam()),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: SkotiqColors.dark.background,
          body: child,
        ),
      ),
    );
  }

  testWidgets('morning report — sub cull rail (dark)', (tester) async {
    tester.view.physicalSize = const Size(940, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final boundaryKey = GlobalKey();
    await tester.pumpWidget(await scopedSurface(
      Center(
        child: RepaintBoundary(
          key: boundaryKey,
          child: SizedBox(
            width: 900,
            height: 680,
            child: Consumer(
              builder: (context, ref, _) {
                final state = ref.watch(sessionReviewControllerProvider(scope));
                final controller =
                    ref.read(sessionReviewControllerProvider(scope).notifier);
                return SubCullRail(
                  subs: state.lights,
                  controller: controller,
                  onTapSub: (_) {},
                  onSetAccepted: (_, __) {},
                  onBulkCull: ({hfrThreshold, qualityThreshold}) {},
                );
              },
            ),
          ),
        ),
      ),
    ));
    await _settle(tester);

    final file = await SurfaceGoldenHarness.captureBoundary(
      tester,
      boundaryKey,
      fileName: 'morning-report-sub-cull-rail.png',
    );
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(1024));
    expect(tester.takeException(), isNull);
  });

  testWidgets('morning report — A/B compare panel (dark)', (tester) async {
    tester.view.physicalSize = const Size(940, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final boundaryKey = GlobalKey();
    await tester.pumpWidget(await scopedSurface(
      SingleChildScrollView(
        padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
        child: RepaintBoundary(
          key: boundaryKey,
          child: SizedBox(
            width: 900,
            child: Consumer(
              builder: (context, ref, _) {
                final controller =
                    ref.watch(sessionReviewControllerProvider(scope).notifier);
                return AbComparePanel(controller: controller);
              },
            ),
          ),
        ),
      ),
    ));
    await _settle(tester);

    final file = await SurfaceGoldenHarness.captureBoundary(
      tester,
      boundaryKey,
      fileName: 'morning-report-ab-compare.png',
    );
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(1024));
    expect(tester.takeException(), isNull);
  });
}

/// Let the controller's async `_load` settle and the panels rebuild, without
/// `pumpAndSettle` (thumbnails/spinners can animate indefinitely).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}
