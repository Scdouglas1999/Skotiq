// Migration test for the v65 -> v66 step: frames say what their gain number
// is, and the gPhoto2 frames that recorded an ISO-list position are marked.
//
// A v65 database is simulated by writing the rows and rewinding
// `PRAGMA user_version = 65`; reopening runs onUpgrade(65, 66).

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';

void main() {
  group('migration onUpgrade v65 -> v66 (gain kind)', () {
    late File dbFile;

    setUp(() async {
      final dir = await Directory.systemTemp.createTemp('skotiq_v65_v66_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      dbFile = File('${dir.path}/skotiq.db');
    });

    Future<void> writeV65() async {
      final setup = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        const profile =
            'INSERT INTO equipment_profiles (id, name, camera_id) VALUES (?, ?, ?)';
        await setup.customStatement(profile, [1, 'DSLR', 'native:gphoto2:0:x:Canon EOS 6D']);
        await setup.customStatement(profile, [2, 'Astro', 'native:zwo:0']);
        const session =
            'INSERT INTO imaging_sessions (id, profile_id, start_time) VALUES (?, ?, ?)';
        await setup.customStatement(session, [10, 1, 1700000000]);
        await setup.customStatement(session, [20, 2, 1700000000]);
        const frame =
            'INSERT INTO captured_images (id, file_path, file_name, session_id, '
            'exposure_duration, gain, captured_at) VALUES (?, ?, ?, ?, ?, ?, ?)';
        // DSLR frames: an ISO-list position and no gain at all.
        await setup.customStatement(frame, [1, '/a.fits', 'a.fits', 10, 60.0, 7, 1700000000]);
        await setup.customStatement(frame, [2, '/b.fits', 'b.fits', 10, 60.0, null, 1700000000]);
        // An astronomy camera's small gain is a gain.
        await setup.customStatement(frame, [3, '/c.fits', 'c.fits', 20, 60.0, 7, 1700000000]);
        // A frame of no session cannot be told apart and is left alone.
        await setup.customStatement(frame, [4, '/d.fits', 'd.fits', null, 60.0, 7, 1700000000]);
        await setup.customStatement('PRAGMA user_version = 65');
      } finally {
        await setup.close();
      }
    }

    test('only gPhoto2 frames with a small gain read as an ISO-list position', () async {
      await writeV65();
      final db = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      addTearDown(db.close);
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.data['user_version'], db.schemaVersion);
      final rows = await db
          .customSelect('SELECT id, gain, gain_kind FROM captured_images ORDER BY id')
          .get();
      expect(
        {for (final r in rows) r.read<int>('id'): r.readNullable<String>('gain_kind')},
        {1: 'isoListPosition', 2: null, 3: null, 4: null},
      );
      // The recorded number itself is never rewritten.
      expect(rows.first.read<int>('gain'), 7);
    });
  });
}
