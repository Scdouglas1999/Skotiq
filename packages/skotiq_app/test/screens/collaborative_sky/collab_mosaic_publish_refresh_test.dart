// Regression guard for: "Collaborative Sky still says 'No collaborative
// mosaics on this hub yet' right after you publish one".
//
// The Collaborative Sky listings are plain (non-autoDispose) FutureProviders,
// so the empty answer the surface got on first open was cached for the life of
// the container. Publishing from the mosaic planner reloaded only the planner's
// own project row, so the surface whose entire job is to show shared mosaics
// went on claiming there were none until the operator pressed its manual
// refresh icon.
//
// This drives the REAL `mosaicProjectControllerProvider` (not a hand-built
// controller), so cutting the `onHubStateChanged` wiring in the provider body
// — not just the callback inside the controller — fails the test.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/collaborative_sky/collaborative_sky_providers.dart';
import 'package:skotiq_app/screens/mosaic/mosaic_project_controller.dart';
import 'package:skotiq_core/skotiq_core.dart';

const _published = CollabMosaic(
  mosaicId: 'mos-1',
  ownerAccountId: 'acct-1',
  name: 'M31 Wide Field',
  rows: 2,
  cols: 3,
  overlapPct: 15.0,
  positionAngleDeg: 0.0,
  centerRaDeg: 10.68,
  centerDecDeg: 41.27,
  status: 'open',
  outputPresent: false,
);

/// A hub stand-in: `listMosaics` answers from an in-memory catalogue that
/// `publishProject` appends to, so a stale (cached) read and a fresh read give
/// visibly different answers.
class _FakeHub extends CollaborativeMosaicService {
  _FakeHub({
    required this.projectsDao,
    required this.panelsDao,
    required super.mastersDao,
    required super.projectService,
  }) : super(
          credentialsResolver: _noCreds,
          projectsDao: projectsDao,
          panelsDao: panelsDao,
          logger: LoggingService(),
          assemblyDirResolver: _tmpDir,
        );

  static Future<ConstellationCredentials?> _noCreds() async => null;
  static Future<String> _tmpDir(String id) async => '/tmp/$id';

  final MosaicProjectsDao projectsDao;
  final MosaicPanelsDao panelsDao;

  final List<CollabMosaic> hubMosaics = [];
  int listCalls = 0;

  @override
  Future<List<CollabMosaic>> listMosaics() async {
    listCalls++;
    return List.of(hubMosaics);
  }

  @override
  Future<CollabMosaic> publishProject(int projectId) async {
    hubMosaics.add(_published);
    await projectsDao.setHubMosaic(projectId, _published.mosaicId, 'owner');
    return _published;
  }

  @override
  Future<List<MosaicPanelClaim>> claimPanels(
    int projectId,
    List<int> indices,
  ) async {
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
        mosaicId: _published.mosaicId,
        panelIndex: index,
        claimToken: 'baton-$index',
        expiresAt: DateTime.now().toUtc(),
      ));
    }
    return claims;
  }
}

/// The seam is never reached: nothing in these tests integrates or stitches.
class _NoopSeam implements PostSessionSeam {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not used in test');
}

void main() {
  late SkotiqDatabase db;
  late ProviderContainer container;
  late _FakeHub hub;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    final projectsDao = MosaicProjectsDao(db);
    final panelsDao = MosaicPanelsDao(db);
    final mastersDao = IntegratedMastersDao(db);
    hub = _FakeHub(
      projectsDao: projectsDao,
      panelsDao: panelsDao,
      mastersDao: mastersDao,
      projectService: MosaicProjectService(
        db: db,
        projectsDao: projectsDao,
        panelsDao: panelsDao,
        mastersDao: mastersDao,
        targetsDao: TargetsDao(db),
        imagesDao: ImagesDao(db),
        integrationService: PostSessionIntegrationService(
          mastersDao: mastersDao,
          calibrationLibrary: CalibrationLibraryService(
            db: db,
            flatLibraryDao: FlatLibraryDao(db),
            tagsDao: CalibrationTagsDao(db),
          ),
          seam: _NoopSeam(),
        ),
        seam: _NoopSeam(),
      ),
    );
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        collaborativeMosaicServiceProvider.overrideWithValue(hub),
        constellationConfiguredProvider.overrideWith((ref) async => true),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<int> seedProject() async {
    final dao = MosaicProjectsDao(db);
    final panels = MosaicPanelsDao(db);
    final projectId =
        await dao.create(name: 'M31 Wide Field', rows: 2, cols: 3);
    for (var i = 0; i < 6; i++) {
      await panels.upsert(
        projectId: projectId,
        panelIndex: i,
        centerRa: 0.71 + i * 0.01,
        centerDec: 41.27,
      );
    }
    return projectId;
  }

  /// Resolve the hub-configured gate BEFORE reading the controller: the family
  /// provider watches it, so a controller read while it is still loading is torn
  /// down and rebuilt the moment it resolves.
  Future<MosaicProjectController> openController(int projectId) async {
    await container.read(constellationConfiguredProvider.future);
    final controller = container.read(
      mosaicProjectControllerProvider(
        MosaicProjectControllerArgs(
          projectId: projectId,
          artifactsBaseDir: '/tmp/skotiq-mosaic-test',
        ),
      ).notifier,
    );
    for (var i = 0; i < 50 && controller.state.isLoading; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    return controller;
  }

  test('publishing a project refreshes the hub mosaic listing', () async {
    final projectId = await seedProject();

    // Opening Collaborative Sky first is what warms the cache with "empty" —
    // exactly the order the operator hit in the field.
    expect(await container.read(collaborativeMosaicsProvider.future), isEmpty);
    expect(hub.listCalls, 1);

    final controller = await openController(projectId);
    expect(controller.state.project, isNotNull);

    await controller.publishToHub();
    expect(controller.state.isPublished, isTrue);

    final listed = await container.read(collaborativeMosaicsProvider.future);
    expect(
      listed.map((m) => m.name),
      ['M31 Wide Field'],
      reason: 'the surface that exists to show shared mosaics must not keep '
          'serving its pre-publish answer',
    );
    expect(hub.listCalls, 2, reason: 'publishing must drop the cached listing');
  });

  test('claiming a panel refreshes the hub mosaic listing', () async {
    final projectId = await seedProject();
    final controller = await openController(projectId);
    await controller.publishToHub();

    await container.read(collaborativeMosaicsProvider.future);
    final callsBeforeClaim = hub.listCalls;

    await controller.claimPanel(0);

    await container.read(collaborativeMosaicsProvider.future);
    expect(hub.listCalls, callsBeforeClaim + 1);
  });
}
