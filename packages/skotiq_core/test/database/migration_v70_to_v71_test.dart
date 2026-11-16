// Migration test for the v70 -> v71 step: equipment profiles gain the
// default camera read mode, and existing profiles state none. A v70 database
// is simulated by dropping the column and rewinding `PRAGMA user_version`.

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';

void main() {
  test(
    'migration v70 -> v71 keeps every profile and states no read mode',
    () async {
      final dir = await Directory.systemTemp.createTemp('skotiq_v70_v71_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/skotiq.db');
      final setup = SkotiqDatabase.forTesting(NativeDatabase(file));
      await setup.customStatement(
        'INSERT INTO equipment_profiles (id, name, camera_id, default_gain, '
        'default_offset) VALUES (3, ?, ?, 120, 30)',
        ['NYX rig', 'native:zwo:0'],
      );
      await setup.customStatement(
        'ALTER TABLE equipment_profiles DROP COLUMN default_readout_mode',
      );
      await setup.customStatement('PRAGMA user_version = 70');
      await setup.close();

      final db = SkotiqDatabase.forTesting(NativeDatabase(file));
      addTearDown(db.close);
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.data['user_version'], db.schemaVersion);

      final profile = await (db.select(
        db.equipmentProfiles,
      )..where((p) => p.id.equals(3))).getSingle();
      expect(profile.name, 'NYX rig');
      expect(profile.cameraId, 'native:zwo:0');
      expect((profile.defaultGain, profile.defaultOffset), (120, 30));
      expect(profile.defaultReadoutMode, isNull);

      await (db.update(
        db.equipmentProfiles,
      )..where((p) => p.id.equals(3))).write(
        const EquipmentProfilesCompanion(
          defaultReadoutMode: Value('High speed'),
        ),
      );
      final stated = await (db.select(
        db.equipmentProfiles,
      )..where((p) => p.id.equals(3))).getSingle();
      expect(stated.defaultReadoutMode, 'High speed');
    },
  );
}
