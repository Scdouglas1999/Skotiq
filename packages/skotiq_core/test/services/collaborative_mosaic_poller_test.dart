// The unattended owner auto-assembly / participant auto-download poller.
//
// Drives [CollaborativeMosaicPoller.pollOnce] against a real in-memory DB (real
// MosaicProjectsDao) and a FAKE [CollaborativeMosaicService] that returns a hub
// status sequence pending -> assembling -> complete. Pins two guarantees:
//
//   * an OWNER project auto-fires assembleMosaic EXACTLY ONCE when the hub flips
//     to `assembling` (and never again under repeated polls / while a long
//     stitch is still in flight — the re-entrancy guard), and
//   * a PARTICIPANT project auto-fires downloadOutput once on `complete`.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// A fake [CollaborativeMosaicService] whose `refreshStatus` mirrors a
/// caller-controlled hub status into `collab_status` (so the next sweep sees the
/// progression), and whose terminal actions record their call count + mark the
/// project complete. `assembleMosaic` can be gated on a [Completer] so the test
/// can hold it "in flight" across overlapping ticks to exercise the guard.
class _FakePollService extends CollaborativeMosaicService {
  _FakePollService({required SkotiqDatabase db, required super.projectService})
    : projectsDao = MosaicProjectsDao(db),
      panelsDao = MosaicPanelsDao(db),
      super(
        credentialsResolver: _noCreds,
        projectsDao: MosaicProjectsDao(db),
        panelsDao: MosaicPanelsDao(db),
        mastersDao: IntegratedMastersDao(db),
        logger: LoggingService(),
        assemblyDirResolver: _tmpDir,
      );

  static Future<ConstellationCredentials?> _noCreds() async => null;
  static Future<String> _tmpDir(String id) async => '/tmp/$id';

  final MosaicProjectsDao projectsDao;
  final MosaicPanelsDao panelsDao;

  /// The status the hub reports on the next refresh.
  String hubStatus = 'published';
  int refreshCalls = 0;
  int assembleCalls = 0;
  int downloadCalls = 0;

  /// Panel indices the auto-upload pass pushed, in order.
  final List<int> uploadedIndices = <int>[];

  /// When set, `assembleMosaic` awaits this before completing — lets the test
  /// hold the action in flight across a second poll tick.
  Completer<void>? assembleGate;

  CollabMosaic _mosaicWith(String status) => CollabMosaic(
    mosaicId: 'mos-1',
    ownerAccountId: 'acct-1',
    name: 'Veil',
    rows: 1,
    cols: 2,
    overlapPct: 15.0,
    positionAngleDeg: 0.0,
    centerRaDeg: 300.0,
    centerDecDeg: 30.0,
    status: status,
    outputPresent: status == 'complete',
  );

  @override
  Future<CollabMosaic?> refreshStatus(int projectId) async {
    refreshCalls++;
    final project = await projectsDao.getById(projectId);
    if (project?.hubMosaicId == null) return null;
    await projectsDao.setCollabStatus(projectId, hubStatus);
    return _mosaicWith(hubStatus);
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
  Future<MosaicStitchOutcome> assembleMosaic(int projectId) async {
    assembleCalls++;
    final gate = assembleGate;
    if (gate != null) await gate.future;
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

  @override
  Future<String> downloadOutput(int projectId) async {
    downloadCalls++;
    await projectsDao.setCollabStatus(projectId, 'complete');
    return '/tmp/out.fits';
  }
}

/// Build a minimal real [MosaicProjectService] (with a noop seam) so the fake
/// service is constructible — the poller never reaches the stitcher.
MosaicProjectService _buildProjectService(SkotiqDatabase db) {
  final mastersDao = IntegratedMastersDao(db);
  final seam = _NoopSeam();
  return MosaicProjectService(
    db: db,
    projectsDao: MosaicProjectsDao(db),
    panelsDao: MosaicPanelsDao(db),
    targetsDao: TargetsDao(db),
    imagesDao: ImagesDao(db),
    mastersDao: mastersDao,
    integrationService: PostSessionIntegrationService(
      mastersDao: mastersDao,
      calibrationLibrary: CalibrationLibraryService(
        db: db,

        flatLibraryDao: FlatLibraryDao(db),

        tagsDao: CalibrationTagsDao(db),
      ),
      seam: seam,
    ),
    seam: seam,
  );
}

class _NoopSeam implements PostSessionSeam {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not used in test');
}

void main() {
  late SkotiqDatabase db;
  late MosaicProjectsDao projectsDao;
  late _FakePollService service;
  late CollaborativeMosaicPoller poller;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    projectsDao = MosaicProjectsDao(db);
    service = _FakePollService(
      db: db,
      projectService: _buildProjectService(db),
    );
    poller = CollaborativeMosaicPoller(
      service: service,
      projectsDao: projectsDao,
      panelsDao: MosaicPanelsDao(db),
      logger: LoggingService(),
    );
  });

  tearDown(() async {
    poller.stop();
    await db.close();
  });

  Future<int> seedOwner() async {
    final id = await projectsDao.create(name: 'Veil', rows: 1, cols: 2);
    await projectsDao.setHubMosaic(id, 'mos-1', 'owner');
    return id;
  }

  Future<int> seedParticipant() async {
    final id = await projectsDao.create(name: 'Veil', rows: 1, cols: 2);
    await projectsDao.setHubMosaic(id, 'mos-1', 'participant');
    return id;
  }

