// Controller tests for the Smart Morning Report data backbone added to
// [SessionReviewController]: the smart-data load (Night Doctor report), the
// view-mode toggle, the curve-linked cull guard, and the narrowband channel
// projection. Runs against an in-memory database and a fake post-session seam
// (its progress stream is empty, exercising the progress binding harmlessly).

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';
import 'package:skotiq_core/skotiq_core.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/post_session_seam.dart' as seam;

import '../../harness/mock_database.dart';

class _FakeSeam implements PostSessionSeam {
  @override
  Future<seam.IntegrateSessionResult> integrateSession(
          Map<String, dynamic> args) async =>
      throw UnimplementedError();

  @override
  Future<seam.MasterAccumulateResult> masterAccumulate(
          Map<String, dynamic> args) async =>
      throw UnimplementedError();

  @override
  Future<seam.BuildMasterFlatResult> buildMasterFlat(
          Map<String, dynamic> args) async =>
      throw UnimplementedError();

  @override
  Future<seam.SaveFitsMasterResult> saveFitsMaster(
          Map<String, dynamic> args) async =>
      throw UnimplementedError();

  @override
  Future<IntegrationCurve> analyzeNight({
    required List<Map<String, dynamic>> qualities,
    required List<double> weights,
    required List<double> exposuresS,
    double? aggressiveness,
    int? minKeep,
  }) async =>
      throw UnimplementedError();

  @override
  Future<StarPhotometryResult> detectStarsPhotometry({
    required String inputFits,
    int? maxStars,
    int? aperture,
  }) async =>
      throw UnimplementedError();

  @override
  Future<ColorCalibrationResult> colorCalibrate({
    required String inputFits,
    required String outputFits,
    required int channels,
    double? whiteRefBv,
    required List<Map<String, dynamic>> matchedStars,
  }) async =>
      throw UnimplementedError();

  @override
  Future<String> extractBackground(Map<String, dynamic> args) async =>
      throw UnimplementedError();

  @override
  Future<String> deconvolvePreview(Map<String, dynamic> args) async =>
      throw UnimplementedError();

  @override
  Future<String> reduceStarsPreview(Map<String, dynamic> args) async =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> drizzleIntegrate(
          Map<String, dynamic> args) async =>
      throw UnimplementedError();

  /// Records the combine request so the test can assert the controller wired
  /// the palette + inputs correctly; returns a synthetic composite path.
  Map<String, dynamic>? lastCombineArgs;

  @override
  Future<String> combineChannels(Map<String, dynamic> args) async {
    lastCombineArgs = args;
    return args['output'] as String;
  }

  @override
  Future<MosaicStitchResult> stitchMosaic(Map<String, dynamic> args) async =>
      throw UnimplementedError();

  @override
  Stream<({String phase, double fraction})> integrationProgress() =>
      const Stream.empty();
}

/// A Night Doctor whose analysis always throws, standing in for the real
/// failures the controller has to report: a query error, a corrupt row, a
/// detector that blows up on one night's data.
class _ThrowingNightAnalysisService extends NightAnalysisService {
  _ThrowingNightAnalysisService({
    required super.images,
    required super.science,
    required super.reports,
  });

