// Migration round-trip test for the v53 -> v54 step (Living Sky — Wave 0 DB
// layer). v54 is purely additive:
//   * NEW table `constellation_contributions` (+ its unique
//     (hub_key, tile_id, healpix_order) index) — federation receipts.
//   * `sky_tiles.swarm_overlay_frames` / `swarm_overlay_integration_seconds`
//     — blended community depth kept out of the own-light totals.
//   * `captured_images.atlas_folded_at` — the fold dedup marker.
//
// Strategy mirrors migration_v52_to_v53_test.dart for an additive step:
//   1. Open a fresh on-disk DB at v54 via onCreate (full schema).
//   2. Simulate the pre-v54 (v53) state by DROPping the new columns + table and
//      rewinding `PRAGMA user_version = 53`.
//   3. Reopen — triggers onUpgrade(53, 54), running the v54 helper.
//   4. Assert the table/columns/index exist + round-trip each DAO concern, and
//      the idempotency guard holds (re-run preserves data, no duplicates).

import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';

void main() {
  group('migration onUpgrade v53 -> v54 (Constellation receipts + atlas '
      'overlay/fold-dedup columns)', () {
    /// Opens a fresh DB at v54, drops everything v54 added, and rewinds
    /// `PRAGMA user_version = 53` so the next open triggers onUpgrade(53, 54).
    Future<File> createV53Database(Directory dir) async {
      final dbFile = File('${dir.path}/skotiq.db');
      final setupDb = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        await setupDb.customStatement(
          'DROP TABLE IF EXISTS constellation_contributions',
        );
        await setupDb.customStatement(
          'ALTER TABLE sky_tiles DROP COLUMN swarm_overlay_frames',
        );
        await setupDb.customStatement(
          'ALTER TABLE sky_tiles DROP COLUMN swarm_overlay_integration_seconds',
        );
        await setupDb.customStatement(
          'ALTER TABLE captured_images DROP COLUMN atlas_folded_at',
        );
        await setupDb.customStatement('PRAGMA user_version = 53');
      } finally {
        await setupDb.close();
      }
      return dbFile;
    }

    Future<Set<String>> columnNames(SkotiqDatabase db, String table) async {
      final rows = await db.customSelect('PRAGMA table_info($table)').get();
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

    test('creates the constellation_contributions table + unique index '
        'and the new atlas columns', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v53_v54_schema_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV53Database(tempDir);

      final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        expect(
          await tableExists(upgraded, 'constellation_contributions'),
          isTrue,
        );

        // The unique key index materialized by the @TableIndex.
        final indexRows = await upgraded
            .customSelect(
              "SELECT name FROM sqlite_master WHERE type = 'index' "
              "AND name = 'idx_constellation_contributions_key'",
            )
            .get();
        expect(
          indexRows,
          isNotEmpty,
          reason:
              'the unique (hub_key, tile_id, healpix_order) index must '
              'exist',
        );

        expect(
          await columnNames(upgraded, 'sky_tiles'),
          containsAll(<String>[
            'swarm_overlay_frames',
            'swarm_overlay_integration_seconds',
          ]),
        );
        expect(
          await columnNames(upgraded, 'captured_images'),
          contains('atlas_folded_at'),
        );
      } finally {
        await upgraded.close();
      }
    });

    test(
      'the new table round-trips contribution / pull / join receipts',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'skotiq_v53_v54_rt_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
        final dbFile = await createV53Database(tempDir);

        final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
        try {
          final dao = upgraded.constellationContributionsDao;
          const hub = 'http://hub.local:8080';
          const tileId = 4242;

          // Contribution high-water. Use a local DateTime: Drift stores DateTime
          // as a timezone-naive epoch int, so a UTC value reads back as local.
          final anchor = DateTime(2026, 6, 21, 23, 0);
          await dao.upsertContribution(
            hub,
            tileId,
            lastContributedAt: anchor,
            lastContributedLabel: anchor.toIso8601String(),
            contributionId: 'receipt-1',
            contributedFrames: 12,
            contributedIntegrationSeconds: 1440.0,
          );

          // Pull high-water on the SAME row must not clobber contribution fields.
          await dao.upsertPulledHighWater(
            hub,
            tileId,
            lastPulledFrames: 99,
            lastPulledIntegrationSeconds: 9900.0,
          );

          // Join rehydration on the SAME row, likewise non-clobbering.
          await dao.upsertJoined(
            hub,
            tileId,
            joined: true,
            targetName: 'M31',
            targetRaDeg: 10.68,
            targetDecDeg: 41.27,
          );

          final row = await dao.getContribution(hub, tileId);
          expect(row, isNotNull);
          expect(row!.contributionId, 'receipt-1');
          expect(row.lastContributedAt, anchor);
          expect(row.lastContributedLabel, anchor.toIso8601String());
          expect(row.contributedFrames, 12);
          expect(row.contributedIntegrationSeconds, 1440.0);
          expect(row.lastPulledFrames, 99);
          expect(row.lastPulledIntegrationSeconds, 9900.0);
          expect(row.joined, isTrue);
          expect(row.targetName, 'M31');

          // Exactly one row for the (hub, tile) key — the three upserts merged.
          final all = await dao.getAllForHub(hub);
          expect(all, hasLength(1));
        } finally {
          await upgraded.close();
        }
      },
    );

    test(
      'atlas overlay columns + atlas_folded_at round-trip through the DAOs',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'skotiq_v53_v54_atlas_rt_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        });
        final dbFile = await createV53Database(tempDir);

        final upgraded = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
        try {
          // Overlay columns: a fold writes own-light totals only; a swarm merge
          // writes the overlay totals without clobbering own-light.
          final tileRowId = await upgraded.skyAtlasDao.upsertTile(
            tileId: 7,
            channels: 1,
            centerRaDeg: 10.0,
            centerDecDeg: 20.0,
            coverageMean: 1.0,
            totalFrames: 5,
            integrationSeconds: 300.0,
            sidecarPath: '/atlas/tiles/9/7.nst',
          );
          await upgraded.skyAtlasDao.upsertTile(
            tileId: 7,
            channels: 1,
            centerRaDeg: 10.0,
            centerDecDeg: 20.0,
            coverageMean: 1.0,
            totalFrames: 5,
            integrationSeconds: 300.0,
            sidecarPath: '/atlas/tiles/9/7.nst',
            swarmOverlayFrames: 40,
            swarmOverlayIntegrationSeconds: 2400.0,
          );
          final tile = await upgraded.skyAtlasDao.getTile(7);
          expect(tile, isNotNull);
          expect(tile!.totalFrames, 5, reason: 'own-light totals untouched');
          expect(tile.swarmOverlayFrames, 40);
          expect(tile.swarmOverlayIntegrationSeconds, 2400.0);
          expect(tileRowId, isPositive);

          // atlas_folded_at dedup marker.
          final imageId = await upgraded.imagesDao.createImage(
            CapturedImagesCompanion.insert(
              filePath: '/data/light_0001.fits',
              fileName: 'light_0001.fits',
              exposureDuration: 60.0,
              capturedAt: DateTime(2026, 6, 21, 22),
            ),
          );
          var image = await upgraded.imagesDao.getImageById(imageId);
          expect(image!.atlasFoldedAt, isNull);

          final stamp = DateTime(2026, 6, 21, 22, 5);
          final updated = await upgraded.imagesDao.stampAtlasFolded(
            imageId,
            at: stamp,
          );
          expect(updated, 1);
          image = await upgraded.imagesDao.getImageById(imageId);
          expect(image!.atlasFoldedAt, stamp);
        } finally {
          await upgraded.close();
        }
      },
    );

    test('re-running the v54 migration block is idempotent (no-op)', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_v53_v54_idem_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });
      final dbFile = await createV53Database(tempDir);

      final first = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      await first.constellationContributionsDao.upsertContribution(
        'http://hub.local:8080',
        7,
        contributionId: 'keep-me',
        contributedFrames: 3,
      );
      await first.close();

      // Rewind to v53 WITHOUT dropping; the helper guards each step with
      // _tableExists/_columnExists, so the second pass must be a pure no-op
      // that preserves the existing row.
      final rewind = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      await rewind.customStatement('PRAGMA user_version = 53');
      await rewind.close();

      final second = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        expect(
          await tableExists(second, 'constellation_contributions'),
          isTrue,
        );
        final row = await second.constellationContributionsDao.getContribution(
          'http://hub.local:8080',
          7,
        );
        expect(
          row?.contributionId,
          'keep-me',
          reason: 'the idempotent helper must NOT clobber existing data',
        );
      } finally {
        await second.close();
      }
    });
  });
}
