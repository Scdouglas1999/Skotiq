// Migration test for the v63 -> v64 step: profiles name the built-in
// guider's guide camera, and simulator rigs guided by the built-in guider get
// the simulator's guide camera.
//
// A v63 database is simulated by writing the rows and rewinding
// `PRAGMA user_version = 63`; reopening runs onUpgrade(63, 64).

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';

void main() {
  group('migration onUpgrade v63 -> v64 (guide camera)', () {
    late File dbFile;

    setUp(() async {
      final dir = await Directory.systemTemp.createTemp('skotiq_v63_v64_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      dbFile = File('${dir.path}/skotiq.db');
    });

    Future<void> writeV63() async {
      final setup = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        const insert =
            'INSERT INTO equipment_profiles (id, name, camera_id, guider_id) '
            'VALUES (?, ?, ?, ?)';
        await setup.customStatement(insert, [
          1,
          'Sim Rig',
          'sim_camera_1',
          kBuiltinGuiderId,
        ]);
        await setup.customStatement(insert, [
          2,
          'Sim with PHD2',
          'sim_camera_1',
          'phd2',
        ]);
        await setup.customStatement(insert, [
          3,
          'Real rig',
          'native:zwo:0',
          kBuiltinGuiderId,
        ]);
        await setup.customStatement('PRAGMA user_version = 63');
      } finally {
        await setup.close();
      }
    }

    test('only simulator rigs on the built-in guider get the sim guide '
        'camera', () async {
      await writeV63();
      final db = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(db.close);
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.data['user_version'], 64);
      final rows = await db
          .customSelect(
            'SELECT id, guide_camera_id, guide_camera_name, '
            'guide_focal_length FROM equipment_profiles ORDER BY id',
          )
          .get();
      final byId = {
        for (final r in rows)
          r.read<int>('id'): (
            r.readNullable<String>('guide_camera_id'),
            r.readNullable<String>('guide_camera_name'),
            r.readNullable<double>('guide_focal_length'),
          ),
      };
      expect(byId[1], (
        kSimGuideCameraId,
        'Simulated Guide Camera',
        kSimGuideFocalLengthMm,
      ));
      expect(byId[2], (null, null, null));
      expect(byId[3], (null, null, null));
    });

    test('a guide camera the user already chose is kept', () async {
      await writeV63();
      final setup = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      await setup.customStatement(
        "UPDATE equipment_profiles SET guide_camera_id = 'native:zwo:1', "
        'guide_focal_length = 200 WHERE id = 1',
      );
      await setup.customStatement('PRAGMA user_version = 63');
      await setup.close();

      final db = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(db.close);
      final row = await db
          .customSelect(
            'SELECT guide_camera_id, guide_focal_length '
            'FROM equipment_profiles WHERE id = 1',
          )
          .getSingle();
      expect(row.read<String>('guide_camera_id'), 'native:zwo:1');
      expect(row.read<double>('guide_focal_length'), 200);
    });

    test('the onboarding rule matches the migration rule', () {
      expect(
        usesSimulatedGuideCamera(
          cameraId: 'sim_camera_1',
          guiderId: kBuiltinGuiderId,
        ),
        isTrue,
      );
      expect(
        usesSimulatedGuideCamera(cameraId: 'sim_camera_1', guiderId: 'phd2'),
        isFalse,
      );
      expect(
        usesSimulatedGuideCamera(
          cameraId: 'native:zwo:0',
          guiderId: kBuiltinGuiderId,
        ),
        isFalse,
      );
    });
  });
}
