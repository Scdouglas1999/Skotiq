// Migration round-trip test for the v54 -> v55 step (Living Sky — Wave 3
// scale/retention DB layer). v55 is purely additive:
//   * NEW table `living_sky_retention` (+ its unique `scope` index) — per-pillar
//     prune high-water markers.
//   * NEW scale indexes:
//       - idx_transient_detections_dismissed (dismissed, tile_id)
//       - idx_transient_detections_confirmed (reviewed, dismissed, detected_at)
//       - idx_sky_tiles_dec (center_dec_deg)
//       - idx_sky_atlas_folds_contributor (contributor, tile_id, healpix_order)
//
// Strategy mirrors migration_v53_to_v54_test.dart for an additive step:
//   1. Open a fresh on-disk DB at v55 via onCreate (full schema).
//   2. Simulate the pre-v55 (v54) state by DROPping the new table + indexes and
//      rewinding `PRAGMA user_version = 54`.
//   3. Reopen — triggers onUpgrade(54, 55), running the v55 helper.
//   4. Assert the table/index set exists, round-trip the retention DAO, exercise
//      the new index-backed DAO reads, and confirm the idempotent re-run.

import 'dart:io';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/database/tables/living_sky_retention.dart';

void main() {
  group('migration onUpgrade v54 -> v55 (Living Sky Wave 3 retention + scale '
      'indexes)', () {
    const wave3Indexes = <String>[
      'idx_transient_detections_dismissed',
      'idx_transient_detections_confirmed',
      'idx_sky_tiles_dec',
      'idx_sky_atlas_folds_contributor',
    ];

    /// Opens a fresh DB at v55, drops everything v55 added, and rewinds
    /// `PRAGMA user_version = 54` so the next open triggers onUpgrade(54, 55).
    Future<File> createV54Database(Directory dir) async {
      final dbFile = File('${dir.path}/skotiq.db');
      final setupDb = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        await setupDb.customStatement(
          'DROP TABLE IF EXISTS living_sky_retention',
        );
        for (final idx in wave3Indexes) {
          await setupDb.customStatement('DROP INDEX IF EXISTS $idx');
        }
        await setupDb.customStatement('PRAGMA user_version = 54');
      } finally {
        await setupDb.close();
      }
      return dbFile;
    }

    Future<Set<String>> indexNames(SkotiqDatabase db) async {
      final rows = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
          .get();
      return rows.map((r) => r.read<String>('name')).toSet();
    }

    Future<bool> tableExists(SkotiqDatabase db, String table) async {
      final rows = await db
          .customSelect(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
            variables: [Variable.withString(table)],
          )
          .get();
      return rows.isNotEmpty;
    }

    test('creates the living_sky_retention table + unique scope index and the '
        'four Wave 3 scale indexes', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v54_v55_schema_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV54Database(tempDir);

      final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        expect(await tableExists(upgraded, 'living_sky_retention'), isTrue);

        final idx = await indexNames(upgraded);
        expect(
          idx,
          contains('idx_living_sky_retention_scope'),
          reason: 'the unique scope index must exist',
        );
        expect(
          idx,
          containsAll(wave3Indexes),
          reason: 'all four Wave 3 scale indexes must be created on upgrade',
        );
      } finally {
        await upgraded.close();
      }
    });

    test(
      'living_sky_retention round-trips a prune marker + accumulates count',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'skotiq_v54_v55_rt_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
        final dbFile = await createV54Database(tempDir);

        final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
        try {
          final dao = upgraded.livingSkyRetentionDao;
          const scope = LivingSkyRetentionScope.transientDetections;

          expect(await dao.getMarker(scope), isNull);

          final firstAt = DateTime(2026, 6, 21, 12);
          await dao.recordPrune(
            scope,
            lastPrunedAt: firstAt,
            lastPrunedId: 100,
            reclaimed: 7,
            note: 'first sweep',
          );

          var row = await dao.getMarker(scope);
          expect(row, isNotNull);
          expect(row!.lastPrunedAt, firstAt);
          expect(row.lastPrunedId, 100);
          expect(row.prunedCount, 7);
          expect(row.note, 'first sweep');

          // A second pass advances the marker and ADDS to the running count.
          final secondAt = DateTime(2026, 6, 22, 12);
          await dao.recordPrune(
            scope,
            lastPrunedAt: secondAt,
            lastPrunedId: 250,
            reclaimed: 3,
          );
          row = await dao.getMarker(scope);
          expect(row!.lastPrunedAt, secondAt);
          expect(row.lastPrunedId, 250);
          expect(row.prunedCount, 10, reason: 'reclaimed counts accumulate');
          expect(row.note, 'first sweep', reason: 'omitted note is preserved');
        } finally {
          await upgraded.close();
        }
      },
    );

    test('the index-backed transient + atlas reads return correct rows after '
        'upgrade', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v54_v55_reads_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV54Database(tempDir);

      final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        final tDao = upgraded.transientDetectionsDao;

        // A dismissed artefact on tile 11, a confirmed discovery on tile 22,
        // and an unreviewed candidate on tile 33.
        await tDao.insertDetection(
          _detection(tileId: 11, dismissed: true, reviewed: true),
        );
        await tDao.insertDetection(
          _detection(
            tileId: 22,
            reviewed: true,
            dismissed: false,
            catalogMatch: null,
          ),
        );
        await tDao.insertDetection(_detection(tileId: 33));

        // dismissedDetectionsForTiles is scoped to covered tiles.
        final dismissed = await tDao.dismissedDetectionsForTiles(<int>[11, 33]);
        expect(dismissed, hasLength(1));
        expect(dismissed.single.tileId, 11);
        expect(
          await tDao.dismissedDetectionsForTiles(const <int>[]),
          isEmpty,
          reason: 'empty cover set suppresses nothing',
        );

        // confirmedDetections = reviewed && !dismissed (the dismissed artefact
        // must NOT leak in).
        final confirmed = await tDao.confirmedDetections();
        expect(confirmed, hasLength(1));
        expect(confirmed.single.tileId, 22);

        // recentDetections bounds the feed.
        final recent = await tDao.recentDetections(limit: 2);
        expect(recent, hasLength(2));

        // pruneDetections reclaims aged dismissed rows, keeps the rest.
        final deleted = await tDao.pruneDetections(olderThan: DateTime(2027));
        expect(deleted, 1, reason: 'only the dismissed artefact ages out');
        expect(await tDao.confirmedDetections(), hasLength(1));

        // Dec-band cone prefilter on the atlas.
        final aDao = upgraded.skyAtlasDao;
        await aDao.upsertTile(
          tileId: 1,
          channels: 1,
          centerRaDeg: 10,
          centerDecDeg: 41,
          coverageMean: 1,
          totalFrames: 1,
          integrationSeconds: 60,
          sidecarPath: '/atlas/1.skt',
        );
        await aDao.upsertTile(
          tileId: 2,
          channels: 1,
          centerRaDeg: 10,
          centerDecDeg: -20,
          coverageMean: 1,
          totalFrames: 1,
          integrationSeconds: 60,
          sidecarPath: '/atlas/2.skt',
        );
        final band = await aDao.getTilesInDecBand(40, 42);
        expect(band, hasLength(1));
        expect(band.single.tileId, 1);
      } finally {
        await upgraded.close();
      }
    });

    test('re-running the v55 migration block is idempotent (no-op)', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v54_v55_idem_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV54Database(tempDir);

      final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      await first.livingSkyRetentionDao.recordPrune(
        LivingSkyRetentionScope.swarmBlobs,
        reclaimed: 5,
        note: 'keep-me',
      );
      await first.close();

      // Rewind to v54 WITHOUT dropping; the helper guards table creation with
      // _tableExists and the indexes with IF NOT EXISTS, so the second pass is
      // a pure no-op that preserves the existing row.
      final rewind = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      await rewind.customStatement('PRAGMA user_version = 54');
      await rewind.close();

      final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        expect(await tableExists(second, 'living_sky_retention'), isTrue);
        final row = await second.livingSkyRetentionDao.getMarker(
          LivingSkyRetentionScope.swarmBlobs,
        );
        expect(
          row?.note,
          'keep-me',
          reason: 'the idempotent helper must NOT clobber existing data',
        );
        expect(row?.prunedCount, 5);
      } finally {
        await second.close();
      }
    });
  });
}

/// A minimal valid `transient_detections` insert companion for the reads test.
TransientDetectionsCompanion _detection({
  required int tileId,
  bool reviewed = false,
  bool dismissed = false,
  String? catalogMatch = 'noise',
}) {
  return TransientDetectionsCompanion.insert(
    tileId: tileId,
    raDeg: 10.0,
    decDeg: 20.0,
    residualFlux: 1.0,
    snr: 6.0,
    fwhm: 2.0,
    eccentricity: 0.1,
    kind: 'newSource',
    confidence: 0.9,
    reviewed: Value(reviewed),
    dismissed: Value(dismissed),
    catalogMatch: Value(catalogMatch),
  );
}
