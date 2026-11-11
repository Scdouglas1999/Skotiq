// Pins the results of the mosaic project and panel DAOs on a seeded database:
// reads on empty tables, the collaborative-project filter's null and empty
// string handling, ORDER BY ties broken by id, the panel upsert that keeps
// capture progress, and the rows each write leaves behind.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/mosaic_panels_dao.dart';
import 'package:skotiq_core/src/database/daos/mosaic_projects_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/imaging/mosaic_project.dart';

import 'pin_harness.dart';

Object? _encode(Object value) => switch (value) {
  MosaicProject p => {
    'id': p.id,
    'targetId': p.targetId,
    'name': p.name,
    'rows': p.rows,
    'cols': p.cols,
    'overlapPct': p.overlapPct,
    'positionAngleDeg': p.positionAngleDeg,
    'status': p.status,
    'outputMasterId': p.outputMasterId,
    'createdAt': p.createdAt,
    'updatedAt': p.updatedAt,
    'hubMosaicId': p.hubMosaicId,
    'collabRole': p.collabRole,
    'collabStatus': p.collabStatus,
  },
  MosaicProjectPanel p => {
    'id': p.id,
    'projectId': p.projectId,
    'panelIndex': p.panelIndex,
    'centerRa': p.centerRa,
    'centerDec': p.centerDec,
    'targetId': p.targetId,
    'integratedMasterId': p.integratedMasterId,
    'capturedCount': p.capturedCount,
    'status': p.status,
    'assignedRigId': p.assignedRigId,
    'assignedUserId': p.assignedUserId,
    'claimToken': p.claimToken,
    'uploadedMasterId': p.uploadedMasterId,
  },
  _ => null,
};

Future<int> _seedMaster(SkotiqDatabase db, String name) => db.customInsert(
  'INSERT INTO integrated_masters (name, created_at, updated_at) '
  "VALUES ('$name', 1740866400, 1740866400)",
);

