import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

import 'post_session_integration_service_test.dart' show FakePostSessionSeam;

/// Master accumulation ([MasterAccumulationService.addNight]) and the Darkroom
/// ([CalibrationLibraryService.match]) answer "which flat" from one rule.
void main() {
  late SkotiqDatabase db;
  late FlatLibraryDao flatDao;
  late FakePostSessionSeam seam;
  late MasterAccumulationService accumulation;
  late CalibrationLibraryService darkroom;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    flatDao = FlatLibraryDao(db);
    seam = FakePostSessionSeam();
    accumulation = MasterAccumulationService(
      mastersDao: IntegratedMastersDao(db),
      darkLibrary: DarkLibraryService(DarkLibraryDao(db)),
      flatLibrary: FlatLibraryService(dao: flatDao, seam: seam),
      seam: seam,
    );
    darkroom = CalibrationLibraryService(
      db: db,
      flatLibraryDao: flatDao,
      tagsDao: CalibrationTagsDao(db),
    );
  });

  tearDown(() => db.close());

  const result = MasterAccumulateResult(
    sidecarPath: '/m/m.skmaster',
    masterPath: null,
    previewPath: null,
    frameCount: 0,
    totalIntegrationSec: 0,
    width: 100,
    height: 80,
    channels: 1,
    framesAdded: 0,
    rejected: 0,
  );

  Future<DbCapturedImage> insertSub(String path, {int? gain}) async {
    final id = await db
        .into(db.capturedImages)
        .insert(
          CapturedImagesCompanion.insert(
            filePath: path,
            fileName: path.split('/').last,
            frameType: const Value('light'),
            exposureDuration: 180,
            capturedAt: DateTime(2026, 6, 7, 22),
            gain: Value(gain),
            offset: const Value(10),
            filter: const Value('L'),
            sensorTemp: const Value(-10.0),
            isAccepted: const Value(true),
          ),
        );
    return (await db.imagesDao.getImageById(id))!;
  }

  /// The flat master accumulation hands the native fold for [sub].
  Future<String?> accumulationPick(DbCapturedImage sub) async {
    seam.scriptedAccumulate['create'] = [result];
    seam.scriptedAccumulate['add'] = [result];
    final masterId = await accumulation.createMaster(
      referenceSub: sub,
      sidecarPath: '/m/m.skmaster',
      targetName: 'M51',
      filter: 'L',
    );
    await accumulation.addNight(masterId: masterId, subs: [sub], label: 'n1');
    final add = seam.accumulateCalls.lastWhere((c) => c['op'] == 'add');
    return (add['calibration'] as Map<String, dynamic>)['flat'] as String?;
  }

  Future<String?> darkroomPick(DbCapturedImage sub) async =>
      (await darkroom.match(
        LightFrameContext(
          gain: sub.gain,
          offset: sub.offset,
          exposureSeconds: sub.exposureDuration,
          temperature: sub.sensorTemp,
          filter: sub.filter,
        ),
        includeRemote: false,
      )).flat?.record.filePath;

  test(
    'the newest flat within the temperature tolerance wins in both',
    () async {
      await flatDao.addEntry(
        filePath: '/flats/L_old_exact.fits',
        filter: 'L',
        gain: 100,
        offset: 10,
        temperature: -10,
        createdAt: DateTime.utc(2026, 6, 1),
      );
      await flatDao.addEntry(
        filePath: '/flats/L_new_warmer.fits',
        filter: 'L',
        gain: 100,
        offset: 10,
        temperature: -7,
        createdAt: DateTime.utc(2026, 6, 6),
      );
      final sub = await insertSub('/n1/a.fits', gain: 100);

      final darkroomPath = await darkroomPick(sub);
      expect(darkroomPath, '/flats/L_new_warmer.fits');
      expect(await accumulationPick(sub), darkroomPath);
    },
  );

  test('lights that record no gain draw the same flat from both', () async {
    await flatDao.addEntry(
      filePath: '/flats/L_gain100.fits',
      filter: 'L',
      gain: 100,
      offset: 10,
      temperature: -10,
    );
    final sub = await insertSub('/n1/a.fits');

    final darkroomPath = await darkroomPick(sub);
    expect(darkroomPath, '/flats/L_gain100.fits');
    expect(await accumulationPick(sub), darkroomPath);
  });

  test(
    'a flat outside the temperature tolerance is the pick of both',
    () async {
      await flatDao.addEntry(
        filePath: '/flats/L_warm.fits',
        filter: 'L',
        gain: 100,
        offset: 10,
        temperature: 5,
      );
      final sub = await insertSub('/n1/a.fits', gain: 100);

      final darkroomPath = await darkroomPick(sub);
      expect(darkroomPath, '/flats/L_warm.fits');
      expect(await accumulationPick(sub), darkroomPath);
    },
  );
}