  test('owner: does NOT assemble while the hub is still open', () async {
    await seedOwner();
    service.hubStatus = 'published';

    await poller.pollOnce();

    expect(service.refreshCalls, 1);
    expect(service.assembleCalls, 0);
  });

  test('owner: auto-assembles once when the hub flips to assembling', () async {
    final id = await seedOwner();
    service.hubStatus = 'assembling';

    await poller.pollOnce();

    expect(service.assembleCalls, 1);
    // The terminal action marked the project complete, so it drops out of the
    // active-collaborative sweep — a second poll cannot re-fire it.
    final project = await projectsDao.getById(id);
    expect(project!.collabStatus, 'complete');

    await poller.pollOnce();
    expect(service.assembleCalls, 1);
  });

  test(
    'owner: no double-fire while a long stitch is still in flight',
    () async {
      await seedOwner();
      service.hubStatus = 'assembling';
      // Hold assembleMosaic open so it stays in flight across the second tick.
      final gate = Completer<void>();
      service.assembleGate = gate;

      final first = poller.pollOnce();
      // Let the first sweep reach (and block inside) assembleMosaic.
      await Future<void>.delayed(Duration.zero);
      // A second tick lands while the stitch is still running — the in-flight
      // guard must skip it rather than starting a second assemble.
      await poller.pollOnce();
      expect(service.assembleCalls, 1);

      gate.complete();
      await first;
      expect(service.assembleCalls, 1);
    },
  );

  test(
    'participant: auto-downloads once when the hub reports complete',
    () async {
      final id = await seedParticipant();
      // Still assembling — a participant does nothing yet.
      service.hubStatus = 'assembling';
      await poller.pollOnce();
      expect(service.downloadCalls, 0);

      // Owner finished; the hub now serves the output.
      service.hubStatus = 'complete';
      await poller.pollOnce();
      expect(service.downloadCalls, 1);
      final project = await projectsDao.getById(id);
      expect(project!.collabStatus, 'complete');

      // Completed projects drop out of the sweep — no re-download.
      await poller.pollOnce();
      expect(service.downloadCalls, 1);
    },
  );

  test('participant: never calls assembleMosaic', () async {
    await seedParticipant();
    service.hubStatus = 'assembling';
    await poller.pollOnce();
    service.hubStatus = 'complete';
    await poller.pollOnce();
    expect(service.assembleCalls, 0);
  });

  // Auto-upload — the integrate→upload bridge that lets a truly unattended rig
  // push its captured panels into the hub (so the hub can ever reach
  // `assembling`), gated on the persisted unattended-upload consent.

  /// Seed an owner project with one claimed + integrated + not-yet-uploaded
  /// panel (the exact state an unattended rig is stuck in after capturing).
  Future<int> seedClaimedIntegratedPanel() async {
    final mastersDao = IntegratedMastersDao(db);
    final panelsDao = MosaicPanelsDao(db);
    final id = await projectsDao.create(name: 'Veil', rows: 1, cols: 1);
    await projectsDao.setHubMosaic(id, 'mos-1', 'owner');
    final masterId = await mastersDao.insertMaster(
      name: 'Panel 0',
      masterFitsPath: '/tmp/p0.fits',
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
    );
    await panelsDao.upsert(
      projectId: id,
      panelIndex: 0,
      centerRa: 20.0,
      centerDec: 30.0,
    );
    final panel = await panelsDao.getByIndex(id, 0);
    await panelsDao.setMaster(panel!.id!, masterId);
    await panelsDao.setClaim(
      panel.id!,
      claimToken: 'baton-0',
      rigId: 'rig-1',
      accountId: 'acct-1',
    );
    return id;
  }

  test(
    'auto-uploads a claimed integrated panel when consent allows it',
    () async {
      final id = await seedClaimedIntegratedPanel();
      service.hubStatus = 'published';
      final autoPoller = CollaborativeMosaicPoller(
        service: service,
        projectsDao: projectsDao,
        panelsDao: MosaicPanelsDao(db),
        logger: LoggingService(),
        uploadConsentResolver: () async => const MosaicUploadConsent(
          license: ContributionLicense.ccBy,
          attributionConsent: true,
          autoUpload: true,
        ),
      );

      await autoPoller.pollOnce();

      expect(service.uploadedIndices, [0]);
      final reread = await MosaicPanelsDao(db).getByIndex(id, 0);
      expect(reread!.isUploaded, isTrue);
      autoPoller.stop();
    },
  );

  test('does NOT auto-upload when no unattended consent is recorded', () async {
    await seedClaimedIntegratedPanel();
    service.hubStatus = 'published';
    // The default poller (from setUp) has no consent resolver wired.
    await poller.pollOnce();
    expect(service.uploadedIndices, isEmpty);
  });

  test('does NOT auto-upload when consent withholds the auto opt-in', () async {
    await seedClaimedIntegratedPanel();
    service.hubStatus = 'published';
    final autoPoller = CollaborativeMosaicPoller(
      service: service,
      projectsDao: projectsDao,
      panelsDao: MosaicPanelsDao(db),
      logger: LoggingService(),
      // Consent recorded, but the unattended auto-upload opt-in is OFF.
      uploadConsentResolver: () async => const MosaicUploadConsent(
        license: ContributionLicense.ccBy,
        attributionConsent: true,
      ),
    );

    await autoPoller.pollOnce();

    expect(service.uploadedIndices, isEmpty);
    autoPoller.stop();
  });
}
