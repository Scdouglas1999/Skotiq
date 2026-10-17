// The narrative hero's only call to action must say why it cannot run.
//
// Observed defect: on a calibration-only session the empty state read "No
// finished master yet — Run an integration to see tonight's master here" and
// offered an "Integrate now" button that did nothing when clicked — no toast,
// no dialog, no log line, no tooltip, and barely dimmer than an enabled button.
// The Workbench tab on the same screen stated the reason plainly ("No light
// subs"), so the information existed one tab away.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

  Future<_FixedStateController> pump(
    WidgetTester tester,
    SessionReviewState seed,
  ) async {
    late _FixedStateController controller;
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sessionReviewControllerProvider(scope).overrideWith((ref) {
            controller = _FixedStateController(ref, scope, seed);
            return controller;
          }),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            backgroundColor: SkotiqColors.dark.background,
            body: const NarrativeView(scope: scope),
          ),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    return controller;
  }

  testWidgets('a calibration-only session states that it has no light frames',
      (tester) async {
    final controller = await pump(
      tester,
      const SessionReviewState(loading: false, subs: []),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('No finished master yet'), findsOneWidget);
    expect(
      find.textContaining('captured no light frames'),
      findsOneWidget,
      reason: 'the narrative must give the reason the Workbench already knows',
    );
    // The generic "run an integration" invitation is gone — it was a dead end.
    expect(find.textContaining('Run an integration to see'), findsNothing);

    // A disabled button is not silently clickable.
    await tester.tap(find.text('Integrate now'), warnIfMissed: false);
    await tester.pump();
    expect(controller.reIntegrateCalls, 0);

    // The reason is also on the button itself, for a pointer user at 2am.
    final tooltips = tester
        .widgetList<Tooltip>(find.byType(Tooltip))
        .map((t) => t.message)
        .whereType<String>();
    expect(
      tooltips.any((m) => m.contains('captured no light frames')),
      isTrue,
    );
  });

  testWidgets('an all-rejected session says so, with the frame count',
      (tester) async {
    await pump(
      tester,
      SessionReviewState(
        loading: false,
        subs: [
          _light(id: 1, accepted: false),
          _light(id: 2, accepted: false),
          _light(id: 3, accepted: false),
        ],
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.textContaining('3 light frames is'), findsOneWidget);
    expect(find.textContaining('Accept at least one sub'), findsOneWidget);
  });

  testWidgets('with accepted subs the action is enabled and fires',
      (tester) async {
    final controller = await pump(
      tester,
      SessionReviewState(
        loading: false,
        subs: [_light(id: 1, accepted: true)],
      ),
    );

    expect(find.textContaining('Run an integration to see'), findsOneWidget);
    await tester.tap(find.text('Integrate now'));
    await tester.pump();
    expect(controller.reIntegrateCalls, 1);
  });
}
