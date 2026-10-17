// Controller tests for the Mosaic project review screen.
//
// Exercises the UI-side orchestration against an in-memory database with the
// REAL v45 DAOs, and a SPY [MosaicProjectService] (a subclass recording calls
// and returning canned outcomes) so the controller's two durable actions are
// pinned without the native stitcher / integration pipeline:
//
//   * load() reads the project + panels + per-panel masters + stitched output.
//   * integratePanels() drives the service then reloads.
//   * stitchProject() is GATED on >= 2 panels with masters — with fewer than two
//     it records an error WITHOUT touching the service; with two it drives it.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/mosaic/mosaic_project_controller.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// A [MosaicProjectService] spy: it never calls the real integration / stitch
/// path, only records the calls and (for integrate) links a canned per-panel
/// master onto each panel so the controller's reload reflects "integrated".
class _SpyService extends MosaicProjectService {
  _SpyService({
    required super.db,
    required this.panelsDao,
    required this.mastersDao,
    required this.projectsDao,
    required super.targetsDao,
    required super.imagesDao,
    required super.integrationService,
    required super.seam,
  }) : super(
            projectsDao: projectsDao,
            panelsDao: panelsDao,
            mastersDao: mastersDao);

  final MosaicPanelsDao panelsDao;
  final IntegratedMastersDao mastersDao;
  final MosaicProjectsDao projectsDao;

  int integrateCalls = 0;
  int stitchCalls = 0;
  int startCaptureCalls = 0;

  /// How many panels integrate should link a master onto (mirrors a partial
  /// capture: only the first [panelsToLink] panels produced subs).
  int panelsToLink = 0;

  @override
  Future<List<MosaicPanelIntegrationOutcome>> integratePanels(
    int projectId, {
    required IntegrationSettings settings,
    required String Function(MosaicProjectPanel panel) outputFitsPathBuilder,
  }) async {
    integrateCalls++;
    final panels = await panelsDao.getForProject(projectId);
    final outcomes = <MosaicPanelIntegrationOutcome>[];
    for (final panel in panels.take(panelsToLink)) {
      final masterId = await mastersDao.insertMaster(
        name: 'Panel ${panel.panelIndex} master',
        masterFitsPath: outputFitsPathBuilder(panel),
        previewPngPath: '${outputFitsPathBuilder(panel)}.png',
        status: IntegratedMasterStatus.finalized,
        accumulationMode: AccumulationMode.batch,
        width: 100,
        height: 80,
        frameCount: 5,
      );
      await panelsDao.setMaster(panel.id!, masterId);
      await panelsDao.setCaptured(panel.id!, 5);
      outcomes.add(MosaicPanelIntegrationOutcome(
        panelId: panel.id!,
        panelIndex: panel.panelIndex,
        integratedMasterId: masterId,
        status: MosaicPanelStatus.integrated,
        subCount: 5,
      ));
    }
    return outcomes;
  }

  @override
  Future<MosaicCaptureRequest> startCapture(
    int projectId, {
    required MosaicCaptureLauncher launcher,
  }) async {
    startCaptureCalls++;
    final panels = await panelsDao.getForProject(projectId);
    final project = await projectsDao.getById(projectId);
    final request = MosaicCaptureRequest(
      project: project!,
      panels: panels,
      panelTargetIds: {
        for (final p in panels)
          if (p.targetId != null) p.panelIndex: p.targetId!,
      },
    );
    await launcher(request);
    await projectsDao.updateStatus(projectId, MosaicProjectStatus.capturing);
    return request;
  }

