// An integration run that throws away most of the night must say so.
//
// The reproduced defect: with 9 accepted subs, "Integrate now" produced a
// master reading "1 frame · 00:05:00 integration" and nothing else — no toast,
// no banner, no rejected count. The information existed the whole time
// (`framesRejected` on the outcome, `rejection_reason` on every dropped row);
// the manual path simply never rendered it. Losing 89% of a night's data is not
// allowed to be silent.
//
// `SessionReviewController.integrationShortfall` is the single sentence both
// surfaces render — the once-each warning toast in `SessionReviewScreen` and
// the persistent `SkotiqAlert` above "Master & overlays" in the workbench —
// so asserting it here covers what the user is actually told.

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';
import 'package:skotiq_core/skotiq_core.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/post_session_seam.dart' as seam;

import '../../harness/mock_database.dart';

const String _registrationFailure =
    'registration failed: too few stars to register: '
    'reference=0, frame=29, need >= 3';

/// A seam that reproduces the failure: the reference frame integrates, every
/// other sub is dropped for the same registration reason. Only
/// `integrateSession` is exercised; the rest of the interface is stubbed.
class _ShortfallSeam implements PostSessionSeam {
  @override
  Future<seam.IntegrateSessionResult> integrateSession(
      Map<String, dynamic> args) async {
    final lights = (args['lightPaths'] as List).cast<String>();
    final output = args['output'] as Map<String, dynamic>;
    return seam.IntegrateSessionResult(
      masterFitsPath: output['masterFitsPath'] as String,
      previewPath: output['previewPngPath'] as String?,
      rejectionMapPath: output['rejectionMapPath'] as String?,
      framesIntegrated: 1,
      framesRejected: lights.length - 1,
      totalIntegrationSec: 60.0,
      rmsResidual: 0.0,
      width: 100,
      height: 80,
      channels: 1,
      perFrameStats: [
        for (var i = 0; i < lights.length; i++)
          seam.PerFrameRecord(
            path: lights[i],
            weight: i == 0 ? 1.0 : 0.0,
            rmsResidualPx: i == 0 ? 0.0 : null,
            accepted: i == 0,
            reason: i == 0 ? null : _registrationFailure,
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

  @override
  Future<String> combineChannels(Map<String, dynamic> args) async =>
      throw UnimplementedError();

  @override
  Future<MosaicStitchResult> stitchMosaic(Map<String, dynamic> args) async =>
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

  @override
  Stream<({String phase, double fraction})> integrationProgress() =>
      const Stream.empty();
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
      postSessionSeamProvider.overrideWithValue(_ShortfallSeam()),
    ]);

    final sessions = container.read(sessionsDaoProvider);
    final images = container.read(imagesDaoProvider);

    sessionId = await sessions.createSession(
      ImagingSessionsCompanion.insert(startTime: DateTime.now()),
    );

    for (var i = 0; i < 9; i++) {
      await images.createImage(
        CapturedImagesCompanion.insert(
          filePath: 'C:/subs/audit_L_00$i.fits',
          fileName: 'audit_L_00$i.fits',
          sessionId: Value(sessionId),
          exposureDuration: 300,
          frameType: const Value('light'),
          filter: const Value('L'),
          hfr: Value(2.0 + i * 0.05),
          isAccepted: const Value(true),
          capturedAt: DateTime.now(),
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
    for (var i = 0; i < 50 && state().loading; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('a run that kept 1 of 9 subs is reported, not silent', () async {
    final c = controller();
    await waitUntilLoaded();
    expect(state().acceptedCount, 9);

    final outcome = await c.integrate();
    expect(outcome, isNotNull);
    expect(outcome!.result.framesIntegrated, 1);
    expect(outcome.result.framesRejected, 8);

    final shortfall =
        SessionReviewController.integrationShortfall(state().lastOutcome);
    expect(
      shortfall,
      isNotNull,
      reason:
          'The controller produced a master from 1 of 9 subs; the UI must say '
          'so somewhere. A null shortfall is exactly the silent failure.',
    );
    expect(shortfall, contains('Integrated 1 of 9 subs'));
    expect(shortfall, contains('8 were dropped'));
    expect(
      shortfall,
      contains('too few stars to register'),
      reason: 'The reason is what tells the user how to recover.',
    );

    // integrate() fires loadSmartData unawaited; let it settle before the
    // container is torn down so the test fails on its own assertions only.
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  test('a clean run says nothing', () async {
    // Everything integrated → no banner, no toast. The surfaces must stay quiet
    // when there is nothing to report, or the warning becomes noise.
    expect(
      SessionReviewController.integrationShortfall(
        const PostSessionIntegrationOutcome(
          masterId: 1,
          filter: 'L',
          result: seam.IntegrateSessionResult(
            masterFitsPath: '/m.fits',
            previewPath: null,
            rejectionMapPath: null,
            framesIntegrated: 9,
            framesRejected: 0,
            totalIntegrationSec: 2700,
            rmsResidual: 0.11,
            width: 100,
            height: 80,
            channels: 1,
            perFrameStats: [],
          ),
        ),
      ),
      isNull,
    );
  });

  test('no outcome at all reports nothing', () {
    expect(SessionReviewController.integrationShortfall(null), isNull);
  });

  test('the dominant reason wins, not the first one seen', () {
    // A run usually fails the same way for every sub; naming the common cause
    // is what makes the sentence actionable.
    const outcome = PostSessionIntegrationOutcome(
      masterId: 1,
      filter: 'L',
      result: seam.IntegrateSessionResult(
        masterFitsPath: '/m.fits',
        previewPath: null,
        rejectionMapPath: null,
        framesIntegrated: 2,
        framesRejected: 4,
        totalIntegrationSec: 600,
        rmsResidual: 0.3,
        width: 100,
        height: 80,
        channels: 1,
        perFrameStats: [
          seam.PerFrameRecord(
            path: '/a.fits',
            weight: 0,
            rmsResidualPx: null,
            accepted: false,
            reason: 'clouded out',
          ),
          seam.PerFrameRecord(
            path: '/b.fits',
            weight: 0,
            rmsResidualPx: null,
            accepted: false,
            reason: _registrationFailure,
          ),
          seam.PerFrameRecord(
            path: '/c.fits',
            weight: 0,
            rmsResidualPx: null,
            accepted: false,
            reason: _registrationFailure,
          ),
          seam.PerFrameRecord(
            path: '/d.fits',
            weight: 0,
            rmsResidualPx: null,
            accepted: false,
            reason: _registrationFailure,
          ),
        ],
      ),
    );

    final shortfall = SessionReviewController.integrationShortfall(outcome);
    expect(shortfall, contains('Integrated 2 of 6 subs'));
    expect(shortfall, contains('too few stars to register'));
    expect(shortfall, isNot(contains('clouded out')));
  });

  test('a single dropped sub reads in the singular', () {
    final shortfall = SessionReviewController.integrationShortfall(
      const PostSessionIntegrationOutcome(
        masterId: 1,
        filter: 'L',
        result: seam.IntegrateSessionResult(
          masterFitsPath: '/m.fits',
          previewPath: null,
          rejectionMapPath: null,
          framesIntegrated: 8,
          framesRejected: 1,
          totalIntegrationSec: 2400,
          rmsResidual: 0.11,
          width: 100,
          height: 80,
          channels: 1,
          perFrameStats: [],
        ),
      ),
    );
    expect(shortfall, 'Integrated 8 of 9 subs — 1 was dropped.');
  });
}
