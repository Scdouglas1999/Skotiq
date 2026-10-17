// Controller tests for the narrowband palette combine.
//
// Exercises that applying a palette in the workbench mixer:
//   * persists a `narrowband_composites` row (v44 table) carrying the palette,
//     the component master ids, and the output FITS path, and
//   * pushes the persisted composite onto controller state, and
//   * that `loadComposites()` reads the persisted list back.
//
// Runs against an in-memory database and a fake post-session seam whose
// `combineChannels` echoes the requested output path (the controller writes the
// row from that path).

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';
import 'package:skotiq_core/skotiq_core.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/post_session_seam.dart' as seam;

import '../../harness/mock_database.dart';

/// A fake seam whose `combineChannels` echoes the requested `output` path (so
/// the controller persists a real, deterministic composite path). Every other
/// member is stubbed — these tests only drive the narrowband path.
class _CombineSeam implements PostSessionSeam {
  @override
  Future<String> combineChannels(Map<String, dynamic> args) async =>
      args['output'] as String;

  @override
  Future<MosaicStitchResult> stitchMosaic(Map<String, dynamic> args) async =>
      throw UnimplementedError();

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

  @override
  Stream<({String phase, double fraction})> integrationProgress() =>
      const Stream.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late ProviderContainer container;
  late int sessionId;
  late int targetId;
  late int haMasterId;
  late int oiiiMasterId;

  setUp(() async {
    db = mockDatabase();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      postSessionSeamProvider.overrideWithValue(_CombineSeam()),
    ]);

    final sessions = container.read(sessionsDaoProvider);
    final images = container.read(imagesDaoProvider);
    final targets = container.read(targetsDaoProvider);
    final masters = container.read(integratedMastersDaoProvider);

    targetId = await targets.createTarget(
      TargetsCompanion.insert(name: 'NGC 7000', ra: 20.97, dec: 44.5),
    );

    sessionId = await sessions.createSession(
      ImagingSessionsCompanion.insert(startTime: DateTime.now()),
    );

    // Two single-channel narrowband subs so the session resolves to the target
    // and the mixer has Ha / OIII channels.
    Future<void> addSub(String filter) {
      return images.createImage(
        CapturedImagesCompanion.insert(
          filePath: 'C:/subs/$filter.fits',
          fileName: '$filter.fits',
          sessionId: Value(sessionId),
          targetId: Value(targetId),
          exposureDuration: 300,
          frameType: const Value('light'),
          filter: Value(filter),
          hfr: const Value(2.0),
          qualityScore: const Value(90),
          isAccepted: const Value(true),
          capturedAt: DateTime.now(),
        ),
      );
    }

    await addSub('Ha');
    await addSub('OIII');

    // Two finalized per-filter masters the narrowband mixer composes.
    haMasterId = await masters.insertMaster(
      targetId: targetId,
      name: 'NGC 7000 · Ha',
      masterFitsPath: 'C:/masters/ngc7000_ha.fits',
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
      channels: 1,
      width: 6248,
      height: 4176,
      filter: 'Ha',
    );
    oiiiMasterId = await masters.insertMaster(
      targetId: targetId,
      name: 'NGC 7000 · OIII',
      masterFitsPath: 'C:/masters/ngc7000_oiii.fits',
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
      channels: 1,
      width: 6248,
      height: 4176,
      filter: 'OIII',
    );
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

  test('mixer exposes the two narrowband channels', () async {
    controller();
    await waitUntilLoaded();
    final channels = state().narrowbandChannels;
    expect(channels.map((c) => c.label), containsAll(<String>['Ha', 'OIII']));
    expect(channels.every((c) => c.fitsPath != null), isTrue);
  });

  test('runNarrowband persists a composite row + path and surfaces it',
      () async {
    final c = controller();
    await waitUntilLoaded();

    final path = await c.runNarrowband('hoo', const []);
    expect(path, isNotNull);
    expect(path, endsWith('.fits'));

    // A `narrowband_composites` row was written with the palette, the component
    // master ids (in channel order), the output path, and the target.
    final dao = container.read(narrowbandCompositesDaoProvider);
    final rows = await dao.getAll();
    expect(rows, hasLength(1));
    final row = rows.single;
    expect(row.palette, 'hoo');
    expect(row.outputPath, path);
    // The component master ids are recorded in the mixer's channel order; both
    // narrowband masters fed the combine.
    expect(
        row.componentMasterIds, containsAll(<int>[haMasterId, oiiiMasterId]));
    expect(row.componentMasterIds, hasLength(2));
    expect(row.targetId, targetId);
    // Composite dimensions track the component masters.
    expect(row.width, 6248);
    expect(row.height, 4176);

    // The composite is surfaced on state, not discarded.
    expect(state().narrowbandComposite, isNotNull);
    expect(state().narrowbandComposite!.outputPath, path);
    expect(state().narrowbandComposites, hasLength(1));
    expect(state().error, isNull);
  });

  test('runNarrowband refuses fewer than two channels', () async {
    final c = controller();
    await waitUntilLoaded();

    final path = await c.runNarrowband(
      'hoo',
      const [],
      channels: [
        const NarrowbandChannelRef(
          masterId: 1,
          label: 'Ha',
          fitsPath: 'C:/masters/only_ha.fits',
        ),
      ],
    );
    expect(path, isNull);
    expect(state().error, contains('two finalized narrowband masters'));

    final dao = container.read(narrowbandCompositesDaoProvider);
    expect(await dao.getAll(), isEmpty);
  });

  test('loadComposites reads the persisted composites for the target',
      () async {
    final c = controller();
    await waitUntilLoaded();

    // Persist directly through the DAO (independent of a combine run).
    final dao = container.read(narrowbandCompositesDaoProvider);
    await dao.insertComposite(
      targetId: targetId,
      palette: 'sho',
      componentMasterIds: [haMasterId, oiiiMasterId],
      outputPath: 'C:/composites/ngc7000_sho.fits',
      width: 6248,
      height: 4176,
    );

    await c.loadComposites();
    final list = state().narrowbandComposites;
    expect(list, hasLength(1));
    expect(list.single.palette, 'sho');
    expect(list.single.outputPath, 'C:/composites/ngc7000_sho.fits');
    expect(list.single.componentMasterIds,
        containsAll(<int>[haMasterId, oiiiMasterId]));
  });
}
