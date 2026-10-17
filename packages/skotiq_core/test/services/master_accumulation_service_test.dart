import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/src/database/daos/dark_library_dao.dart';
import 'package:skotiq_core/src/database/daos/flat_library_dao.dart';
import 'package:skotiq_core/src/database/daos/images_dao.dart';
import 'package:skotiq_core/src/database/daos/integrated_masters_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/imaging/integrated_master.dart';
import 'package:skotiq_core/src/services/dark_library_service.dart';
import 'package:skotiq_core/src/services/flat_library_service.dart';
import 'package:skotiq_core/src/services/master_accumulation_service.dart';
import 'package:skotiq_core/src/services/post_session_seam.dart';

import 'post_session_integration_service_test.dart' show FakePostSessionSeam;

void main() {
  late SkotiqDatabase db;
  late ImagesDao imagesDao;
  late IntegratedMastersDao mastersDao;
  late FakePostSessionSeam seam;
  late MasterAccumulationService service;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    imagesDao = db.imagesDao;
    mastersDao = IntegratedMastersDao(db);
    seam = FakePostSessionSeam();
    service = MasterAccumulationService(
      mastersDao: mastersDao,
      darkLibrary: DarkLibraryService(DarkLibraryDao(db)),
      flatLibrary: FlatLibraryService(dao: FlatLibraryDao(db), seam: seam),
      seam: seam,
    );
  });

  tearDown(() async {
    await db.close();
  });

  Future<CapturedImage> insertSub(String path, {String filter = 'L'}) async {
    final id = await db
        .into(db.capturedImages)
        .insert(
          CapturedImagesCompanion.insert(
            filePath: path,
            fileName: path.split('/').last,
            frameType: const Value('light'),
            exposureDuration: 180.0,
            capturedAt: DateTime(2026, 6, 7, 22),
            gain: const Value(100),
            offset: const Value(10),
            filter: Value(filter),
            sensorTemp: const Value(-10.0),
            isAccepted: const Value(true),
          ),
        );
    return (await imagesDao.getImageById(id))!;
  }

  test(
    'createMaster inserts an accumulating, runningWeightedMean row',
    () async {
      final ref = await insertSub('/n1/ref.fits');
      seam.scriptedAccumulate['create'] = [
        const MasterAccumulateResult(
          sidecarPath: '/m/m51.skmaster',
          masterPath: null,
          previewPath: null,
          frameCount: 0,
          totalIntegrationSec: 0.0,
          width: 100,
          height: 80,
          channels: 1,
          framesAdded: 0,
          rejected: 0,
        ),
      ];

      final id = await service.createMaster(
        referenceSub: ref,
        sidecarPath: '/m/m51.skmaster',
        targetName: 'M51',
        filter: 'L',
      );

      final master = await mastersDao.getById(id);
      expect(master, isNotNull);
      expect(master!.status, IntegratedMasterStatus.accumulating);
      expect(master.accumulationMode, AccumulationMode.runningWeightedMean);
      expect(master.sidecarPath, '/m/m51.skmaster');
      expect(master.filter, 'L');
      expect(master.name, 'M51 · L');

      // The create call carried the online clip + the reference path.
      final call = seam.accumulateCalls.single;
      expect(call['op'], 'create');
      expect(call['referencePath'], '/n1/ref.fits');
      final settings = call['settings'] as Map<String, dynamic>;
      expect(settings['onlineClipLow'], 4.0);
      expect(settings['onlineClipHigh'], 4.0);
    },
  );

  test('addNight folds subs, records them, and bumps running totals', () async {
    final ref = await insertSub('/n1/ref.fits');
    seam.scriptedAccumulate['create'] = [
      const MasterAccumulateResult(
        sidecarPath: '/m/m.skmaster',
        masterPath: null,
        previewPath: null,
        frameCount: 0,
        totalIntegrationSec: 0.0,
        width: 100,
        height: 80,
        channels: 1,
        framesAdded: 0,
        rejected: 0,
      ),
    ];
    final masterId = await service.createMaster(
      referenceSub: ref,
      sidecarPath: '/m/m.skmaster',
      targetName: 'M51',
      filter: 'L',
    );

    final night1 = [
      await insertSub('/n1/a.fits'),
      await insertSub('/n1/b.fits'),
    ];
    seam.scriptedAccumulate['add'] = [
      const MasterAccumulateResult(
        sidecarPath: '/m/m.skmaster',
        masterPath: null,
        previewPath: null,
        frameCount: 2,
        totalIntegrationSec: 360.0,
        width: 100,
        height: 80,
        channels: 1,
        framesAdded: 2,
        rejected: 5,
        // Native per-frame weights, in lightPaths order (= fresh-subs order).
        frameWeights: [0.8, 1.0],
      ),
    ];

    final result = await service.addNight(
      masterId: masterId,
      subs: night1,
      label: '2026-06-07',
    );
    expect(result.framesAdded, 2);

    final master = await mastersDao.getById(masterId);
    expect(master!.frameCount, 2);
    expect(master.totalIntegrationSeconds, 360.0);

    final folded = await mastersDao.getFoldedImageIds(masterId);
    expect(folded, night1.map((s) => s.id).toSet());

    // The native per-frame weights were persisted onto the fold records (not
    // nulled) so the multi-night growth/best-night intelligence has real data.
    final frames = await mastersDao.getFramesForMaster(masterId);
    final weightById = {for (final f in frames) f.imageId: f.weight};
    expect(weightById[night1[0].id], 0.8);
    expect(weightById[night1[1].id], 1.0);

    // The add call carried only the new lights + a label.
    final addCall = seam.accumulateCalls.firstWhere((c) => c['op'] == 'add');
    expect(
      (addCall['lightPaths'] as List).cast<String>(),
      containsAll(['/n1/a.fits', '/n1/b.fits']),
    );
    expect(addCall['label'], '2026-06-07');
  });

  test('addNight dedups subs already folded (idempotent re-add)', () async {
    final ref = await insertSub('/n1/ref.fits');
    seam.scriptedAccumulate['create'] = [
      const MasterAccumulateResult(
        sidecarPath: '/m/m.skmaster',
        masterPath: null,
        previewPath: null,
        frameCount: 0,
        totalIntegrationSec: 0.0,
        width: 100,
        height: 80,
        channels: 1,
        framesAdded: 0,
        rejected: 0,
      ),
    ];
    final masterId = await service.createMaster(
      referenceSub: ref,
      sidecarPath: '/m/m.skmaster',
    );

    final a = await insertSub('/n1/a.fits');
    final b = await insertSub('/n1/b.fits');

    seam.scriptedAccumulate['add'] = [
      const MasterAccumulateResult(
        sidecarPath: '/m/m.skmaster',
        masterPath: null,
        previewPath: null,
        frameCount: 2,
        totalIntegrationSec: 360.0,
        width: 100,
        height: 80,
        channels: 1,
        framesAdded: 2,
        rejected: 0,
      ),
    ];
    await service.addNight(masterId: masterId, subs: [a, b], label: 'night-1');

    // Re-add [a, b, c] — only c is new.
    final c = await insertSub('/n2/c.fits');
    seam.scriptedAccumulate['add'] = [
      const MasterAccumulateResult(
        sidecarPath: '/m/m.skmaster',
        masterPath: null,
        previewPath: null,
        frameCount: 3,
        totalIntegrationSec: 540.0,
        width: 100,
        height: 80,
        channels: 1,
        framesAdded: 1,
        rejected: 0,
      ),
    ];
    await service.addNight(
      masterId: masterId,
      subs: [a, b, c],
      label: 'night-2',
    );

    // Only the new sub went to the seam on the second add.
    final addCalls = seam.accumulateCalls
        .where((c) => c['op'] == 'add')
        .toList();
    expect(addCalls, hasLength(2));
    expect((addCalls[1]['lightPaths'] as List).cast<String>(), ['/n2/c.fits']);

    // All three subs are folded exactly once.
    final folded = await mastersDao.getFoldedImageIds(masterId);
    expect(folded, {a.id, b.id, c.id});
  });

  test(
    'addNight with only already-folded subs touches the sidecar via info',
    () async {
      final ref = await insertSub('/n1/ref.fits');
      seam.scriptedAccumulate['create'] = [
        const MasterAccumulateResult(
          sidecarPath: '/m/m.skmaster',
          masterPath: null,
          previewPath: null,
          frameCount: 0,
          totalIntegrationSec: 0.0,
          width: 100,
          height: 80,
          channels: 1,
          framesAdded: 0,
          rejected: 0,
        ),
      ];
      final masterId = await service.createMaster(
        referenceSub: ref,
        sidecarPath: '/m/m.skmaster',
      );
      final a = await insertSub('/n1/a.fits');
      seam.scriptedAccumulate['add'] = [
        const MasterAccumulateResult(
          sidecarPath: '/m/m.skmaster',
          masterPath: null,
          previewPath: null,
          frameCount: 1,
          totalIntegrationSec: 180.0,
          width: 100,
          height: 80,
          channels: 1,
          framesAdded: 1,
          rejected: 0,
        ),
      ];
      await service.addNight(masterId: masterId, subs: [a], label: 'n1');

      // Re-add the same sub — nothing new ⇒ an `info` op, no `add`.
      final result = await service.addNight(
        masterId: masterId,
        subs: [a],
        label: 'n1',
      );
      expect(result.framesAdded, 0);
      final ops = seam.accumulateCalls.map((c) => c['op']).toList();
      expect(ops.where((o) => o == 'add').length, 1);
      expect(ops.contains('info'), isTrue);
    },
  );

  test(
    'finalizeMaster writes the FITS path and flips status to finalized',
    () async {
      final ref = await insertSub('/n1/ref.fits');
      seam.scriptedAccumulate['create'] = [
        const MasterAccumulateResult(
          sidecarPath: '/m/m.skmaster',
          masterPath: null,
          previewPath: null,
          frameCount: 0,
          totalIntegrationSec: 0.0,
          width: 100,
          height: 80,
          channels: 1,
          framesAdded: 0,
          rejected: 0,
        ),
      ];
      final masterId = await service.createMaster(
        referenceSub: ref,
        sidecarPath: '/m/m.skmaster',
      );

      seam.scriptedAccumulate['finalize'] = [
        const MasterAccumulateResult(
          sidecarPath: '/m/m.skmaster',
          masterPath: '/m/m_master.fits',
          previewPath: '/m/m_master.png',
          frameCount: 12,
          totalIntegrationSec: 2160.0,
          width: 100,
          height: 80,
          channels: 1,
          framesAdded: 0,
          rejected: 0,
        ),
      ];

      await service.finalizeMaster(
        masterId: masterId,
        masterFitsPath: '/m/m_master.fits',
        previewPngPath: '/m/m_master.png',
      );

      final master = await mastersDao.getById(masterId);
      expect(master!.status, IntegratedMasterStatus.finalized);
      expect(master.masterFitsPath, '/m/m_master.fits');
      expect(master.previewPngPath, '/m/m_master.png');
      expect(master.frameCount, 12);
      expect(master.totalIntegrationSeconds, 2160.0);
    },
  );

  test('addNight on a missing master is a hard error', () async {
    final a = await insertSub('/n1/a.fits');
    expect(
      () => service.addNight(masterId: 9999, subs: [a], label: 'x'),
      throwsStateError,
    );
  });

  group('a retired accumulator', () {
    late Directory dir;
    late String sidecarPath;
    late _RetiringSeam retiringSeam;
    late MasterAccumulationService retiringService;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('sk_master_retired');
      sidecarPath = p.join(dir.path, 'm51.skmaster');
      File(sidecarPath).writeAsStringSync('v1 accumulator state');
      File('$sidecarPath.calib.json').writeAsStringSync('{"folds":[]}');
      retiringSeam = _RetiringSeam(sidecarPath);
      retiringService = MasterAccumulationService(
        mastersDao: mastersDao,
        darkLibrary: DarkLibraryService(DarkLibraryDao(db)),
        flatLibrary: FlatLibraryService(dao: FlatLibraryDao(db), seam: seam),
        seam: retiringSeam,
      );
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    Future<int> seedMaster() async {
      final ref = await insertSub('${dir.path}/ref.fits');
      return retiringService.createMaster(
        referenceSub: ref,
        sidecarPath: sidecarPath,
        targetName: 'M51',
        filter: 'L',
      );
    }

    test('is archived aside and the night lands in a new master', () async {
      final retiredId = await seedMaster();
      final night = [
        await insertSub('${dir.path}/a.fits'),
        await insertSub('${dir.path}/b.fits'),
      ];

      final result = await retiringService.addNight(
        masterId: retiredId,
        subs: night,
        label: '2026-08-16',
      );

      // The night was folded, not lost.
      expect(result.framesAdded, 2);

      // The retired state was moved aside, never deleted — it is the only
      // record of how those earlier nights were accumulated.
      expect(File(sidecarPath).existsSync(), isFalse);
      expect(
        File('$sidecarPath$kSupersededSidecarSuffix').existsSync(),
        isTrue,
      );
      expect(
        File('$sidecarPath.calib.json$kSupersededSidecarSuffix').existsSync(),
        isTrue,
      );

      final notice = retiringService.lastRestart;
      expect(notice, isNotNull);
      expect(notice!.retiredMasterId, retiredId);
      expect(notice.newMasterId, isNot(retiredId));
      expect(notice.reason, contains(kRetiredMasterSidecarMarker));

      // The new master carries the operator's target and filter, holds this
      // night's subs, and has its own sidecar.
      final fresh = await mastersDao.getById(notice.newMasterId);
      expect(fresh, isNotNull);
      expect(fresh!.name, 'M51 · L');
      expect(fresh.filter, 'L');
      expect(fresh.status, IntegratedMasterStatus.accumulating);
      expect(fresh.sidecarPath, isNot(sidecarPath));
      expect(
        await mastersDao.getFoldedImageIds(notice.newMasterId),
        night.map((s) => s.id).toSet(),
      );

      // Every sub of every earlier night is selectable again, because the new
      // master has no fold records of its own beyond tonight's.
      final retiredRow = await mastersDao.getById(retiredId);
      expect(
        retiredRow,
        isNotNull,
        reason: 'what the retired master recorded did happen; it is kept',
      );
    });

    test('is never superseded twice', () async {
      final retiredId = await seedMaster();
      final night = [await insertSub('${dir.path}/a.fits')];
      await retiringService.addNight(
        masterId: retiredId,
        subs: night,
        label: '2026-08-16',
      );
      final mastersAfterFirst = (await mastersDao.getAll()).length;

      // The operator presses the same button again on the same (retired)
      // master. It must say where the state went, not start a third master.
      await expectLater(
        retiringService.addNight(
          masterId: retiredId,
          subs: [await insertSub('${dir.path}/c.fits')],
          label: '2026-08-17',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains(kSupersededSidecarSuffix),
              contains(kRetiredMasterSidecarMarker),
            ),
          ),
        ),
      );
      expect((await mastersDao.getAll()).length, mastersAfterFirst);
    });
  });
}

/// A seam whose `add` refuses the retired sidecar exactly the way the native
/// side does — the marker clause `masters.rs` writes.
class _RetiringSeam extends FakePostSessionSeam {
  _RetiringSeam(this.retiredSidecar);

  final String retiredSidecar;

  @override
  Future<MasterAccumulateResult> masterAccumulate(
    Map<String, dynamic> args,
  ) async {
    if (args['op'] == 'add' && args['sidecarPath'] == retiredSidecar) {
      throw StateError(
        "this accumulating master's $kRetiredMasterSidecarMarker: sidecar "
        'version 1 was built by an earlier Skotiq whose frame '
        'normalization was defective and erased star flux from the fold, so '
        'it cannot be extended. Start a new master — every original sub is '
        'untouched on disk and re-integrates cleanly (this build reads '
        'version 2).',
      );
    }
    return super.masterAccumulate(args);
  }
}
