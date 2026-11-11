// Pins the results of IntegratedMastersDao on a seeded database: the
// accumulating-master lookup with and without a filter, partial updates that
// write only the fields given, the replace transaction that moves recipes,
// fold records under the (master, image) identity, and the chunked
// master-ids-for-images join with its newest-first order.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/integrated_masters_dao.dart';
import 'package:skotiq_core/src/database/daos/recipes_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/imaging/integrated_master.dart';

import 'pin_harness.dart';

Object? _encode(Object value) => switch (value) {
  IntegratedMaster m => {
    'id': m.id,
    'targetId': m.targetId,
    'name': m.name,
    'masterFitsPath': m.masterFitsPath,
    'previewPngPath': m.previewPngPath,
    'sidecarPath': m.sidecarPath,
    'rejectionMapPath': m.rejectionMapPath,
    'rejectionMapPreviewPath': m.rejectionMapPreviewPath,
    'coverageMapPath': m.coverageMapPath,
    'coverageMapPreviewPath': m.coverageMapPreviewPath,
    'status': m.status,
    'accumulationMode': m.accumulationMode,
    'channels': m.channels,
    'width': m.width,
    'height': m.height,
    'frameCount': m.frameCount,
    'totalIntegrationSeconds': m.totalIntegrationSeconds,
    'filter': m.filter,
    'settingsJson': m.settingsJson,
    'statsJson': m.statsJson,
    'createdAt': m.createdAt,
    'updatedAt': m.updatedAt,
    'wcs': [
      m.wcsCrval1,
      m.wcsCrval2,
      m.wcsCrpix1,
      m.wcsCrpix2,
      m.wcsCd1_1,
      m.wcsCd1_2,
      m.wcsCd2_1,
      m.wcsCd2_2,
    ],
    'backgroundExtractedPath': m.backgroundExtractedPath,
    'deconvolvedPath': m.deconvolvedPath,
    'starReducedPath': m.starReducedPath,
    'colorCalibratedPath': m.colorCalibratedPath,
  },
  IntegratedMasterFrame f => {
    'id': f.id,
    'masterId': f.masterId,
    'imageId': f.imageId,
    'weight': f.weight,
    'alignmentResidualPx': f.alignmentResidualPx,
    'accepted': f.accepted,
    'rejectionReason': f.rejectionReason,
    'foldedAt': f.foldedAt,
  },
  _ => null,
};

