// Stepped migration test for the v38 -> v39 step (OSC / Color Stacking, C11):
// `stacked_results` gains two colour-provenance columns — `is_color`
// (0/1 boolean) and `channels` (1=mono, 3=RGB) — added in place via guarded
// ALTER TABLE statements. Existing rows must backfill to mono and survive the
// upgrade.
//
// Pattern mirrors migration_v29_to_v30_test.dart:
//   1. Open a fresh DB at v39 via onCreate (lands the full schema incl. the
//      v39 columns).
//   2. Drop `stacked_results` and recreate the pre-v39 (v38) shape WITHOUT the
//      two new columns, seed a mono row, rewind PRAGMA user_version to 38,
//      close.
//   3. Reopen — triggers onUpgrade(38, 39) which runs the guarded ALTERs in
//      database.dart.
//   4. Assert the columns now exist (NOT NULL with mono defaults), the seeded
//      row backfilled to is_color=0 / channels=1, and a fresh insert through
//      the DAO can persist a colour stack.
//
// We deliberately do NOT import `package:drift/drift.dart` wholesale to avoid
// the `isNull` symbol collision with flutter_test; `Variable` is imported
// explicitly for the DAO-backed colour-insert assertion.
import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/stacked_results_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/imaging/stack_and_share_models.dart';

void main() {
  group('stepped migration onUpgrade v38 -> v39 (stacked_results colour)', () {
    /// Creates a fresh on-disk database opened at v39 (so the full schema
    /// lands), then replaces `stacked_results` with its pre-v39 (v38) shape
    /// — the same column set minus `is_color` / `channels`. Seeds one mono
    /// row and rewinds `PRAGMA user_version = 38` so the next open triggers
    /// `onUpgrade(38, 39)`.
    Future<File> createV38Database(Directory dir) async {
      final dbFile = File('${dir.path}/skotiq.db');
      final setupDb = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        await setupDb.customStatement('DROP TABLE stacked_results');
        // v38 shape: the v39 colour columns are absent.
        await setupDb.customStatement(
          'CREATE TABLE stacked_results('
          'id INTEGER PRIMARY KEY AUTOINCREMENT,'
          'session_id INTEGER,'
          'target_id INTEGER,'
          'target_name TEXT,'
          'width INTEGER NOT NULL,'
          'height INTEGER NOT NULL,'
          'frames_stacked INTEGER NOT NULL,'
          'frames_attempted INTEGER NOT NULL,'
          'integration_secs REAL NOT NULL,'
          'avg_alignment_residual REAL,'
          'avg_hfr REAL,'
          'filter TEXT,'
          'exported_image_path TEXT,'
          'created_at INTEGER NOT NULL)',
        );
        // Seed a pre-v39 mono row (no colour columns to populate).
        await setupDb.customStatement(
          'INSERT INTO stacked_results('
          'session_id, target_id, target_name, width, height, '
          'frames_stacked, frames_attempted, integration_secs, '
          'avg_alignment_residual, avg_hfr, filter, exported_image_path, '
          'created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
          <Object?>[
            7,
            11,
            'M81 (legacy mono)',
            4144,
            2822,
            30,
            32,
            3600.0,
            0.51,
            2.4,
            'L',
            '/exports/m81.png',
            DateTime.utc(2026, 4, 1, 22, 0).millisecondsSinceEpoch ~/ 1000,
          ],
        );
        await setupDb.customStatement('PRAGMA user_version = 38');
      } finally {
        await setupDb.close();
      }
      return dbFile;
    }

    test(
      'adds is_color + channels columns with NOT NULL mono defaults',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'skotiq_v38_v39_cols_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
        final dbFile = await createV38Database(tempDir);

        final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
        try {
          final info = await upgraded
              .customSelect("PRAGMA table_info('stacked_results')")
              .get();
          final isColor = info.firstWhere(
            (r) => r.data['name'] == 'is_color',
            orElse: () => throw StateError(
              'is_color column missing after v38 -> v39 upgrade',
            ),
          );
          final channels = info.firstWhere(
            (r) => r.data['name'] == 'channels',
            orElse: () => throw StateError(
              'channels column missing after v38 -> v39 upgrade',
            ),
          );
          expect(isColor.data['notnull'], equals(1));
          expect(isColor.data['dflt_value'].toString(), equals('0'));
          expect(channels.data['notnull'], equals(1));
          expect(channels.data['dflt_value'].toString(), equals('1'));
        } finally {
          await upgraded.close();
        }
      },
    );

    test(
      'existing pre-v39 rows backfill to mono (is_color=0, channels=1)',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'skotiq_v38_v39_backfill_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
        final dbFile = await createV38Database(tempDir);

        final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
        try {
          // The seeded row must survive untouched and adopt the mono defaults.
          final dao = StackedResultsDao(upgraded);
          final rows = await dao.getResultsForSession(7);
          expect(
            rows,
            hasLength(1),
            reason:
                'The seeded pre-v39 row must survive the in-place ALTER. '
                'If this fails the migration is destroying user data.',
          );
          final read = rows.single;
          expect(read.targetName, 'M81 (legacy mono)');
          expect(read.isColor, isFalse);
          expect(read.channels, 1);
          // The unrelated columns are untouched by the ALTER.
          expect(read.width, 4144);
          expect(read.framesStacked, 30);
          expect(read.exportedImagePath, '/exports/m81.png');
        } finally {
          await upgraded.close();
        }
      },
    );

    test(
      'a colour stack can be inserted and read back after the upgrade',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'skotiq_v38_v39_insert_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
        final dbFile = await createV38Database(tempDir);

        final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
        try {
          final dao = StackedResultsDao(upgraded);
          final id = await dao.insertResult(
            StackAndShareResult(
              sessionId: 99,
              targetName: 'NGC 7000 (OSC)',
              width: 6248,
              height: 4176,
              framesStacked: 60,
              framesAttempted: 64,
              integrationSecs: 7200,
              avgAlignmentResidual: 0.38,
              isColor: true,
              channels: 3,
              createdAt: DateTime.utc(2026, 5, 29, 4, 0),
            ),
          );
          expect(id, greaterThan(0));

          final read = await dao.getResultById(id);
          expect(read, isNotNull);
          expect(read!.isColor, isTrue);
          expect(read.channels, 3);

          final stored = await upgraded
              .customSelect(
                'SELECT is_color, channels FROM stacked_results WHERE id = ?',
                variables: [Variable<int>(id)],
              )
              .getSingle();
          expect(stored.read<int>('is_color'), 1);
          expect(stored.read<int>('channels'), 3);
        } finally {
          await upgraded.close();
        }
      },
    );
  });
}
