// Pins the results of the master-flat library and calibration-tag DAOs on a
// seeded database: the merge upsert's null handling and the rows each write
// leaves behind.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/calibration_tags_dao.dart';
import 'package:skotiq_core/src/database/daos/flat_library_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/calibration/calibration_library_models.dart';
import 'package:skotiq_core/src/models/imaging/integrated_master.dart';

import 'pin_harness.dart';

Object? _encode(Object value) => switch (value) {
  FlatLibraryEntry e => {
    'id': e.id,
    'filePath': e.filePath,
    'filter': e.filter,
    'equipmentProfileId': e.equipmentProfileId,
    'opticalTrainId': e.opticalTrainId,
    'temperature': e.temperature,
    'gain': e.gain,
    'offset': e.offset,
    'binX': e.binX,
    'binY': e.binY,
    'width': e.width,
    'height': e.height,
    'flatKind': e.flatKind,
    'masterFrameCount': e.masterFrameCount,
    'createdAt': e.createdAt,
  },
  CalibrationTagEntry e => {
    'id': e.id,
    'masterType': e.masterType,
    'masterId': e.masterId,
    'tags': e.tags,
    'notes': e.notes,
    'cameraId': e.cameraId,
    'updatedAt': e.updatedAt,
    'sharedBy': e.sharedBy,
    'sharedAt': e.sharedAt,
    'license': e.license,
    'provenanceJson': e.provenanceJson,
    'publishedRemoteId': e.publishedRemoteId,
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

  test('FlatLibraryDao results are pinned', () async {
    final pins = PinRecorder('flat_library_dao', encode: _encode);
    final dao = FlatLibraryDao(db);

    await pins('empty getAllEntries', dao.getAllEntries);
    await pins('empty getEntryById', () => dao.getEntryById(1));

    await pins(
      'add L cold',
      () => dao.addEntry(
        filePath: '/flats/L_cold.fits',
        filter: 'L',
        equipmentProfileId: seed.profile,
        opticalTrainId: 'train-a',
        temperature: -10,
        gain: 100,
        offset: 30,
        width: 6248,
        height: 4176,
        flatKind: 'panel',
        masterFrameCount: 30,
        createdAt: pinT(10),
      ),
    );
    await pins(
      'add L warm',
      () => dao.addEntry(
        filePath: '/flats/L_warm.fits',
        filter: 'L',
        temperature: 5,
        gain: 100,
        offset: 30,
        createdAt: pinT(20),
      ),
    );
    await pins(
      'add L no temp no train',
      () => dao.addEntry(
        filePath: '/flats/L_any.fits',
        filter: 'L',
        gain: 100,
        offset: 30,
        createdAt: pinT(15),
      ),
    );
    await pins(
      'add L other train same time',
      () => dao.addEntry(
        filePath: '/flats/L_b.fits',
        filter: 'L',
        opticalTrainId: 'train-b',
        temperature: -9,
        gain: 100,
        offset: 30,
        createdAt: pinT(10),
      ),
    );
    await pins(
      'add Ha bin2',
      () => dao.addEntry(
        filePath: '/flats/Ha_bin2.fits',
        filter: 'Ha',
        gain: 0,
        binX: 2,
        binY: 2,
        createdAt: pinT(5),
      ),
    );
    await pins(
      'add no filter',
      () => dao.addEntry(filePath: '/flats/none.fits', createdAt: pinT(1)),
    );
    await pins(
      'add default time',
      () => dao.addEntry(filePath: '/flats/now.fits', filter: 'R'),
    );
    await pins(
      're-add same path updates',
      () => dao.addEntry(
        filePath: '/flats/L_warm.fits',
        filter: 'L',
        temperature: 6.5,
        gain: 100,
        offset: 30,
        masterFrameCount: 12,
        createdAt: pinT(25),
      ),
    );
    await pins.dump(db, 'flat_library', 'after adds');

    await pins('getAllEntries', dao.getAllEntries);
    await pins('getEntryById 1', () => dao.getEntryById(1));
    await pins('getEntryById missing', () => dao.getEntryById(99));

    await pins('delete 1', () => dao.deleteEntry(1));
    await pins('delete missing', () => dao.deleteEntry(1));
    await pins.dump(db, 'flat_library', 'after delete');
    pins.verify();
  });

  test('CalibrationTagsDao results are pinned', () async {
    final pins = PinRecorder('calibration_tags_dao', encode: _encode);
    final dao = CalibrationTagsDao(db);
    const dark = CalibrationMasterType.dark;
    const flat = CalibrationMasterType.flat;

    await pins('empty getForMaster', () => dao.getForMaster(dark, 1));
    await pins('empty getAllKeyed', dao.getAllKeyed);

    await pins(
      'upsert new tags',
      () => dao.upsert(dark, 1, tags: const ['winter', 'gain100']),
    );
    await pins.dump(db, 'calibration_tags', 'after first upsert');
    await pins(
      'upsert camera keeps tags',
      () => dao.upsert(dark, 1, cameraId: 'ZWO ASI2600MM'),
    );
    await pins(
      'upsert notes',
      () => dao.upsert(dark, 1, notes: 'taken in the garage'),
    );
    await pins(
      'upsert shared',
      () => dao.upsert(
        flat,
        3,
        sharedBy: 'someone',
        sharedAt: pinT(40),
        license: 'CC-BY-4.0',
        provenanceJson: '{"rig":"x"}',
        publishedRemoteId: 'hub-7',
      ),
    );
    await pins(
      'upsert clear notes and remote id',
      () => dao.upsert(dark, 1, clearNotes: true, clearPublishedRemoteId: true),
    );
    await pins(
      'upsert clear remote id on shared',
      () => dao.upsert(flat, 3, clearPublishedRemoteId: true, tags: const []),
    );
    await pins(
      'upsert defect map',
      () => dao.upsert(CalibrationMasterType.defectMap, 1, notes: 'hot'),
    );
    await pins.dump(db, 'calibration_tags', 'after upserts');

    await pins('getForMaster dark 1', () => dao.getForMaster(dark, 1));
    await pins('getForMaster flat 3', () => dao.getForMaster(flat, 3));
    await pins('getForMaster other type', () => dao.getForMaster(flat, 1));

    await db.customStatement(
      "INSERT INTO calibration_tags (master_type, master_id, tags_json, "
      "updated_at) VALUES ('future-kind', 5, '[]', 1740866400)",
    );
    await db.customStatement(
      "INSERT INTO calibration_tags (master_type, master_id, tags_json, "
      "updated_at) VALUES ('bias', 6, '{\"not\":\"a list\"}', 1740866400)",
    );
    await db.customStatement(
      "INSERT INTO calibration_tags (master_type, master_id, tags_json, "
      "updated_at) VALUES ('bias', 7, 'broken', 1740866400)",
    );
    await pins('getAllKeyed', dao.getAllKeyed);
    await pins(
      'getForMaster unknown type row',
      () => dao.getForMaster(CalibrationMasterType.bias, 6),
    );
    await pins(
      'getForMaster bad json',
      () => dao.getForMaster(CalibrationMasterType.bias, 7),
    );

    await pins('deleteForMaster', () => dao.deleteForMaster(dark, 1));
    await pins('deleteForMaster missing', () => dao.deleteForMaster(dark, 1));
    await pins.dump(db, 'calibration_tags', 'after delete');
    pins.verify();
  });
}