  @override
  Future<NightReport> computeReport({
    int? sessionId,
    int? targetId,
    bool persist = true,
  }) async {
    throw StateError('night analysis failed in the detector');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late ProviderContainer container;
  late _FakeSeam fakeSeam;
  late int sessionId;

  setUp(() async {
    db = mockDatabase();
    fakeSeam = _FakeSeam();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      postSessionSeamProvider.overrideWithValue(fakeSeam),
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

  Future<void> waitUntilLoaded() async {
    for (var i = 0;
        i < 50 && (state().loading || state().loadingSmartData);
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('loadSmartData populates a night report and settles loading flag',
      () async {
    controller();
    await waitUntilLoaded();
    // A clean four-sub session yields a neutral (non-null) Night Doctor report.
    expect(state().nightReport, isNotNull);
    expect(state().nightReport!.score, inInclusiveRange(0, 100));
    expect(state().loadingSmartData, isFalse);
    // No master in scope → no improvement curve / growth / annotations.
    expect(state().improvementCurve, isNull);
    expect(state().growthPoints, isEmpty);
    expect(state().bestNight, isNull);
    expect(state().annotationLayer, isNull);
  });

  test('a failed Night Doctor run is surfaced, not left as "analysis pending"',
      () async {
    // The null report renders NightReportPanel's "Analysis pending — the Night
    // Doctor is still reviewing this session" card. Nothing is still running
    // once computeReport has thrown, so the failure has to reach the operator
    // through state.error (the screen's toast) rather than hide behind it.
    final failing = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      postSessionSeamProvider.overrideWithValue(fakeSeam),
      nightAnalysisServiceProvider.overrideWith(
        (ref) => _ThrowingNightAnalysisService(
          images: ref.watch(imagesDaoProvider),
          science: ref.watch(scienceDaoProvider),
          reports: ref.watch(nightReportsDaoProvider),
        ),
      ),
    ]);
    addTearDown(failing.dispose);

    final scope = SessionReviewScope.session(sessionId);
    failing.read(sessionReviewControllerProvider(scope).notifier);
    SessionReviewState failingState() =>
        failing.read(sessionReviewControllerProvider(scope));
    for (var i = 0;
        i < 50 && (failingState().loading || failingState().loadingSmartData);
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(failingState().nightReport, isNull);
    expect(failingState().error, isNotNull);
    expect(failingState().error, contains('Night analysis failed'));
  });

  test('default view mode is narrative and setViewMode toggles it', () async {
    final c = controller();
    await waitUntilLoaded();
    expect(state().viewMode, SessionReviewViewMode.narrative);
    c.setViewMode();
    expect(state().viewMode, SessionReviewViewMode.workbench);
    c.setViewMode(SessionReviewViewMode.narrative);
    expect(state().viewMode, SessionReviewViewMode.narrative);
  });

  test('cullToRecommended is a no-op with no improvement curve loaded',
      () async {
    final c = controller();
    await waitUntilLoaded();
    expect(state().improvementCurve, isNull);
    final result = await c.cullToRecommended();
    expect(result.outcome, CullOutcome.staleCurve);
    expect(result.rejected, 0);
    expect(state().acceptedCount, 4);
  });

  test('narrowbandChannels lists only narrowband-filtered masters', () async {
    controller();
    await waitUntilLoaded();
    // A luminance-only session exposes no narrowband channels.
    expect(state().narrowbandChannels, isEmpty);
  });

  /// Record fold rows for [masterId] over this session's subs, exactly as the
  /// post-session pipeline's `_persist` does. The reviewed-master resolution is
  /// by fold record (a master with no folds belongs to no review), so a seeded
  /// master needs them to be in scope.
  Future<void> foldSessionSubsInto(int masterId) async {
    final images = container.read(imagesDaoProvider);
    final masters = container.read(integratedMastersDaoProvider);
    for (final sub in await images.getImagesForSession(sessionId)) {
      await masters.recordFoldedFrame(masterId: masterId, imageId: sub.id);
    }
  }

  /// Insert a finalized master carrying an improvement curve whose recommendation
  /// keeps [keepN] of the population [populationPaths], so the controller picks
  /// it up as the reviewed master and loads the curve + population.
  Future<void> seedMasterWithCurve({
    required int keepN,
    required List<int> keptIndices,
    required List<String> populationPaths,
  }) async {
    final masters = container.read(integratedMastersDaoProvider);
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
        predictedSnrGainPct: 3.0,
        reason: 'test',
      ),
    );
    final stored = curve.toJson()..['population'] = populationPaths;
    await masters.updateSmartFields(id,
        improvementCurveJson: jsonEncode(stored));
    await foldSessionSubsInto(id);
  }

  test(
      'cullToRecommended maps keptIndices through the population paths and '
      'rejects exactly the non-kept subs', () async {
    // Population in capture order = the four accepted subs; keep the first two.
    await seedMasterWithCurve(
      keepN: 2,
      keptIndices: const [0, 1],
      populationPaths: const [
        'C:/subs/s0.fits',
        'C:/subs/s1.fits',
        'C:/subs/s2.fits',
        'C:/subs/s3.fits',
      ],
    );
    final c = controller();
    await waitUntilLoaded();
    expect(state().improvementCurve, isNotNull);
    expect(state().improvementCurvePopulation, hasLength(4));

    final result = await c.cullToRecommended();
    expect(result.outcome, CullOutcome.culled);
    expect(result.rejected, 2);

    // s0/s1 stay accepted; s2/s3 (outside keptIndices) are now rejected.
    final accepted = state().acceptedLights.map((s) => s.filePath).toSet();
    expect(accepted, {'C:/subs/s0.fits', 'C:/subs/s1.fits'});

    // The cull fires an unawaited loadSmartData() to re-derive the backbone;
    // let it settle so it doesn't run after tearDown disposes the container.
    await waitUntilLoaded();
  });

  test(
      'cullToRecommended is a no-op when the curve population no longer matches '
      'the live accepted subs (stale curve never rejects arbitrary subs)',
      () async {
    // The population references a sub path that is NOT among the live subs, so
    // the index space no longer maps — the cull must bail without rejecting.
    await seedMasterWithCurve(
      keepN: 2,
      keptIndices: const [0, 1],
      populationPaths: const [
        'C:/subs/s0.fits',
        'C:/subs/s1.fits',
        'C:/subs/GHOST.fits',
        'C:/subs/s3.fits',
      ],
    );
    final c = controller();
    await waitUntilLoaded();

    final result = await c.cullToRecommended();
    expect(result.outcome, CullOutcome.staleCurve);
    expect(result.rejected, 0);
    expect(state().acceptedCount, 4);
  });

  test('cullToRecommended is a no-op when the curve carried no population',
      () async {
    final masters = container.read(integratedMastersDaoProvider);
    final id = await masters.insertMaster(
      targetId: null,
      name: 'No-pop master',
      masterFitsPath: '/tmp/m2.fits',
      previewPngPath: null,
      sidecarPath: null,
      rejectionMapPath: null,
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
      channels: 1,
      width: 100,
      height: 100,
      frameCount: 4,
      totalIntegrationSeconds: 240,
      filter: 'L',
      settingsJson: '{}',
      statsJson: '{}',
    );
    // Legacy-style curve JSON with NO population sibling key.
    const curve = IntegrationCurve(
      points: [],
      recommendation: SubsetRecommendation(
        keepN: 2,
        keptIndices: [0, 1],
        predictedSnrGainPct: 3.0,
        reason: 'test',
      ),
    );
    await masters.updateSmartFields(id,
        improvementCurveJson: jsonEncode(curve.toJson()));
    await foldSessionSubsInto(id);

    final c = controller();
    await waitUntilLoaded();
    expect(state().improvementCurve, isNotNull);
    expect(state().improvementCurvePopulation, isEmpty);

    final result = await c.cullToRecommended();
    expect(result.outcome, CullOutcome.staleCurve);
    expect(result.rejected, 0);
    expect(state().acceptedCount, 4);
  });

  test('runNarrowband errors when fewer than two channels are available',
      () async {
    final c = controller();
    await waitUntilLoaded();
    final out = await c.runNarrowband('sho', const []);
    expect(out, isNull);
    expect(state().error, isNotNull);
    expect(fakeSeam.lastCombineArgs, isNull);
  });

  group('header title identifies the session, not "the night"', () {
    /// Two sequences on the same night would otherwise both render a "Night of
    /// <date>" header over mutually exclusive sub sets, with no session name on
    /// screen — a title claiming an aggregation the screen does not do.
    Future<int> namedSessionAt(String name, DateTime start) async {
      final sessions = container.read(sessionsDaoProvider);
      final images = container.read(imagesDaoProvider);
      final id = await sessions.createSession(
        ImagingSessionsCompanion.insert(
          name: Value(name),
          startTime: start,
        ),
      );
      await images.createImage(
        CapturedImagesCompanion.insert(
          filePath: '/subs/$name.fits',
          fileName: '$name.fits',
          sessionId: Value(id),
          exposureDuration: 60,
          frameType: const Value('light'),
          capturedAt: start,
        ),
      );
      return id;
    }

    Future<String> titleFor(int id) async {
      final scope = SessionReviewScope.session(id);
      container.read(sessionReviewControllerProvider(scope).notifier);
      for (var i = 0; i < 50; i++) {
        final s = container.read(sessionReviewControllerProvider(scope));
        if (!s.loading && !s.loadingSmartData) return s.title;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return container.read(sessionReviewControllerProvider(scope)).title;
    }

    test('two sessions on one night get distinct, session-named titles',
        () async {
      final first = await namedSessionAt(
        'MF PROBE B',
        DateTime(2026, 7, 25, 17, 4),
      );
      final second = await namedSessionAt(
        'MF PROBE C',
        DateTime(2026, 7, 25, 17, 6),
      );

      final firstTitle = await titleFor(first);
      final secondTitle = await titleFor(second);

      expect(firstTitle, 'MF PROBE B · 2026-07-25 17:04');
      expect(secondTitle, 'MF PROBE C · 2026-07-25 17:06');
      expect(firstTitle, isNot(secondTitle));
      expect(firstTitle, isNot(contains('Night of')));
    });

    test('an unnamed session still gets a dated, non-"night" title', () async {
      final sessions = container.read(sessionsDaoProvider);
      final id = await sessions.createSession(
        ImagingSessionsCompanion.insert(
          startTime: DateTime(2026, 7, 28, 14, 27),
        ),
      );
      final title = await titleFor(id);
      expect(title, 'Session · 2026-07-28 14:27');
      expect(title, isNot(contains('Night of')));
    });
  });

  group('reviewedMaster is scoped to the session under review', () {
    /// Insert a finalized master that folded [imageIds] (empty = another
    /// session's subs), with a null target_id like the real pipeline writes for
    /// an un-catalogued session.
    Future<int> insertMasterFolding(
      String name,
      List<int> imageIds,
    ) async {
      final masters = container.read(integratedMastersDaoProvider);
      final id = await masters.insertMaster(
        targetId: null,
        name: name,
        masterFitsPath: '/tmp/$name.fits',
        previewPngPath: '/tmp/$name.png',
        status: IntegratedMasterStatus.finalized,
        accumulationMode: AccumulationMode.batch,
        frameCount: imageIds.length,
        totalIntegrationSeconds: imageIds.length * 60.0,
      );
      for (final imageId in imageIds) {
        await masters.recordFoldedFrame(masterId: id, imageId: imageId);
      }
      return id;
    }

    test('another night\'s master is NOT presented as this session\'s',
        () async {
      // A different session, integrated into its own master. Nothing in THIS
      // session has been integrated.
      final sessions = container.read(sessionsDaoProvider);
      final images = container.read(imagesDaoProvider);
      final otherSessionId = await sessions.createSession(
        ImagingSessionsCompanion.insert(
          startTime: DateTime.now().subtract(const Duration(days: 3)),
        ),
      );
      final otherImageId = await images.createImage(
        CapturedImagesCompanion.insert(
          filePath: 'C:/other/o0.fits',
          fileName: 'o0.fits',
          sessionId: Value(otherSessionId),
          exposureDuration: 60,
          frameType: const Value('light'),
          capturedAt: DateTime.now().subtract(const Duration(days: 3)),
        ),
      );
      await insertMasterFolding('other_night', [otherImageId]);

      controller();
      await waitUntilLoaded();

      // The library still lists it (target-less masters are library-wide), but
      // it must not be the master this session claims as its result — the hero
      // image and every finishing action read reviewedMaster.
      expect(state().masters, isNotEmpty);
      expect(state().reviewedMaster, isNull);
    });

    test('this session\'s own master IS the reviewed master', () async {
      final images = container.read(imagesDaoProvider);
      final subs = await images.getImagesForSession(sessionId);
      final mineId =
          await insertMasterFolding('mine', [subs.first.id, subs[1].id]);
      // A newer, unrelated master exists too — recency must not win.
      await insertMasterFolding('newer_other', const []);

      controller();
      await waitUntilLoaded();

      expect(state().reviewedMaster, isNotNull);
      expect(state().reviewedMaster!.id, mineId);
    });
  });
}