void main() {
  late SkotiqDatabase db;
  late PinSeed seed;

  setUp(() async {
    db = openPinDatabase();
    seed = await PinSeed.create(db);
  });

  tearDown(() => db.close());

  test('MosaicProjectsDao results are pinned', () async {
    final pins = PinRecorder('mosaic_projects_dao', encode: _encode);
    final dao = MosaicProjectsDao(db);
    final master = await _seedMaster(db, 'stitched');

    await pins('empty listAll', dao.listAll);
    await pins('empty getById', () => dao.getById(1));
    await pins('empty listActiveCollaborative', dao.listActiveCollaborative);
    await pins('empty getByHubMosaicId', () => dao.getByHubMosaicId('h'));
    await pins(
      'empty listByStatus',
      () => dao.listByStatus(MosaicProjectStatus.planning),
    );

    await pins(
      'create full',
      () => dao.create(
        targetId: seed.targets[0],
        name: 'M31 2x3',
        rows: 2,
        cols: 3,
        overlapPct: 20,
        positionAngleDeg: 35.5,
        status: MosaicProjectStatus.capturing,
        outputMasterId: master,
        createdAt: pinT(10),
        updatedAt: pinT(11),
      ),
    );
    await pins(
      'create defaults tie',
      () => dao.create(name: 'Veil', rows: 1, cols: 4, createdAt: pinT(10)),
    );
    await pins(
      'create older',
      () => dao.create(name: 'Old', rows: 3, cols: 3, createdAt: pinT(1)),
    );
    await pins(
      'create default time',
      () => dao.create(name: 'Now', rows: 1, cols: 1),
    );
    await pins(
      'create fifth',
      () => dao.create(name: 'Fifth', rows: 2, cols: 2, createdAt: pinT(30)),
    );
    await pins(
      'create sixth',
      () => dao.create(name: 'Sixth', rows: 2, cols: 2, createdAt: pinT(31)),
    );
    await pins.dump(db, 'mosaic_projects', 'after create');

    await pins(
      'setHubMosaic 1',
      () => dao.setHubMosaic(1, 'hub-a', 'owner', now: pinT(12)),
    );
    await pins(
      'setHubMosaic 2',
      () => dao.setHubMosaic(2, 'hub-a', 'participant', now: pinT(13)),
    );
    await pins(
      'setHubMosaic 3 empty id',
      () => dao.setHubMosaic(3, '', 'owner', now: pinT(14)),
    );
    await pins(
      'setHubMosaic 5',
      () => dao.setHubMosaic(5, 'hub-c', 'owner', now: pinT(32)),
    );
    await pins(
      'setCollabStatus 5 complete',
      () => dao.setCollabStatus(5, 'complete', now: pinT(33)),
    );
    await pins(
      'setCollabStatus 2 assembling',
      () => dao.setCollabStatus(2, 'assembling', now: pinT(34)),
    );
    await pins(
      'setHubMosaic 6',
      () => dao.setHubMosaic(6, 'hub-d', 'owner', now: pinT(35)),
    );
    await db.customStatement(
      'UPDATE mosaic_projects SET collab_status = NULL WHERE id = 6',
    );
    await pins(
      'setHubMosaic missing',
      () => dao.setHubMosaic(99, 'x', 'owner', now: pinT(1)),
    );
    await pins(
      'setCollabStatus default now',
      () => dao.setCollabStatus(4, 'x'),
    );
    await pins.dump(db, 'mosaic_projects', 'after hub');

    await pins('listAll', dao.listAll);
    await pins('getById 1', () => dao.getById(1));
    await pins('getById missing', () => dao.getById(77));
    await pins('listActiveCollaborative', dao.listActiveCollaborative);
    await pins('getByHubMosaicId hub-a', () => dao.getByHubMosaicId('hub-a'));
    await pins('getByHubMosaicId empty', () => dao.getByHubMosaicId(''));
    await pins('getByHubMosaicId missing', () => dao.getByHubMosaicId('zz'));
    await pins(
      'listByStatus planning',
      () => dao.listByStatus(MosaicProjectStatus.planning),
    );

    await pins(
      'updateStatus',
      () => dao.updateStatus(2, MosaicProjectStatus.stitching, now: pinT(40)),
    );
    await pins(
      'updateStatus missing',
      () => dao.updateStatus(99, MosaicProjectStatus.stitching, now: pinT(40)),
    );
    await pins(
      'setOutputMaster',
      () => dao.setOutputMaster(3, master, now: pinT(41)),
    );
    await pins(
      'updateStatus default now',
      () => dao.updateStatus(5, MosaicProjectStatus.integrating),
    );
    await pins(
      'setOutputMaster default now',
      () => dao.setOutputMaster(6, master),
    );
    await pins.dump(db, 'mosaic_projects', 'after status');

    await MosaicPanelsDao(
      db,
    ).upsert(projectId: 1, panelIndex: 0, centerRa: 1, centerDec: 2);
    await pins('deleteProject 1', () => dao.deleteProject(1));
    await pins('deleteProject missing', () => dao.deleteProject(1));
    await pins.dump(db, 'mosaic_projects', 'after delete');
    await pins.dump(db, 'mosaic_panels', 'after delete');
    pins.verify();
  });

  test('MosaicPanelsDao results are pinned', () async {
    final pins = PinRecorder('mosaic_panels_dao', encode: _encode);
    final dao = MosaicPanelsDao(db);
    final projects = MosaicProjectsDao(db);
    final p1 = await projects.create(
      name: 'A',
      rows: 2,
      cols: 2,
      createdAt: pinT(0),
    );
    final p2 = await projects.create(
      name: 'B',
      rows: 1,
      cols: 1,
      createdAt: pinT(0),
    );
    final m1 = await _seedMaster(db, 'panel master');
    final m2 = await _seedMaster(db, 'uploaded');

    await pins('empty getForProject', () => dao.getForProject(p1));
    await pins('empty getByIndex', () => dao.getByIndex(p1, 0));
    await pins('empty getById', () => dao.getById(1));

    await pins(
      'upsert p1 #2',
      () => dao.upsert(
        projectId: p1,
        panelIndex: 2,
        centerRa: 10.5,
        centerDec: 41.25,
        targetId: seed.targets[0],
        integratedMasterId: m1,
      ),
    );
    await pins(
      'upsert p1 #0',
      () =>
          dao.upsert(projectId: p1, panelIndex: 0, centerRa: 10, centerDec: 41),
    );
    await pins(
      'upsert p1 #1',
      () =>
          dao.upsert(projectId: p1, panelIndex: 1, centerRa: 9, centerDec: 40),
    );
    await pins(
      'upsert p2 #0',
      () =>
          dao.upsert(projectId: p2, panelIndex: 0, centerRa: 3, centerDec: -5),
    );
    await pins.dump(db, 'mosaic_panels', 'after insert');

    await pins('incrementCaptured', () => dao.incrementCaptured(1, delta: 4));
    await pins('incrementCaptured default', () => dao.incrementCaptured(1));
    await pins(
      'incrementCaptured zero',
      () => dao.incrementCaptured(1, delta: 0),
    );
    await pins('incrementCaptured missing', () => dao.incrementCaptured(99));
    await pins(
      'updateStatus',
      () => dao.updateStatus(1, MosaicPanelStatus.captured),
    );
    await pins(
      're-upsert keeps progress',
      () =>
          dao.upsert(projectId: p1, panelIndex: 2, centerRa: 11, centerDec: 42),
    );
    await pins('setMaster', () => dao.setMaster(2, m1));
    await pins('setMaster missing', () => dao.setMaster(99, m1));
    await pins('clearMaster', () => dao.clearMaster(2));
    await pins(
      'setClaim',
      () => dao.setClaim(3, claimToken: 'tok', rigId: 'rig-1', accountId: 'u1'),
    );
    await pins('setClaim nulls', () => dao.setClaim(4, claimToken: 'tok2'));
    await pins('setUploaded', () => dao.setUploaded(3, m2));
    await pins('setCaptured', () => dao.setCaptured(3, 17));
    await pins('setCaptured zero', () => dao.setCaptured(4, 0));
    await pins('setCaptured negative', () => dao.setCaptured(3, -1));
    await pins.dump(db, 'mosaic_panels', 'after updates');
    await pins('clearClaim', () => dao.clearClaim(3));
    await pins('clearClaim missing', () => dao.clearClaim(99));
    await pins.dump(db, 'mosaic_panels', 'after clearClaim');

    await pins('getForProject p1', () => dao.getForProject(p1));
    await pins('getForProject p2', () => dao.getForProject(p2));
    await pins('getByIndex p1 2', () => dao.getByIndex(p1, 2));
    await pins('getByIndex missing', () => dao.getByIndex(p2, 2));
    await pins('getById 3', () => dao.getById(3));
    await pins('getById missing', () => dao.getById(99));
    pins.verify();
  });
}
