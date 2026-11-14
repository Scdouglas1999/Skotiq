// Migration test for the v68 -> v69 step: every frame names its type in the
// one record spelling. Rows written before said "Light" (the owner's database
// has some), "darkFlat" or "dark_flat"; nothing reads those any more.
//
// A v68 database is simulated by writing the rows and rewinding
// `PRAGMA user_version = 68`; reopening runs onUpgrade(68, 69).

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';

void main() {
  test(
    'migration v68 -> v69 writes every frame type in the record spelling',
    () async {
      final dir = await Directory.systemTemp.createTemp('skotiq_v68_v69_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/skotiq.db');
      final setup = SkotiqDatabase.forTesting(NativeDatabase(file));
      const frame =
          'INSERT INTO captured_images (id, file_path, file_name, frame_type, '
          'exposure_duration, captured_at) VALUES (?, ?, ?, ?, ?, ?)';
      final spellings = [
        'light',
        'Light',
        'darkFlat',
        'dark_flat',
        'DARK',
        'lights',
      ];
      for (final (i, spelling) in spellings.indexed) {
        await setup.customStatement(frame, [
          i + 1,
          '/$i.fits',
          '$i.fits',
          spelling,
          60.0,
          1700000000,
        ]);
      }
      await setup.customStatement('PRAGMA user_version = 68');
      await setup.close();

      final db = SkotiqDatabase.forTesting(NativeDatabase(file));
      addTearDown(db.close);
      final version = await db.customSelect('PRAGMA user_version').getSingle();
      expect(version.data['user_version'], db.schemaVersion);
      final rows = await db
          .customSelect('SELECT frame_type FROM captured_images ORDER BY id')
          .get();
      expect(rows.map((r) => r.read<String>('frame_type')), [
        'light',
        'light',
        'darkflat',
        'darkflat',
        'dark',
        // Not a frame type: left as it was.
        'lights',
      ]);
    },
  );
}
