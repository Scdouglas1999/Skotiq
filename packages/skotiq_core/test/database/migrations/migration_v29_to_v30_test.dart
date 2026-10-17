// Stepped migration test for the v29 -> v30 step on guide_rms_history:
// exposure_seconds becomes NULL-able, the missing idx_guide_rms_mount_recent
// index is created, and existing rows survive the table recreate.
//
// Same pattern as migration_v28_to_v29_test.dart:
//   1. Open a fresh DB at v30 via onCreate.
//   2. Drop the v30-specific guide_rms_history shape, recreate the v29
//      shape (NOT NULL exposure_seconds, no helper index), seed it with
//      a row that exercises the data-preservation invariant, rewind
//      PRAGMA user_version to 29, close.
//   3. Reopen — triggers onUpgrade(29, 30) which runs the recreate-with-
//      nullable-column block in database.dart.
//   4. Assert via sqlite_master + PRAGMA table_info that the schema
//      changed shape, AND verify the seeded row survived — that is what
//      catches a migration that drops user data.
//
// `package:drift/drift.dart` is deliberately not imported wholesale, to avoid
// the `isNull` symbol collision with flutter_test; the companions and
// `SkotiqDatabase` come through `database.dart`.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';

void main() {
  group('stepped migration onUpgrade v29 -> v30 (guide_rms_history)', () {
    /// Creates a fresh on-disk database file, opens it at v30 so the full
    /// Drift schema lands, then mutates `guide_rms_history` to look like
    /// the pre-v30 (v29) shape:
    ///   * `exposure_seconds REAL NOT NULL`
    ///   * no `idx_guide_rms_mount_recent` helper index
    /// Rewinds `PRAGMA user_version = 29` so the next open triggers
    /// `onUpgrade(29, 30)`. Optionally seeds [seedRows] before closing,
    /// so the data-preservation assertion can read them back after the
    /// upgrade.
    Future<File> createV29Database(
      Directory dir, {
      List<Map<String, Object>> seedRows = const <Map<String, Object>>[],
    }) async {
      final dbFile = File('${dir.path}/skotiq.db');
      final setupDb = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        // Replace the v30 table with the v29 shape. SQLite doesn't have
        // ALTER COLUMN, so we do the same rename-create-copy-drop dance
        // the production migration uses — just in the opposite direction.
        await setupDb.customStatement(
          'DROP INDEX IF EXISTS idx_guide_rms_mount_recent',
        );
        await setupDb.customStatement(
          'ALTER TABLE guide_rms_history RENAME TO guide_rms_history_v30',
        );
        await setupDb.customStatement(
          'CREATE TABLE guide_rms_history ('
          'id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, '
          'session_id TEXT NOT NULL, '
          'mount_id TEXT NOT NULL, '
          'target_id INTEGER NULL, '
          'total_rms_arcsec REAL NOT NULL, '
          'sample_count INTEGER NOT NULL, '
          'exposure_seconds REAL NOT NULL, '
          'recorded_at INTEGER NOT NULL'
          ')',
        );
        await setupDb.customStatement('DROP TABLE guide_rms_history_v30');

        for (final row in seedRows) {
          await setupDb.customStatement(
            'INSERT INTO guide_rms_history '
            '(session_id, mount_id, target_id, total_rms_arcsec, '
            'sample_count, exposure_seconds, recorded_at) '
            'VALUES (?, ?, ?, ?, ?, ?, ?)',
            <Object?>[
              row['session_id'],
              row['mount_id'],
              row['target_id'],
              row['total_rms_arcsec'],
              row['sample_count'],
              row['exposure_seconds'],
              row['recorded_at'],
            ],
          );
        }

        await setupDb.customStatement('PRAGMA user_version = 29');
      } finally {
        await setupDb.close();
      }
      return dbFile;
    }

    test('exposure_seconds becomes nullable after upgrade', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v29_v30_nullable_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      final dbFile = await createV29Database(tempDir);

      final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        final info = await upgraded
            .customSelect("PRAGMA table_info('guide_rms_history')")
            .get();
        final exposureRow = info.firstWhere(
          (r) => r.data['name'] == 'exposure_seconds',
          orElse: () => throw StateError(
            'exposure_seconds column missing from guide_rms_history after '
            'v29 -> v30 upgrade',
          ),
        );
        expect(
          exposureRow.data['notnull'],
          equals(0),
          reason:
              'exposure_seconds must be nullable after v30 upgrade '
              '(I4 fix). Got notnull=${exposureRow.data['notnull']}.',
        );
      } finally {
        await upgraded.close();
      }
    });

    test('idx_guide_rms_mount_recent is created during upgrade', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v29_v30_index_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      final dbFile = await createV29Database(tempDir);

      final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        final rows = await upgraded
            .customSelect(
              "SELECT name FROM sqlite_master "
              "WHERE type='index' AND name='idx_guide_rms_mount_recent'",
            )
            .get();
        expect(
          rows,
          hasLength(1),
          reason:
              'idx_guide_rms_mount_recent must exist after v30 '
              'upgrade. The DAO advertises the index as the hot path; '
              'without it recentForMount() degrades to a table scan.',
        );
      } finally {
        await upgraded.close();
      }
    });

    test(
      'preserves existing guide_rms_history rows through the recreate',
      () async {
        // Seed a representative v29 row. The recreate-with-nullable-column
        // migration copies every column verbatim, so the row must round-trip
        // unchanged — including the (previously mandatory) exposure_seconds
        // value.
        final recordedAtUnix =
            DateTime.utc(2026, 5, 17, 21, 30).millisecondsSinceEpoch ~/ 1000;
        final tempDir = await Directory.systemTemp.createTemp(
          'skotiq_v29_v30_preserve_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });
        final dbFile = await createV29Database(
          tempDir,
          seedRows: <Map<String, Object>>[
            <String, Object>{
              'session_id': 'seed-session',
              'mount_id': 'eq6r-pro',
              'target_id': 42,
              'total_rms_arcsec': 0.83,
              'sample_count': 312,
              'exposure_seconds': 90.0,
              'recorded_at': recordedAtUnix,
            },
          ],
        );

        final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
        try {
          final rows = await upgraded
              .customSelect(
                'SELECT session_id, mount_id, target_id, total_rms_arcsec, '
                'sample_count, exposure_seconds, recorded_at '
                'FROM guide_rms_history',
              )
              .get();
          expect(
            rows,
            hasLength(1),
            reason:
                'The seeded v29 row must survive the v30 recreate. '
                'If this fails, the migration is destroying user data — '
                'stop and investigate the recreate transaction in '
                'database.dart before continuing.',
          );

          final row = rows.single.data;
          expect(row['session_id'], equals('seed-session'));
          expect(row['mount_id'], equals('eq6r-pro'));
          expect(row['target_id'], equals(42));
          expect(
            (row['total_rms_arcsec'] as num).toDouble(),
            closeTo(0.83, 1e-9),
          );
          expect(row['sample_count'], equals(312));
          expect(
            (row['exposure_seconds'] as num).toDouble(),
            closeTo(90.0, 1e-9),
          );
          expect(row['recorded_at'], equals(recordedAtUnix));
        } finally {
          await upgraded.close();
        }
      },
    );
  });
}
