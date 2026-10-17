// Controller tests for the Session Review screen.
//
// Exercises the UI-side orchestration against an in-memory database and a fake
// post-session seam: sub loading, the bulk-cull predicate, accept/reject
// round-trip, and that a one-shot integrate persists an integrated_masters row.

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';
import 'package:skotiq_core/skotiq_core.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/post_session_seam.dart' as seam;
// ignore: implementation_imports
import 'package:skotiq_planetarium/skotiq_planetarium.dart' show Star;

import '../../harness/mock_database.dart';

/// A [ColorCalibrationService] whose [calibrate] is scriptable: it records the
/// call and returns a configurable result, so the controller's
/// `runColorCalibration` can be exercised without real photometry / a catalog.
class _FakeColorCalibrationService extends ColorCalibrationService {
  _FakeColorCalibrationService(seam.PostSessionSeam s)
      : super(
          seam: s,
          starSearch: (_, __, {maxMagnitude}) async => const <Star>[],
        );

  final List<({String masterFits, String outputFits, int channels})> calls = [];

  /// When false, [calibrate] returns a *skipped* result (too few matches).
  bool succeed = true;

  @override
  Future<ColorCalibrationResult> calibrate({
    required String masterFits,
    required String outputFits,
    required WcsOverlay? wcs,
    required int channels,
    double? whiteRefBv,
    double matchToleranceArcsec =
        ColorCalibrationService.defaultMatchToleranceArcsec,
    int? maxStars,
    int? aperture,
  }) async {
    calls.add(
        (masterFits: masterFits, outputFits: outputFits, channels: channels));
    if (!succeed) return ColorCalibrationService.skipped(outputFits);
    return ColorCalibrationResult(
      outputPath: outputFits,
      channelScale: List<double>.filled(channels, 1.0),
      matched: 12,
      residual: 0.01,
    );
  }
}

class _FakeSeam implements PostSessionSeam {
  /// Records the args of every finishing-pass call, keyed by step name, so the
  /// finishing-action tests can assert the seam was driven on the right master.
  final Map<String, List<Map<String, dynamic>>> finishingCalls = {
    'extractBackground': [],
    'deconvolvePreview': [],
    'reduceStarsPreview': [],
  };

  @override
  Future<seam.IntegrateSessionResult> integrateSession(
      Map<String, dynamic> args) async {
    final lights = (args['lightPaths'] as List).cast<String>();
    final output = args['output'] as Map<String, dynamic>;
    return seam.IntegrateSessionResult(
      masterFitsPath: output['masterFitsPath'] as String,
      previewPath: output['previewPngPath'] as String?,
      rejectionMapPath: output['rejectionMapPath'] as String?,
      framesIntegrated: lights.length,
      framesRejected: 0,
      totalIntegrationSec: lights.length * 60.0,
      rmsResidual: 0.4,
      width: 100,
      height: 80,
      channels: 1,
      perFrameStats: [
        for (final p in lights)
          seam.PerFrameRecord(
            path: p,
            weight: 1.0,
            rmsResidualPx: 0.4,
            accepted: true,
            reason: null,
          ),
      ],
    );
  }

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

  // Smart morning report seam surface (unused by these tests)
  // These controller tests only exercise integrateSession; the remaining nine
  // PostSessionSeam members are stubbed to satisfy the interface.

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
  Future<String> extractBackground(Map<String, dynamic> args) async {
    finishingCalls['extractBackground']!.add(args);
    return args['outputFits'] as String;
  }

  @override
  Future<String> deconvolvePreview(Map<String, dynamic> args) async {
    finishingCalls['deconvolvePreview']!.add(args);
    return args['outputFits'] as String;
  }

  @override
  Future<String> reduceStarsPreview(Map<String, dynamic> args) async {
    finishingCalls['reduceStarsPreview']!.add(args);
    return args['outputFits'] as String;
  }

  @override
  Future<Map<String, dynamic>> drizzleIntegrate(
          Map<String, dynamic> args) async =>
      throw UnimplementedError();

  @override
  Future<String> combineChannels(Map<String, dynamic> args) async =>
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