  @override
  Future<MosaicStitchOutcome> stitchProject(
    int projectId, {
    required String outputDirectory,
    Map<String, dynamic>? stitchConfig,
    Future<bool> Function(String fitsPath)? fitsHasWcs,
  }) async {
    stitchCalls++;
    final masterId = await mastersDao.insertMaster(
      name: 'Mosaic master',
      masterFitsPath: '$outputDirectory/mosaic.fits',
      previewPngPath: '$outputDirectory/mosaic.png',
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
      width: 200,
      height: 80,
      frameCount: panelsToLink,
    );
    await projectsDao.setOutputMaster(projectId, masterId);
    return MosaicStitchOutcome(
      outputMasterId: masterId,
      panelCount: panelsToLink,
      result: MosaicStitchResult(
        outputPath: '$outputDirectory/mosaic.fits',
        previewPath: '$outputDirectory/mosaic.png',
        outWidth: 200,
        outHeight: 80,
        overlapPairs: panelsToLink - 1,
        meanPanelGain: 1.0,
      ),
    );
  }
}

void main() {
  late SkotiqDatabase db;
  late MosaicProjectsDao projectsDao;
  late MosaicPanelsDao panelsDao;
  late IntegratedMastersDao mastersDao;
  late _SpyService spy;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    projectsDao = MosaicProjectsDao(db);
    panelsDao = MosaicPanelsDao(db);
    mastersDao = IntegratedMastersDao(db);
    // The spy never reaches imagesDao / integration / seam, but the super ctor
    // requires them — hand it the real DAO-backed instances.
    spy = _SpyService(
      db: db,
      panelsDao: panelsDao,
      mastersDao: mastersDao,
      projectsDao: projectsDao,
      targetsDao: TargetsDao(db),
      imagesDao: ImagesDao(db),
      integrationService: PostSessionIntegrationService(
        mastersDao: mastersDao,
        calibrationLibrary: CalibrationLibraryService(
          db: db,
          flatLibraryDao: FlatLibraryDao(db),
          tagsDao: CalibrationTagsDao(db),
        ),
        seam: _noopSeam(),
      ),
      seam: _noopSeam(),
    );
  });

  tearDown(() async {
    await db.close();
  });

  /// Seed a project with [panelCount] pending panels, returning the project id.
  Future<int> seedProject({int rows = 1, int cols = 3}) async {
    final projectId = await projectsDao.create(
      name: 'Veil $cols x $rows',
      rows: rows,
      cols: cols,
    );
    for (var i = 0; i < rows * cols; i++) {
      await panelsDao.upsert(
        projectId: projectId,
        panelIndex: i,
        centerRa: 20.0 + i * 0.01,
        centerDec: 30.0,
      );
    }
    return projectId;
  }

  MosaicProjectController makeController(
    int projectId, {
    MosaicCaptureLauncher? captureLauncher,
    CollaborativeMosaicService? collaborativeService,
    bool hubConfigured = true,
    Duration hubTimeout = MosaicProjectController.defaultHubTimeout,
  }) {
    return MosaicProjectController(
      hubTimeout: hubTimeout,
      projectId: projectId,
      projectsDao: projectsDao,
      panelsDao: panelsDao,
      mastersDao: mastersDao,
      service: spy,
      collaborativeService: collaborativeService,
      hubConfigured: hubConfigured,
      captureLauncher: captureLauncher,
      panelOutputPathBuilder: (panel) =>
          '/tmp/mosaic/${panel.projectId}/panel_${panel.panelIndex}.fits',
      stitchOutputDirectory: (project) => '/tmp/mosaic/${project.id}',
    );
  }

  /// Pump until the controller's load future has resolved.
  Future<void> waitForLoad(MosaicProjectController c) async {
    for (var i = 0; i < 20 && c.state.isLoading; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('load resolves project + panels from the DAOs', () async {
    final projectId = await seedProject(cols: 3);
    final c = makeController(projectId);
    await waitForLoad(c);

    expect(c.state.project, isNotNull);
    expect(c.state.project!.cols, 3);
    expect(c.state.panels, hasLength(3));
    expect(c.state.panelsWithMasters, 0);
    expect(c.state.canStitch, isFalse);
    expect(c.state.isComplete, isFalse);
    c.dispose();
  });

  test('integratePanels calls the service and reloads with linked masters',
      () async {
    final projectId = await seedProject(cols: 3);
    spy.panelsToLink = 3;
    final c = makeController(projectId);
    await waitForLoad(c);

    await c.integratePanels();

    expect(spy.integrateCalls, 1);
    expect(c.state.panelsWithMasters, 3);
    // Each integrated panel resolved its per-panel master for a thumbnail.
    expect(c.state.panelMasters, hasLength(3));
    expect(c.state.canStitch, isTrue);
    expect(c.state.isIntegrating, isFalse);
    expect(c.state.error, isNull);
    c.dispose();
  });

  test('stitchProject is GATED on < 2 masters — service is not called',
      () async {
    final projectId = await seedProject(cols: 3);
    // Link only ONE panel: below the >= 2 stitch threshold.
    spy.panelsToLink = 1;
    final c = makeController(projectId);
    await waitForLoad(c);
    await c.integratePanels();
    expect(c.state.panelsWithMasters, 1);
    expect(c.state.canStitch, isFalse);

    await c.stitchProject();

    // The doomed FFI round-trip was never made; a clear error is surfaced.
    expect(spy.stitchCalls, 0);
    expect(c.state.error, isNotNull);
    expect(c.state.error, contains('at least 2'));
    expect(c.state.isComplete, isFalse);
    c.dispose();
  });

  test('stitchProject calls the service once >= 2 panels have masters',
      () async {
    final projectId = await seedProject(cols: 3);
    spy.panelsToLink = 2;
    final c = makeController(projectId);
    await waitForLoad(c);
    await c.integratePanels();
    expect(c.state.canStitch, isTrue);

    await c.stitchProject();

    expect(spy.stitchCalls, 1);
    expect(c.state.isComplete, isTrue);
    expect(c.state.stitchedMaster, isNotNull);
    expect(c.state.project!.status, MosaicProjectStatus.complete);
    expect(c.state.isStitching, isFalse);
    expect(c.state.error, isNull);
    c.dispose();
  });

  test('startCapture drives the service + launcher and reloads as capturing',
      () async {
    final projectId = await seedProject(cols: 3);
    final c = makeController(
      projectId,
      captureLauncher: (req) async {},
    );
    await waitForLoad(c);
    expect(c.canStartCapture, isTrue);

    await c.startCapture();

    expect(spy.startCaptureCalls, 1);
    expect(c.state.isStartingCapture, isFalse);
    expect(c.state.error, isNull);
    expect(c.state.project!.status, MosaicProjectStatus.capturing);
    c.dispose();
  });

  test('startCapture is unavailable (clear error) without a launcher',
      () async {
    final projectId = await seedProject(cols: 3);
    final c = makeController(projectId); // no launcher injected
    await waitForLoad(c);
    expect(c.canStartCapture, isFalse);

    await c.startCapture();

    // The service was NOT called; a clear error explains capture is unavailable.
    expect(spy.startCaptureCalls, 0);
    expect(c.state.error, isNotNull);
    expect(c.state.error, contains('unavailable'));
    c.dispose();
  });

  group('collaborative mosaics (WS2)', () {
    late _FakeCollab collab;

    MosaicProjectController collabController(int projectId) =>
        makeController(projectId, collaborativeService: collab);

    setUp(() {
      collab = _FakeCollab(
        projectsDao: projectsDao,
        panelsDao: panelsDao,
        mastersDao: mastersDao,
        projectService: spy,
      );
    });

    test('publishToHub drives the service, reloads, and surfaces published',
        () async {
      final projectId = await seedProject(cols: 2);
      final c = collabController(projectId);
      await waitForLoad(c);

      await c.publishToHub();

      expect(collab.publishCalls, 1);
      expect(c.state.isPublishing, isFalse);
      expect(c.state.isPublished, isTrue);
      expect(c.state.hubMosaicId, 'mos-1');
      expect(c.state.error, isNull);
      c.dispose();
    });

    test('claimPanel sets the claiming flag, claims, and reloads', () async {
      final projectId = await seedProject(cols: 2);
      await projectsDao.setHubMosaic(projectId, 'mos-1', 'participant');
      final c = collabController(projectId);
      await waitForLoad(c);

      await c.claimPanel(0);

      expect(collab.claimedIndices, [0]);
      expect(c.state.isClaiming, isFalse);
      final panel = c.state.panels.firstWhere((p) => p.panelIndex == 0);
      expect(panel.isClaimed, isTrue);
      expect(c.state.error, isNull);
      c.dispose();
    });

    test('uploadPanelMaster drives the service and reloads', () async {
      final projectId = await seedProject(cols: 2);
      await projectsDao.setHubMosaic(projectId, 'mos-1', 'owner');
      spy.panelsToLink = 2;
      final c = collabController(projectId);
      await waitForLoad(c);
      await c.integratePanels();

      await c.uploadPanelMaster(
        0,
        license: ContributionLicense.ccBy,
        attributionConsent: true,
      );

      expect(collab.uploadedIndices, [0]);
      expect(c.state.isUploading, isFalse);
      expect(c.state.panelsUploaded, 1);
      expect(c.state.error, isNull);
      c.dispose();
    });

    test('assembleFromHub drives the service and reloads', () async {
      final projectId = await seedProject(cols: 2);
      await projectsDao.setHubMosaic(projectId, 'mos-1', 'owner');
      final c = collabController(projectId);
      await waitForLoad(c);

      await c.assembleFromHub();

      expect(collab.assembleCalls, 1);
      expect(c.state.isAssembling, isFalse);
      expect(c.state.collabStatus, 'complete');
      expect(c.state.error, isNull);
      c.dispose();
    });

    test('joinAsParticipant links the project as a participant + reloads',
        () async {
      final projectId = await seedProject(cols: 2);
      final c = collabController(projectId);
      await waitForLoad(c);

      await c.joinAsParticipant('mos-9');

      expect(collab.joinedHubIds, ['mos-9']);
      expect(c.state.isJoining, isFalse);
      expect(c.state.isPublished, isTrue);
      expect(c.state.hubMosaicId, 'mos-9');
      expect(c.state.project?.collabRole, 'participant');
      expect(c.state.error, isNull);
      c.dispose();
    });

    test('discoverMosaics returns the hub listing', () async {
      final projectId = await seedProject(cols: 2);
      final c = collabController(projectId);
      await waitForLoad(c);

      final mosaics = await c.discoverMosaics();

      expect(collab.listCalls, 1);
      expect(mosaics, hasLength(1));
      expect(mosaics.first.mosaicId, 'mos-9');
      expect(c.state.error, isNull);
      c.dispose();
    });

    test('refreshStatus refreshes the collab lifecycle + reloads', () async {
      final projectId = await seedProject(cols: 2);
      await projectsDao.setHubMosaic(projectId, 'mos-1', 'participant');
      final c = collabController(projectId);
      await waitForLoad(c);

      await c.refreshStatus();

      expect(collab.refreshCalls, 1);
      expect(c.state.isRefreshing, isFalse);
      expect(c.state.collabStatus, 'assembling');
      expect(c.state.error, isNull);
      c.dispose();
    });

    test('downloadOutput pulls the finished mosaic + surfaces the hero',
        () async {
      final projectId = await seedProject(cols: 2);
      await projectsDao.setHubMosaic(projectId, 'mos-1', 'participant');
      final c = collabController(projectId);
      await waitForLoad(c);

      await c.downloadOutput();

      expect(collab.downloadCalls, 1);
      expect(c.state.isDownloading, isFalse);
      expect(c.state.collabStatus, 'complete');
      expect(c.state.stitchedMaster, isNotNull);
      expect(c.state.error, isNull);
      c.dispose();
    });

    test('a collaborative action surfaces a thrown service error', () async {
      final projectId = await seedProject(cols: 2);
      collab.throwOnPublish = true;
      final c = collabController(projectId);
      await waitForLoad(c);

      await c.publishToHub();

      expect(c.state.isPublishing, isFalse);
      expect(c.state.error, contains('Publish failed'));
      c.dispose();
    });

    test('a hub that never answers still releases the action button', () async {
      // The local project read states a bound and surfaces an actionable
      // message when it trips. Every hub action — the calls that actually
      // cross a network — stated none, so a hub that accepted the connection
      // and never replied left the screen spinning with no way back except
      // leaving it.
      final projectId = await seedProject(cols: 2);
      collab.hangOnPublish = const Duration(seconds: 30);
      final c = makeController(
        projectId,
        collaborativeService: collab,
        hubTimeout: const Duration(milliseconds: 40),
      );
      await waitForLoad(c);

      await c.publishToHub();

      expect(c.state.isPublishing, isFalse);
      expect(c.state.error, contains('timed out'));
      expect(c.state.error, contains('hub'));
      c.dispose();
    });

    test('forceReleasePanel drives the service, reloads, and clears busy',
        () async {
      final projectId = await seedProject(cols: 2);
      await projectsDao.setHubMosaic(projectId, 'mos-1', 'owner');
      final c = collabController(projectId);
      await waitForLoad(c);
      await c.claimPanel(0);

      await c.forceReleasePanel(0);

      expect(collab.forceReleasedIndices, [0]);
      expect(c.state.isClaiming, isFalse);
      final panel = c.state.panels.firstWhere((p) => p.panelIndex == 0);
      expect(panel.status, MosaicPanelStatus.pending);
      expect(c.state.error, isNull);
      c.dispose();
    });

    test('releasePanel hands this rig\'s own claim back and reloads', () async {
      final projectId = await seedProject(cols: 2);
      await projectsDao.setHubMosaic(projectId, 'mos-1', 'participant');
      final c = collabController(projectId);
      await waitForLoad(c);
      await c.claimPanel(0);
      expect(c.state.panels.first.isClaimed, isTrue);

      await c.releasePanel(0);

      expect(collab.releasedIndices, [0]);
      expect(c.state.isClaiming, isFalse);
      // A contributor can undo their own claim without the owner evicting it.
      expect(c.state.panels.firstWhere((p) => p.panelIndex == 0).isClaimed,
          isFalse);
      expect(c.state.error, isNull);
      c.dispose();
    });

    test('a participant bulk claim is bounded, leaving panels for the owner',
        () async {
      final projectId = await seedProject(cols: 6);
      await projectsDao.setHubMosaic(projectId, 'mos-1', 'participant');
      final c = collabController(projectId);
      await waitForLoad(c);

      await c.claimPendingBatch();

      // Never the whole grid: the owner is not locked out of her own mosaic.
      expect(collab.claimedIndices, [0, 1, 2]);
      expect(c.state.unclaimedPanels, hasLength(3));
      c.dispose();
    });

    test('the owner bulk claim still takes every pending panel', () async {
      final projectId = await seedProject(cols: 6);
      await projectsDao.setHubMosaic(projectId, 'mos-1', 'owner');
      final c = collabController(projectId);
      await waitForLoad(c);

      await c.claimPendingBatch();

      expect(collab.claimedIndices, [0, 1, 2, 3, 4, 5]);
      expect(c.state.unclaimedPanels, isEmpty);
      c.dispose();
    });

    test('a granted claim surfaces the hub\'s own expiry', () async {
      final projectId = await seedProject(cols: 2);
      await projectsDao.setHubMosaic(projectId, 'mos-1', 'participant');
      final c = collabController(projectId);
      await waitForLoad(c);
      expect(c.state.claimExpiresAt, isNull);

      await c.claimPanel(0);
      expect(c.state.claimExpiresAt, isNotNull);

      // Giving the panel back drops the deadline rather than leaving it stale.
      await c.releasePanel(0);
      expect(c.state.claimExpiresAt, isNull);
      c.dispose();
    });

    test('forceReleasePanel surfaces a thrown auth error (non-owner)',
        () async {
      final projectId = await seedProject(cols: 2);
      await projectsDao.setHubMosaic(projectId, 'mos-1', 'participant');
      collab.throwOnForceRelease = true;
      final c = collabController(projectId);
      await waitForLoad(c);

      await c.forceReleasePanel(0);

      expect(c.state.isClaiming, isFalse);
      expect(c.state.error, contains('Force-release failed'));
      c.dispose();
    });

    test('collaborative actions are unavailable without a wired service',
        () async {
      final projectId = await seedProject(cols: 2);
      final c = makeController(projectId); // no collaborativeService
      await waitForLoad(c);

      await c.publishToHub();

      expect(c.state.error, contains('unavailable'));
      c.dispose();
    });

    test('canCollaborate is false when the hub is not configured/signed-in',
        () async {
      final projectId = await seedProject(cols: 2);
      // A hub-aware service is wired (as it always is in the real provider), but
      // no hub is configured: the collaborative affordances must stay disabled
      // rather than enabled-then-failing at the tap.
      final unconfigured = makeController(
        projectId,
        collaborativeService: collab,
        hubConfigured: false,
      );
      await waitForLoad(unconfigured);
      expect(unconfigured.canCollaborate, isFalse);
      unconfigured.dispose();

      final configured = makeController(
        projectId,
        collaborativeService: collab,
        hubConfigured: true,
      );
      await waitForLoad(configured);
      expect(configured.canCollaborate, isTrue);
      configured.dispose();
    });
  });
}

/// A fake [CollaborativeMosaicService] that records calls and mutates the DB so
/// the controller's reload reflects the new collab state — the controller's
/// actions are pinned without HTTP.
class _FakeCollab extends CollaborativeMosaicService {
  _FakeCollab({
    required this.projectsDao,
    required this.panelsDao,
    required this.mastersDao,
    required super.projectService,
  }) : super(
          credentialsResolver: _noCreds,
          projectsDao: projectsDao,
          panelsDao: panelsDao,
          mastersDao: mastersDao,
          logger: LoggingService(),
          assemblyDirResolver: _tmpDir,
        );

  static Future<ConstellationCredentials?> _noCreds() async => null;
  static Future<String> _tmpDir(String id) async => '/tmp/$id';

  final MosaicProjectsDao projectsDao;
  final MosaicPanelsDao panelsDao;
  final IntegratedMastersDao mastersDao;

  int publishCalls = 0;
  int assembleCalls = 0;
  final List<int> claimedIndices = [];
  final List<int> uploadedIndices = [];
  final List<int> forceReleasedIndices = [];
  final List<int> releasedIndices = [];
  bool throwOnPublish = false;
  bool throwOnForceRelease = false;

  /// Simulates a hub that accepts the connection and then goes quiet.
  Duration? hangOnPublish;

  @override
  Future<CollabMosaic> publishProject(int projectId) async {
    publishCalls++;
    if (throwOnPublish) throw StateError('boom');
    if (hangOnPublish != null) await Future<void>.delayed(hangOnPublish!);
    await projectsDao.setHubMosaic(projectId, 'mos-1', 'owner');
    return const CollabMosaic(
      mosaicId: 'mos-1',
      ownerAccountId: 'acct-1',
      name: 'Veil',
      rows: 1,
      cols: 2,
      overlapPct: 15.0,
      positionAngleDeg: 0.0,
      centerRaDeg: 300.0,
      centerDecDeg: 30.0,
      status: 'open',
      outputPresent: false,
    );
  }

  @override
  Future<List<MosaicPanelClaim>> claimPanels(
    int projectId,
    List<int> indices,
  ) async {
    claimedIndices.addAll(indices);
    final claims = <MosaicPanelClaim>[];
    for (final index in indices) {
      final panel = await panelsDao.getByIndex(projectId, index);
      await panelsDao.setClaim(
        panel!.id!,
        claimToken: 'baton-$index',
        rigId: 'rig-1',
        accountId: 'acct-1',
      );
      claims.add(MosaicPanelClaim(
        mosaicId: 'mos-1',
        panelIndex: index,
        claimToken: 'baton-$index',
        expiresAt: DateTime.now().toUtc(),
      ));
    }
    return claims;
  }

  @override
  Future<CollabMosaicPanel> uploadPanelMaster(
    int projectId,
    int panelIndex, {
    ContributionLicense? license,
    bool? attributionConsent,
  }) async {
    uploadedIndices.add(panelIndex);
    final panel = await panelsDao.getByIndex(projectId, panelIndex);
    await panelsDao.setUploaded(panel!.id!, panel.integratedMasterId ?? 1);
    return const CollabMosaicPanel(
      panelIndex: 0,
      centerRaDeg: 0.0,
      centerDecDeg: 0.0,
      status: 'uploaded',
      assignedAccountId: 'acct-1',
      assignedRigId: 'rig-1',
      uploaded: true,
    );
  }

  @override
  Future<bool> releasePanel(int projectId, int panelIndex) async {
    releasedIndices.add(panelIndex);
    final panel = await panelsDao.getByIndex(projectId, panelIndex);
    await panelsDao.clearClaim(panel!.id!);
    return true;
  }

  @override
  Future<bool> forceReleasePanel(int projectId, int panelIndex) async {
    if (throwOnForceRelease) {
      throw StateError('only the mosaic owner or an admin may force-release');
    }
    forceReleasedIndices.add(panelIndex);
    final panel = await panelsDao.getByIndex(projectId, panelIndex);
    await panelsDao.updateStatus(panel!.id!, MosaicPanelStatus.pending);
    return true;
  }

  @override
  Future<MosaicStitchOutcome> assembleMosaic(int projectId) async {
    assembleCalls++;
    await projectsDao.setCollabStatus(projectId, 'complete');
    return const MosaicStitchOutcome(
      outputMasterId: 1,
      panelCount: 2,
      result: MosaicStitchResult(
        outputPath: '/tmp/mosaic.fits',
        previewPath: '/tmp/mosaic.png',
        outWidth: 200,
        outHeight: 80,
        overlapPairs: 1,
        meanPanelGain: 1.0,
      ),
    );
  }

  int listCalls = 0;
  final List<String> joinedHubIds = [];
  int refreshCalls = 0;
  int downloadCalls = 0;

  @override
  Future<List<CollabMosaic>> listMosaics() async {
    listCalls++;
    return const [
      CollabMosaic(
        mosaicId: 'mos-9',
        ownerAccountId: '',
        ownerDisplayName: 'Andromeda Club',
        name: 'Veil',
        rows: 1,
        cols: 2,
        overlapPct: 15.0,
        positionAngleDeg: 0.0,
        centerRaDeg: 300.0,
        centerDecDeg: 30.0,
        status: 'open',
        outputPresent: false,
      ),
    ];
  }

  @override
  Future<void> joinAsParticipant(int projectId, String hubMosaicId) async {
    joinedHubIds.add(hubMosaicId);
    await projectsDao.setHubMosaic(projectId, hubMosaicId, 'participant');
  }

  @override
  Future<CollabMosaic?> refreshStatus(int projectId) async {
    refreshCalls++;
    await projectsDao.setCollabStatus(projectId, 'assembling');
    return null;
  }

  @override
  Future<String> downloadOutput(int projectId, {String? outPath}) async {
    downloadCalls++;
    final masterId = await mastersDao.insertMaster(
      targetId: null,
      name: 'out',
      masterFitsPath: outPath ?? '/tmp/out.fits',
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
    );
    await projectsDao.setOutputMaster(projectId, masterId);
    await projectsDao.setCollabStatus(projectId, 'complete');
    return outPath ?? '/tmp/out.fits';
  }
}

/// A throwaway [PostSessionSeam] for wiring the unused integration service in
/// the spy's super ctor — the controller never reaches it.
PostSessionSeam _noopSeam() => _NoopSeam();

class _NoopSeam implements PostSessionSeam {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not used in test');
}
