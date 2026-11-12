// Controller tests for the Session Review screen.
//
// Exercises the UI-side orchestration against an in-memory database and a fake
// post-session seam: sub loading, the bulk-cull predicate, the accept/reject
// round-trip, and deconvolution of the reviewed master.

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';
import 'package:skotiq_core/skotiq_core.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/post_session_seam.dart' as seam;

import '../../harness/mock_database.dart';
import '../../harness/temporary_data_directory.dart';

class _FakeSeam implements PostSessionSeam {
  /// The args of every deconvolution call, so the tests can assert the seam
  /// was driven on the right master.
  final List<Map<String, dynamic>> deconvolveCalls = [];

  @override
  Future<seam.IntegrateSessionResult> integrateSession(
          Map<String, dynamic> args) async =>
      throw UnimplementedError();

  @override
  Future<seam.MasterAccumulateResult> masterAccumulate(
          Map<String, dynamic> args) async =>
      seam.MasterAccumulateResult(
        sidecarPath: args['sidecarPath'] as String? ?? '',
        masterPath: null,
        previewPath: null,
        frameCount: 0,
        totalIntegrationSec: 0,
        width: 100,
        height: 80,
        channels: 1,
        framesAdded: 0,
        rejected: 0,
        frameWeights: const [],
      );

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
  Future<String> deconvolvePreview(Map<String, dynamic> args) async {
    deconvolveCalls.add(args);
    return args['outputFits'] as String;
  }

  @override
  Future<String> reduceStarsPreview(Map<String, dynamic> args) async =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> drizzleIntegrate(
          Map<String, dynamic> args) async =>
      throw UnimplementedError();

  @override
  Future<MosaicStitchResult> stitchMosaic(Map<String, dynamic> args) async =>
      throw UnimplementedError();

  @override
  Stream<({String phase, double fraction})> integrationProgress() =>
      const Stream.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late ProviderContainer container;
  late int sessionId;
  late _FakeSeam fakeSeam;
  // Records every (inputFits, outputPng) the finishing-preview renderer was
  // asked to produce, so the action tests can prove a sibling preview is
  // rendered without touching the native bridge.
  late List<({String inputFits, String outputPng})> renderCalls;

  final dataDir = useTemporaryDataDirectory();

  setUp(() async {
    db = mockDatabase();
    fakeSeam = _FakeSeam();
    renderCalls = [];
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      postSessionSeamProvider.overrideWithValue(fakeSeam),
      // Fake renderer: record the request and "succeed" without native code.
      finishingPreviewRendererProvider.overrideWithValue(
        (String inputFits, String outputPng) async {
          renderCalls.add((inputFits: inputFits, outputPng: outputPng));
        },
      ),
    ]);

    final sessions = container.read(sessionsDaoProvider);
    final images = container.read(imagesDaoProvider);

    sessionId = await sessions.createSession(
      ImagingSessionsCompanion.insert(startTime: DateTime.now()),
    );

    Future<void> addSub(String name,
        {required double hfr, bool accepted = true}) {
      return images.createImage(
        CapturedImagesCompanion.insert(
          filePath: 'C:/subs/$name.fits',
          fileName: '$name.fits',
          sessionId: Value(sessionId),
          exposureDuration: 60,
          frameType: const Value('light'),
          filter: const Value('L'),
          hfr: Value(hfr),
          qualityScore: Value(100 - hfr * 10),
          isAccepted: Value(accepted),
          capturedAt: DateTime.now(),
        ),
      );
    }