void main() {
  late SkotiqDatabase db;
  late PinSeed seed;

  setUp(() async {
    db = openPinDatabase();
    seed = await PinSeed.create(db);
  });

  tearDown(() => db.close());

  test('IntegratedMastersDao results are pinned', () async {
    final pins = PinRecorder('integrated_masters_dao', encode: _encode);
    final dao = IntegratedMastersDao(db);
    final t0 = seed.targets[0];
    const acc = IntegratedMasterStatus.accumulating;
    const fin = IntegratedMasterStatus.finalized;
    const batch = AccumulationMode.batch;
    const running = AccumulationMode.runningWeightedMean;

    await pins('empty getAll', dao.getAll);
    await pins('empty getById', () => dao.getById(1));
    await pins('empty getForTarget', () => dao.getForTarget(t0));
    await pins(
      'empty accumulating',
      () => dao.getAccumulatingForTargetFilter(targetId: t0, filter: 'L'),
    );
    await pins('empty masterIdsForImages', () => dao.masterIdsForImages([]));
    await pins('empty getFoldedImageIds', () => dao.getFoldedImageIds(1));
    await pins('empty getFramesForMaster', () => dao.getFramesForMaster(1));

    await pins(
      'insert full',
      () => dao.insertMaster(
        targetId: t0,
        name: 'M31 L',
        masterFitsPath: '/m/L.fits',
        previewPngPath: '/m/L.png',
        sidecarPath: '/m/L.acc',
        rejectionMapPath: '/m/L_rej.fits',
        rejectionMapPreviewPath: '/m/L_rej.png',
        coverageMapPath: '/m/L_cov.fits',
        coverageMapPreviewPath: '/m/L_cov.png',
        status: acc,
        accumulationMode: running,
        channels: 1,
        width: 6248,
        height: 4176,
        frameCount: 40,
        totalIntegrationSeconds: 4800,
        filter: 'L',
        settingsJson: '{"k":1}',
        statsJson: '{"snr":12.5}',
        createdAt: pinT(10),
        updatedAt: pinT(11),
      ),
    );
    await pins(
      'insert accumulating no filter tie',
      () => dao.insertMaster(
        targetId: t0,
        name: 'M31 none',
        status: acc,
        accumulationMode: running,
        createdAt: pinT(10),
        updatedAt: pinT(10),
      ),
    );
    await pins(
      'insert accumulating empty filter',
      () => dao.insertMaster(
        targetId: t0,
        name: 'M31 empty',
        filter: '',
        status: acc,
        accumulationMode: running,
        createdAt: pinT(5),
        updatedAt: pinT(5),
      ),
    );
    await pins(
      'insert finalized default now',
      () => dao.insertMaster(name: 'Loose', status: fin, accumulationMode: batch),
    );
    await pins(
      'insert accumulating L older',
      () => dao.insertMaster(
        targetId: t0,
        name: 'M31 L old',
        filter: 'L',
        status: acc,
        accumulationMode: running,
        createdAt: pinT(1),
        updatedAt: pinT(1),
      ),
    );
    await pins.dump(db, 'integrated_masters', 'after insert');

    await pins('getAll', dao.getAll);
    await pins('getById 1', () => dao.getById(1));
    await pins('getById missing', () => dao.getById(99));
    await pins('getForTarget t0', () => dao.getForTarget(t0));
    await pins('getForTarget t1', () => dao.getForTarget(seed.targets[1]));
    for (final filter in <String?>['L', ' L ', null, '', '  ', 'l', 'Ha']) {
      await pins(
        'accumulating filter=${filter == null ? 'null' : '"$filter"'}',
        () => dao.getAccumulatingForTargetFilter(targetId: t0, filter: filter),
      );
    }

    await pins(
      'updateBookkeeping some',
      () => dao.updateBookkeeping(
        2,
        masterFitsPath: '/m/n.fits',
        status: fin,
        frameCount: 3,
        totalIntegrationSeconds: 360,
      ),
    );
    await pins(
      'updateBookkeeping all',
      () => dao.updateBookkeeping(
        3,
        masterFitsPath: 'a',
        previewPngPath: 'b',
        rejectionMapPath: 'c',
        rejectionMapPreviewPath: 'd',
        coverageMapPath: 'e',
        coverageMapPreviewPath: 'f',
        status: acc,
        channels: 3,
        width: 7,
        height: 8,
        frameCount: 9,
        totalIntegrationSeconds: 10.5,
        statsJson: '{}',
      ),
    );
    await pins('updateBookkeeping none', () => dao.updateBookkeeping(5));
    await pins(
      'updateBookkeeping missing',
      () => dao.updateBookkeeping(99, width: 1),
    );
    await pins(
      'updateSmartFields some',
      () => dao.updateSmartFields(
        1,
        colorCalibratedPath: '/m/cc.fits',
        backgroundExtracted: true,
        targetSnr: 40.25,
      ),
    );
    await pins(
      'updateSmartFields all',
      () => dao.updateSmartFields(
        2,
        colorCalibratedPath: 'x',
        annotatedPreviewPath: 'y',
        backgroundExtracted: false,
        targetSnr: 1,
        targetIntegrationS: 2,
        improvementCurveJson: '[]',
      ),
    );
    await pins('updateSmartFields none', () => dao.updateSmartFields(4));
    await pins(
      'updateWcs',
      () => dao.updateWcs(
        1,
        crval1: 10.68,
        crval2: 41.27,
        crpix1: 3124,
        crpix2: 2088,
        cd1_1: -0.0002,
        cd1_2: 0.00001,
        cd2_1: -0.00001,
        cd2_2: -0.0002,
      ),
    );
    await pins(
      'updateWcs missing',
      () => dao.updateWcs(
        99,
        crval1: 0,
        crval2: 0,
        crpix1: 0,
        crpix2: 0,
        cd1_1: 0,
        cd1_2: 0,
        cd2_1: 0,
        cd2_2: 0,
      ),
    );
    await pins(
      'updateFinishingPaths some',
      () => dao.updateFinishingPaths(1, deconvolvedPath: '/m/d.fits'),
    );
    await pins(
      'updateFinishingPaths all',
      () => dao.updateFinishingPaths(
        2,
        backgroundExtractedPath: 'bgx',
        deconvolvedPath: 'dec',
        starReducedPath: 'star',
      ),
    );
    await pins('updateFinishingPaths none', () => dao.updateFinishingPaths(3));
    await pins.dump(db, 'integrated_masters', 'after updates');

    final img = seed.images;
    await pins(
      'recordFoldedFrame full',
      () => dao.recordFoldedFrame(
        masterId: 1,
        imageId: img[0],
        weight: 0.9,
        alignmentResidualPx: 0.3,
        foldedAt: pinT(20),
        snr: 15,
        fwhm: 2.5,
        eccentricity: 0.4,
      ),
    );
    await pins(
      'recordFoldedFrame rejected',
      () => dao.recordFoldedFrame(
        masterId: 1,
        imageId: img[1],
        accepted: false,
        rejectionReason: 'trail',
        foldedAt: pinT(20),
      ),
    );
    await pins(
      'recordFoldedFrame refold replaces',
      () => dao.recordFoldedFrame(
        masterId: 1,
        imageId: img[0],
        weight: 0.5,
        foldedAt: pinT(21),
      ),
    );
    await pins(
      'recordFoldedFrame master 2',
      () => dao.recordFoldedFrame(masterId: 2, imageId: img[1], foldedAt: pinT(22)),
    );
    await pins(
      'recordFoldedFrame master 3',
      () => dao.recordFoldedFrame(masterId: 3, imageId: img[2], foldedAt: pinT(22)),
    );
    await pins(
      'recordFoldedFrame master 5',
      () => dao.recordFoldedFrame(masterId: 5, imageId: img[3]),
    );
    await pins(
      'recordFoldedFrame missing master',
      () => dao.recordFoldedFrame(masterId: 99, imageId: img[3]),
    );
    await pins.dump(db, 'integrated_master_frames', 'after folds');

    await pins('getFoldedImageIds 1', () => dao.getFoldedImageIds(1));
    await pins('getFramesForMaster 1', () => dao.getFramesForMaster(1));
    await pins(
      'masterIdsForImages',
      () => dao.masterIdsForImages([img[3], img[1], img[2], img[1], 9999]),
    );
    await pins(
      'masterIdsForImages none match',
      () => dao.masterIdsForImages([9998, 9999]),
    );
    await pins(
      'masterIdsForImages over a chunk',
      () => dao.masterIdsForImages([
        for (var i = 10000; i < 10900; i++) i,
        img[0],
        img[2],
      ]),
    );

    final recipes = RecipesDao(db);
    await recipes.create(
      masterId: 2,
      baseMasterPath: '/old/path.fits',
      createdAt: pinT(30),
    );
    await recipes.create(baseMasterPath: '/m/n.fits', createdAt: pinT(30));
    await recipes.create(baseMasterPath: '/keep.fits', createdAt: pinT(30));
    await pins(
      'replaceMaster',
      () => dao.replaceMaster(
        oldId: 2,
        oldPath: '/m/n.fits',
        newId: 1,
        newPath: '/m/L.fits',
      ),
    );
    await pins(
      'replaceMaster null old path',
      () => dao.replaceMaster(
        oldId: 3,
        oldPath: null,
        newId: 1,
        newPath: '/keep.fits',
      ),
    );
    await pins.dump(db, 'recipes', 'after replace');
    await pins.dump(db, 'integrated_masters', 'after replace');
    await pins.dump(db, 'integrated_master_frames', 'after replace');
    await pins('deleteMaster 1', () => dao.deleteMaster(1));
    await pins('deleteMaster missing', () => dao.deleteMaster(1));
    await pins.dump(db, 'integrated_master_frames', 'after delete');
    pins.verify();
  });
}