  test('integrate persists a master from the accepted subs', () async {
    final c = controller();
    await waitUntilLoaded();
    await c.bulkReject(hfrThreshold: 3.5); // drop the worst sub
    final outcome = await c.integrate();
    expect(outcome, isNotNull);
    expect(outcome!.result.framesIntegrated, 2);

    final masters = await container.read(integratedMastersDaoProvider).getAll();
    expect(masters, hasLength(1));
    expect(masters.first.frameCount, 2);
    expect(state().lastOutcome, isNotNull);
    expect(state().masters, hasLength(1));
  });

  // Workbench finishing actions (post-steps on the current master)

  /// Integrate to land one persisted master in scope, then return the
  /// controller + that master's FITS path so the finishing tests run on it.
  Future<(SessionReviewController, String)> seededMaster() async {
    final c = controller();
    await waitUntilLoaded();
    await c.integrate();
    final master = state().reviewedMaster!;
    return (c, master.masterFitsPath!);
  }

  test('runBackgroundExtraction drives the seam + persists the _bgx path',
      () async {
    final (c, fits) = await seededMaster();
    final written = await c.runBackgroundExtraction();

    // The seam ran `extractBackground` on the master FITS, writing `_bgx`.
    expect(fakeSeam.finishingCalls['extractBackground'], hasLength(1));
    final call = fakeSeam.finishingCalls['extractBackground']!.single;
    expect(call['inputFits'], fits);
    expect(written, endsWith('_bgx.fits'));

    // A sibling preview PNG was rendered next to the FITS.
    expect(renderCalls, hasLength(1));
    expect(renderCalls.single.inputFits, written);
    expect(renderCalls.single.outputPng, endsWith('_bgx.png'));

    // The written path round-tripped onto the refreshed master row.
    expect(state().reviewedMaster!.backgroundExtractedPath, written);
    expect(state().extractingBackground, isFalse);
    expect(state().error, isNull);
  });

  test('runDeconvolve drives the seam + persists the _decon path', () async {
    final (c, fits) = await seededMaster();
    final written = await c.runDeconvolve();

    expect(fakeSeam.finishingCalls['deconvolvePreview'], hasLength(1));
    expect(fakeSeam.finishingCalls['deconvolvePreview']!.single['inputFits'],
        fits);
    expect(written, endsWith('_decon.fits'));
    expect(renderCalls.single.outputPng, endsWith('_decon.png'));
    expect(state().reviewedMaster!.deconvolvedPath, written);
    expect(state().deconvolving, isFalse);
  });

  test('runStarReduction drives the seam + persists the _starred path',
      () async {
    final (c, fits) = await seededMaster();
    final written = await c.runStarReduction();

    expect(fakeSeam.finishingCalls['reduceStarsPreview'], hasLength(1));
    expect(fakeSeam.finishingCalls['reduceStarsPreview']!.single['inputFits'],
        fits);
    expect(written, endsWith('_starred.fits'));
    expect(renderCalls.single.outputPng, endsWith('_starred.png'));
    expect(state().reviewedMaster!.starReducedPath, written);
    expect(state().reducingStars, isFalse);
  });

  test('a finishing action is a guarded no-op with no master in scope',
      () async {
    final c = controller();
    await waitUntilLoaded();
    // No integrate() → no reviewed master.
    expect(state().reviewedMaster, isNull);

    final written = await c.runDeconvolve();
    expect(written, isNull);
    expect(fakeSeam.finishingCalls['deconvolvePreview'], isEmpty);
    expect(renderCalls, isEmpty);
    expect(state().error, isNotNull);
  });

  test('runColorCalibration without a solved WCS surfaces an error, no write',
      () async {
    // No plate-solver in this harness, so the integrated master has no WCS.
    final fakeColor = _FakeColorCalibrationService(fakeSeam);
    container.dispose();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      postSessionSeamProvider.overrideWithValue(fakeSeam),
      colorCalibrationServiceProvider.overrideWithValue(fakeColor),
      finishingPreviewRendererProvider.overrideWithValue(
        (String inputFits, String outputPng) async {
          renderCalls.add((inputFits: inputFits, outputPng: outputPng));
        },
      ),
    ]);
    final c = controller();
    await waitUntilLoaded();
    await c.integrate();