    await addSub('a', hfr: 2.0);
    await addSub('b', hfr: 2.4);
    await addSub('c', hfr: 5.0); // worst — culled by HFR>3.5
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
    for (var i = 0; i < 50 && state().loading; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('loads the session subs and counts acceptance', () async {
    controller();
    await waitUntilLoaded();
    expect(state().lights.length, 3);
    expect(state().acceptedCount, 3);
  });

  test('bulkReject culls subs above the HFR threshold', () async {
    final c = controller();
    await waitUntilLoaded();
    final rejected = await c.bulkReject(hfrThreshold: 3.5);
    expect(rejected, 1);
    expect(state().acceptedCount, 2);
    expect(state().rejectedCount, 1);
  });

  test('setAccepted toggles a single sub', () async {
    final c = controller();
    await waitUntilLoaded();
    final id = state().lights.first.id;
    await c.setAccepted(id, false);
    expect(state().acceptedCount, 2);
    await c.setAccepted(id, true);
    expect(state().acceptedCount, 3);
  });

  Future<String> accumulatingSidecar() async {
    final c = controller();
    await waitUntilLoaded();
    await c.createAccumulatingMaster(filter: 'L');
    final masters = await container.read(integratedMastersDaoProvider).getAll();
    return masters
        .singleWhere((m) => m.status == IntegratedMasterStatus.accumulating)
        .sidecarPath!;
  }

  test(
      'with no image folder chosen, an accumulating master goes where '
      'unattended builds go, not to wherever the app was started from',
      () async {
    final sidecar = await accumulatingSidecar();
    expect(sidecar, startsWith('${dataDir().path}/documents/Skotiq/Masters'));
  });

  test('with an image folder chosen, an accumulating master goes under it',
      () async {
    await container
        .read(settingsDaoProvider)
        .write(AppSettingDefs.imageOutputPath, '/data/astro');
    expect(await accumulatingSidecar(), startsWith('/data/astro/masters'));
  });

  /// A master over this night's subs as the Darkroom's build registers it: a
  /// row with no target and a fold record per sub. Returns the controller,
  /// loaded with that master under review, and the master's FITS path.
  Future<(SessionReviewController, String)> seededMaster() async {
    const fits = '/masters/NGC_891/L_master_linear.fits';
    final masters = container.read(integratedMastersDaoProvider);
    final id = await masters.insertMaster(
      name: 'NGC 891 L',
      masterFitsPath: fits,
      previewPngPath: '/masters/NGC_891/L_master_linear.png',
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
      frameCount: 3,
      filter: 'L',
    );
    for (final sub in await container
        .read(imagesDaoProvider)
        .getImagesForSession(sessionId)) {
      await masters.recordFoldedFrame(masterId: id, imageId: sub.id);
    }
    final c = controller();
    await waitUntilLoaded();
    expect(state().reviewedMaster?.id, id);
    return (c, fits);
  }

  test('runDeconvolve drives the seam + persists the _decon path', () async {
    final (c, fits) = await seededMaster();
    final written = await c.runDeconvolve();

    expect(fakeSeam.deconvolveCalls, hasLength(1));
    expect(fakeSeam.deconvolveCalls.single['inputFits'], fits);
    expect(written, '/masters/NGC_891/L_master_linear_decon.fits');
    expect(renderCalls.single.inputFits, written);
    expect(renderCalls.single.outputPng,
        '/masters/NGC_891/L_master_linear_decon.png');
    expect(state().reviewedMaster!.deconvolvedPath, written);
    expect(state().deconvolving, isFalse);
    expect(state().error, isNull);
  });

  test('deconvolution is a guarded no-op with no master in scope', () async {
    final c = controller();
    await waitUntilLoaded();
    expect(state().reviewedMaster, isNull);

    final written = await c.runDeconvolve();
    expect(written, isNull);
    expect(fakeSeam.deconvolveCalls, isEmpty);
    expect(renderCalls, isEmpty);
    expect(state().error, isNotNull);
  });

  test('a render failure still persists the deconvolved FITS path', () async {
    container.dispose();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      postSessionSeamProvider.overrideWithValue(fakeSeam),
      finishingPreviewRendererProvider.overrideWithValue(
        (String inputFits, String outputPng) async =>
            throw StateError('no native lib'),
      ),
    ]);
    final (c, _) = await seededMaster();

    final written = await c.runDeconvolve();
    expect(written, endsWith('_decon.fits'));
    expect(state().reviewedMaster!.deconvolvedPath, written);
    expect(state().error, isNull);
  });
}
