// The cull rail must decide at RENDER time whether the curve-driven cull is
// offerable, using the same evaluation the press handler runs. Offering an
// enabled, quantified "Keep best 1 (+0%)" whenever a curve carries a keep-set,
// and only discovering the curve is stale after the press, advertises an
// operation the control will unconditionally refuse.
//
// These are full-wiring tests: a real SessionReviewController over a real
// in-memory database, with the real widget pumped against it. Nothing is
// stubbed, so cutting either half (the controller's offer evaluation or the
// rail's gate on it) fails them.

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';
import 'package:skotiq_app/screens/session_review/widgets/sub_cull_rail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart';

/// Minimal seam: the controller binds its progress stream on construction and
/// never calls anything else in these tests.
class _FakeSeam implements PostSessionSeam {
  @override
  Stream<({String phase, double fraction})> integrationProgress() =>
      const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late ProviderContainer container;
  late int sessionId;

  setUp(() async {
    db = mockDatabase();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      postSessionSeamProvider.overrideWithValue(_FakeSeam()),
    ]);

    final sessions = container.read(sessionsDaoProvider);
    final images = container.read(imagesDaoProvider);

    sessionId = await sessions.createSession(
      ImagingSessionsCompanion.insert(startTime: DateTime.now()),
    );

    for (var i = 0; i < 4; i++) {
      await images.createImage(
        CapturedImagesCompanion.insert(
          filePath: 'C:/subs/s$i.fits',
          fileName: 's$i.fits',
          sessionId: Value(sessionId),
          exposureDuration: 60,
          frameType: const Value('light'),
          filter: const Value('L'),
          hfr: Value(2.0 + i * 0.1),
          isAccepted: const Value(true),
          capturedAt: DateTime.now().add(Duration(minutes: i)),
        ),
      );
    }
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  SessionReviewController controller() => container.read(
        sessionReviewControllerProvider(SessionReviewScope.session(sessionId))
            .notifier,
      );

  SessionReviewState state() => container.read(
        sessionReviewControllerProvider(SessionReviewScope.session(sessionId)),
      );