    final written = await c.runColorCalibration();
    expect(written, isNull);
    expect(fakeColor.calls, isEmpty,
        reason: 'no WCS -> calibrate never called');
    expect(state().reviewedMaster!.colorCalibratedPath, isNull);
    expect(state().error, contains('WCS'));
    expect(state().calibrating, isFalse);
  });

  test(
      'runColorCalibration on a WCS-solved master calls the service + persists '
      'color_calibrated_path', () async {
    final fakeColor = _FakeColorCalibrationService(fakeSeam);
    container.dispose();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      postSessionSeamProvider.overrideWithValue(fakeSeam),
      colorCalibrationServiceProvider.overrideWithValue(fakeColor),
      finishingPreviewRendererProvider.overrideWithValue(
        (String inputFits, String outputPng) async {
          renderCalls.add((inputFits: inputFits, outputPng: outputPng));
        },
      ),
    ]);
    final c = controller();
    await waitUntilLoaded();
    await c.integrate();
    final master = state().reviewedMaster!;
    final fits = master.masterFitsPath!;

    // Stamp a solved WCS onto the master row, then reload so reviewedMaster
    // carries it (the controller's plate-solve step is unwired in this harness).
    await container.read(integratedMastersDaoProvider).updateWcs(
          master.id,
          crval1: 202.4696,
          crval2: 47.1952,
          crpix1: 50.0,
          crpix2: 40.0,
          cd1_1: -0.000352,
          cd1_2: 0.0000061,
          cd2_1: 0.0000061,
          cd2_2: 0.000352,
        );
    await c.refresh();
    await waitUntilLoaded();
    expect(state().reviewedMaster!.hasWcs, isTrue);

    final written = await c.runColorCalibration();

    // The service was called once against the master FITS, writing `_color`.
    expect(fakeColor.calls, hasLength(1));
    expect(fakeColor.calls.single.masterFits, fits);
    expect(written, endsWith('_color.fits'));
    expect(fakeColor.calls.single.outputFits, written);

    // A sibling preview PNG was rendered next to the calibrated FITS.
    expect(renderCalls.last.inputFits, written);
    expect(renderCalls.last.outputPng, endsWith('_color.png'));

    // The path round-tripped onto the refreshed master row.
    expect(state().reviewedMaster!.colorCalibratedPath, written);
    expect(state().calibrating, isFalse);
    expect(state().error, isNull);
  });

  test('runColorCalibration surfaces a message when the field is too sparse',
      () async {
    final fakeColor = _FakeColorCalibrationService(fakeSeam)..succeed = false;
    container.dispose();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      postSessionSeamProvider.overrideWithValue(fakeSeam),
      colorCalibrationServiceProvider.overrideWithValue(fakeColor),
      finishingPreviewRendererProvider.overrideWithValue(
        (String inputFits, String outputPng) async {
          renderCalls.add((inputFits: inputFits, outputPng: outputPng));
        },
      ),
    ]);
    final c = controller();
    await waitUntilLoaded();
    await c.integrate();
    final master = state().reviewedMaster!;
    await container.read(integratedMastersDaoProvider).updateWcs(
          master.id,
          crval1: 202.4696,
          crval2: 47.1952,
          crpix1: 50.0,
          crpix2: 40.0,
          cd1_1: -0.000352,
          cd1_2: 0.0000061,
          cd2_1: 0.0000061,
          cd2_2: 0.000352,
        );
    await c.refresh();
    await waitUntilLoaded();

    final written = await c.runColorCalibration();
    expect(written, isNull);
    expect(fakeColor.calls, hasLength(1)); // it was attempted...
    // ...but skipped, so nothing is persisted and the user is told why.
    expect(state().reviewedMaster!.colorCalibratedPath, isNull);
    expect(state().error, isNotNull);
    expect(state().calibrating, isFalse);
  });

  test('a render failure still persists the finishing FITS path (fail-soft)',
      () async {
    // Swap in a renderer that throws; the action must keep the written path.
    container.dispose();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      postSessionSeamProvider.overrideWithValue(fakeSeam),
      finishingPreviewRendererProvider.overrideWithValue(
        (String inputFits, String outputPng) async =>
            throw StateError('no native lib'),
      ),
    ]);
    final c = controller();
    await waitUntilLoaded();
    await c.integrate();

    final written = await c.runBackgroundExtraction();
    expect(written, endsWith('_bgx.fits'));
    expect(state().reviewedMaster!.backgroundExtractedPath, written);
    expect(state().error, isNull); // render failure is swallowed, not surfaced
  });
}
