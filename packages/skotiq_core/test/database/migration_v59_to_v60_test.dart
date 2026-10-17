// Migration test for the v59 -> v60 step: autofocus star selection stored as
// '0' (every star, the old seeded default) becomes '10'.
//
// A v59 database is simulated by writing the old value and rewinding
// `PRAGMA user_version = 59`; reopening runs onUpgrade(59, 60).

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';

const _key = 'af_use_brightest_n_stars';

void main() {
  group('migration onUpgrade v59 -> v60 (autofocus star selection)', () {
    late File dbFile;

    setUp(() async {
      final dir = await Directory.systemTemp.createTemp('skotiq_v59_v60_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      dbFile = File('${dir.path}/skotiq.db');
    });

    Future<void> writeV59(String? value) async {
      final setup = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        if (value == null) {
          await setup.customStatement(
            'DELETE FROM app_settings WHERE key = ?',
            [_key],
          );
        } else {
          await setup.settingsDao.setSetting(_key, value);
        }
        await setup.customStatement('PRAGMA user_version = 59');
      } finally {
        await setup.close();
      }
    }

    Future<String?> reopenAndRead() async {
      final db = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        final version = await db
            .customSelect('PRAGMA user_version')
            .getSingle();
        expect(version.data['user_version'], db.schemaVersion);
        return await db.settingsDao.getSetting(_key);
      } finally {
        await db.close();
      }
    }

    test('a stored 0 becomes the brightest 10 stars', () async {
      await writeV59('0');
      expect(await reopenAndRead(), '10');
    });

    test('any other stored count is kept', () async {
      await writeV59('25');
      expect(await reopenAndRead(), '25');
    });

    test('a database with no row is seeded with 10', () async {
      await writeV59(null);
      expect(await reopenAndRead(), '10');
    });

    test('a 0 saved after the upgrade sticks on later opens', () async {
      await writeV59('0');
      expect(await reopenAndRead(), '10');

      final operator = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      await operator.settingsDao.setSetting(_key, '0');
      await operator.close();

      expect(await reopenAndRead(), '0');
      expect(await reopenAndRead(), '0');
    });
  });
}