  Future<void> waitUntilLoaded(WidgetTester tester) async {
    for (var i = 0;
        i < 50 && (state().loading || state().loadingSmartData);
        i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  /// Seed a finalized master carrying an improvement curve, so the controller
  /// picks it up as the reviewed master and loads the curve + population.
  Future<void> seedMasterWithCurve({
    required int keepN,
    required List<int> keptIndices,
    required double gainPct,
    required List<String> populationPaths,
  }) async {
    final masters = container.read(integratedMastersDaoProvider);
    final images = container.read(imagesDaoProvider);
    final id = await masters.insertMaster(
      targetId: null,
      name: 'Test master',
      masterFitsPath: '/tmp/m.fits',
      previewPngPath: null,
      sidecarPath: null,
      rejectionMapPath: null,
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
      channels: 1,
      width: 100,
      height: 100,
      frameCount: populationPaths.length,
      totalIntegrationSeconds: populationPaths.length * 60.0,
      filter: 'L',
      settingsJson: '{}',
      statsJson: '{}',
    );
    final curve = IntegrationCurve(
      points: const [],
      recommendation: SubsetRecommendation(
        keepN: keepN,
        keptIndices: keptIndices,
        predictedSnrGainPct: gainPct,
        reason: 'test',
      ),
    );
    final stored = curve.toJson()..['population'] = populationPaths;
    await masters.updateSmartFields(id,
        improvementCurveJson: jsonEncode(stored));
    for (final sub in await images.getImagesForSession(sessionId)) {
      await masters.recordFoldedFrame(masterId: id, imageId: sub.id);
    }
  }

  Future<void> pumpRail(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final c = controller();
    await waitUntilLoaded(tester);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: SubCullRail(
              subs: state().lights,
              controller: c,
              onTapSub: (_) {},
              onSetAccepted: (_, __) {},
              onBulkCull: ({hfrThreshold, qualityThreshold}) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
      'a stale curve renders an out-of-date chip, not a quantified '
      '"Keep best N" action', (tester) async {
    // GHOST.fits is not among the live subs, so the keep-set no longer maps —
    // exactly the state cullToRecommended() bails on.
    await seedMasterWithCurve(
      keepN: 2,
      keptIndices: const [0, 1],
      gainPct: 12.0,
      populationPaths: const [
        'C:/subs/s0.fits',
        'C:/subs/s1.fits',
        'C:/subs/GHOST.fits',
        'C:/subs/s3.fits',
      ],
    );
    await pumpRail(tester);

    expect(controller().cullRecommendationOffer.status, CullOfferStatus.stale);
    expect(find.textContaining('Keep best'), findsNothing);
    expect(find.text('Cull analysis out of date'), findsOneWidget);
  });

  testWidgets(
      'a curve promising no gain renders no "+0%" action even though its '
      'population matches', (tester) async {
    // The reported shape: a curve computed over a 1-sub master while more subs
    // are accepted collapses to keepN=1 / +0.0%. Here the population matches
    // the live subs, so only the gain gate can stop the label.
    await seedMasterWithCurve(
      keepN: 1,
      keptIndices: const [0],
      gainPct: 0.0,
      populationPaths: const [
        'C:/subs/s0.fits',
        'C:/subs/s1.fits',
        'C:/subs/s2.fits',
        'C:/subs/s3.fits',
      ],
    );
    await pumpRail(tester);

    expect(
      controller().cullRecommendationOffer.status,
      CullOfferStatus.alreadyOptimal,
    );
    expect(find.textContaining('Keep best'), findsNothing);
    expect(find.text('Keep-set already optimal'), findsOneWidget);

    // The chip must not swap one false claim for another. The optimizer here
    // picked 1 of 4, it just predicts no gain — saying it "would keep all 4"
    // misreports the recommendation the app is sitting on.
    final tooltip = tester.widget<Tooltip>(
      find.ancestor(
        of: find.text('Keep-set already optimal'),
        matching: find.byType(Tooltip),
      ),
    );
    expect(tooltip.message, contains('would keep 1 of 4'));
    expect(tooltip.message, contains('no SNR gain'));
    expect(tooltip.message, isNot(contains('keep all')));

    // And the action it declines to offer is genuinely refused: pressing it
    // would have rejected 3 of 4 subs for no predicted benefit.
    final result = await controller().cullToRecommended();
    expect(result.outcome, CullOutcome.alreadyOptimal);
    expect(state().acceptedCount, 4);
  });

  testWidgets('when the keep-set really does cover every sub, the chip says so',
      (tester) async {
    // The other half of alreadyOptimal: keepN >= population, so "keeps
    // everything" is the true sentence and must survive.
    await seedMasterWithCurve(
      keepN: 4,
      keptIndices: const [0, 1, 2, 3],
      gainPct: 3.0,
      populationPaths: const [
        'C:/subs/s0.fits',
        'C:/subs/s1.fits',
        'C:/subs/s2.fits',
        'C:/subs/s3.fits',
      ],
    );
    await pumpRail(tester);

    expect(
      controller().cullRecommendationOffer.status,
      CullOfferStatus.alreadyOptimal,
    );
    final tooltip = tester.widget<Tooltip>(
      find.ancestor(
        of: find.text('Keep-set already optimal'),
        matching: find.byType(Tooltip),
      ),
    );
    expect(tooltip.message, contains('keep all 4 accepted subs'));
  });

  testWidgets('a live, gainful curve still renders the quantified action',
      (tester) async {
    await seedMasterWithCurve(
      keepN: 2,
      keptIndices: const [0, 1],
      gainPct: 7.0,
      populationPaths: const [
        'C:/subs/s0.fits',
        'C:/subs/s1.fits',
        'C:/subs/s2.fits',
        'C:/subs/s3.fits',
      ],
    );
    await pumpRail(tester);

    expect(
      controller().cullRecommendationOffer.status,
      CullOfferStatus.offerable,
    );
    expect(find.text('Keep best 2 (+7%)'), findsOneWidget);
    expect(find.text('Cull analysis out of date'), findsNothing);
  });

  testWidgets(
      'rejecting a sub stales the curve and retracts the action without a '
      'new curve arriving', (tester) async {
    await seedMasterWithCurve(
      keepN: 2,
      keptIndices: const [0, 1],
      gainPct: 7.0,
      populationPaths: const [
        'C:/subs/s0.fits',
        'C:/subs/s1.fits',
        'C:/subs/s2.fits',
        'C:/subs/s3.fits',
      ],
    );
    await pumpRail(tester);
    expect(find.text('Keep best 2 (+7%)'), findsOneWidget);

    // The curve object is unchanged; only the accepted population moved.
    final curveBefore = state().improvementCurve;
    await controller().setAccepted(state().acceptedLights.last.id, false);
    await tester.pump();

    expect(identical(state().improvementCurve, curveBefore), isTrue);
    expect(find.textContaining('Keep best'), findsNothing);
    expect(find.text('Cull analysis out of date'), findsOneWidget);
  });
}
