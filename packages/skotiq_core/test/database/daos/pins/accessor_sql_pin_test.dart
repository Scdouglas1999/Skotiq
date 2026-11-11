// Pins the results of the queries the drift accessors (planning, targets,
// sessions, narrator events, sky atlas, science) still wrote as SQL text:
// return values, null handling and the rows each write leaves behind.

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';

import 'pin_harness.dart';

const _sessionColumns = 'id, start_time, end_time, status, notes';

void main() {
  late SkotiqDatabase db;
  late PinSeed seed;

  setUp(() async {
    db = openPinDatabase();
    seed = await PinSeed.create(db);
  });

  tearDown(() => db.close());

  test('accessor SQL results are pinned', () async {
    final pins = PinRecorder('accessor_sql');

    // Planning: scheduler queue removal selects from targets.
    final planning = db.planningDao;
    await pins('removed ids empty', planning.schedulerRemovedTargetIds);
    await pins(
      'remove one',
      () => planning.removeFromSchedulerQueue(seed.targets[1], 1740900000),
    );
    await pins(
      'remove unknown target',
      () => planning.removeFromSchedulerQueue(999, 1740900001),
    );
    await pins(
      'remove one again replaces',
      () => planning.removeFromSchedulerQueue(seed.targets[1], 1740900002),
    );
    await pins.dump(db, 'scheduler_removed_targets', 'after remove one');
    await pins(
      'remove all',
      () => planning.removeAllFromSchedulerQueue(1740900003),
    );
    await pins.dump(db, 'scheduler_removed_targets', 'after remove all');
    await pins('removed ids', planning.schedulerRemovedTargetIds);

    // Targets: favorite toggle.
    final targets = db.targetsDao;
    await pins('toggle on', () => targets.toggleFavorite(seed.targets[0]));
    await pins('toggle second', () => targets.toggleFavorite(seed.targets[1]));
    await pins('toggle off', () => targets.toggleFavorite(seed.targets[1]));
    await pins('toggle missing', () => targets.toggleFavorite(999));
    final favorites = await db
        .customSelect('SELECT id, is_favorite, updated_at FROM targets')
        .get();
    pins.record('targets after toggles', [for (final r in favorites) r.data]);

    // Sessions: re-open and abort.
    final sessions = db.sessionsDao;
    Future<void> dumpSessions(String label) async {
      final rows = await db
          .customSelect(
            'SELECT $_sessionColumns FROM imaging_sessions ORDER BY id',
          )
          .get();
      pins.record('$label :: imaging_sessions', [for (final r in rows) r.data]);
    }

    final s0 = seed.sessions[0];
    final s1 = seed.sessions[1];
    final empty = await db.customInsert(
      'INSERT INTO imaging_sessions (start_time, notes) '
      "VALUES (1740870000, '')",
    );
    final future = await db.customInsert(
      'INSERT INTO imaging_sessions (start_time) VALUES (1740870000)',
    );
    await db.customStatement(
      'INSERT INTO captured_images (file_path, file_name, exposure_duration, '
      "captured_at, session_id) VALUES ('/late.fits', 'late.fits', 1, "
      '4102444800, $future)',
    );
    await db.customStatement(
      "UPDATE imaging_sessions SET notes = 'first night' WHERE id = $s0",
    );
    await pins('reopen with notes', () => sessions.reopenSession(s0));
    await pins('reopen null notes', () => sessions.reopenSession(s1));
    await pins('reopen empty notes', () => sessions.reopenSession(empty));
    await pins('reopen again appends', () => sessions.reopenSession(s0));
    await pins('reopen missing', () => sessions.reopenSession(999));
    await dumpSessions('after reopen');
    await pins('abort with frames', () => sessions.abortSession(s0));
    await pins('abort without frames', () => sessions.abortSession(empty));
    await pins(
      'abort future frame clamps',
      () => sessions.abortSession(future),
    );
    await pins('abort missing', () => sessions.abortSession(999));
    await dumpSessions('after abort');

    // Narrator: the recent feed is scoped to the newest event's session.
    final narrator = db.narratorEventsDao;
    await pins('feed empty', () => narrator.watchRecentFeed().first);
    Future<int> event(int? session, int minute, {bool pinned = false}) {
      return db
          .into(db.narratorEvents)
          .insert(
            NarratorEventsCompanion.insert(
              sessionId: Value(session),
              timestamp: Value(pinT(minute)),
              eventType: 'note',
              category: 'session',
              severity: 'info',
              headline: 'event $minute',
              dedupeKey: 'k$minute',
              pinned: Value(pinned),
            ),
          );
    }

    await event(s0, 1);
    await event(s0, 2, pinned: true);
    await event(s1, 3);
    await event(s1, 3);
    await pins('feed newest session', () => narrator.watchRecentFeed().first);
    await pins('feed limit 1', () => narrator.watchRecentFeed(limit: 1).first);
    await event(null, 4);
    await event(null, 0, pinned: true);
    await pins('feed sessionless', () => narrator.watchRecentFeed().first);

    // Sky atlas: distinct-frame totals and the full reset.
    final atlas = db.skyAtlasDao;
    await pins('atlas totals empty', atlas.atlasTotals);
    final region = await db
        .into(db.skyAtlasRegions)
        .insert(
          SkyAtlasRegionsCompanion.insert(
            name: 'Cassiopeia',
            kind: 'constellation',
            centerRaDeg: 10,
            centerDecDeg: 60,
            radiusDeg: 8,
            tileCount: const Value(2),
            integrationSeconds: const Value(600),
            createdAt: Value(pinT(0)),
          ),
        );
    Future<void> tile(int tileId, int order, {int? regionId}) => db
        .into(db.skyTiles)
        .insert(
          SkyTilesCompanion.insert(
            tileId: tileId,
            healpixOrder: order,
            channels: 1,
            centerRaDeg: 10,
            centerDecDeg: 60,
            sidecarPath: '/atlas/$tileId.acc',
            regionId: Value(regionId),
            createdAt: Value(pinT(0)),
          ),
        );
    await tile(100, 6, regionId: region);
    await tile(101, 6, regionId: region);
    await tile(100, 7);
    Future<void> fold(
      int tileId,
      int order,
      String label,
      String contributor,
      double seconds, {
      int frames = 1,
    }) => db
        .into(db.skyAtlasFolds)
        .insert(
          SkyAtlasFoldsCompanion.insert(
            tileId: tileId,
            healpixOrder: order,
            framesAdded: frames,
            weightAdded: 1,
            integrationSecondsAdded: seconds,
            label: label,
            contributor: Value(contributor),
            foldedAt: Value(pinT(1)),
          ),
        );
    await fold(100, 6, 'f1', '', 300);
    await fold(101, 6, 'f1', '', 300);
    await fold(100, 6, 'f2', '', 120);
    await fold(100, 6, 'f2', 'peer', 180);
    await fold(101, 6, 'f3', '', 60, frames: 0);
    await fold(100, 7, 'f4', '', 30);
    await pins('atlas totals', atlas.atlasTotals);
    await pins(
      'tile 100 order 6',
      () => atlas.tileTotals(100, healpixOrder: 6),
    );
    await pins(
      'tile 101 order 6',
      () => atlas.tileTotals(101, healpixOrder: 6),
    );
    await pins(
      'tile 100 order 7',
      () => atlas.tileTotals(100, healpixOrder: 7),
    );
    await pins('tile unknown', () => atlas.tileTotals(5, healpixOrder: 6));
    await pins('region totals', () => atlas.regionTotals(region));
    await pins('region unknown', () => atlas.regionTotals(999));
    await db.customStatement(
      'UPDATE captured_images SET atlas_folded_at = 1740870000 '
      'WHERE id IN (${seed.images[0]}, ${seed.images[1]})',
    );
    await pins('delete all tiles and folds', atlas.deleteAllTilesAndFolds);
    final folded = await db
        .customSelect('SELECT id, atlas_folded_at FROM captured_images')
        .get();
    pins.record('atlas marks after reset', [for (final r in folded) r.data]);
    await pins.dump(db, 'sky_atlas_regions', 'after reset');
    await pins('atlas totals after reset', atlas.atlasTotals);

    // Science: frames with any per-frame product, and spatial map versions.
    final science = db.scienceDao;
    final img = seed.images;
    await pins(
      'science ids empty',
      () => science.getCapturedImageIdsWithScience(s0),
    );
    await db
        .into(db.scienceFrameQualityMetrics)
        .insert(
          ScienceFrameQualityMetricsCompanion.insert(
            sessionId: Value(s0),
            capturedImageId: Value(img[0]),
          ),
        );
    await db
        .into(db.framePhotometricCalibration)
        .insert(
          FramePhotometricCalibrationCompanion.insert(
            sessionId: Value(s1),
            capturedImageId: Value(img[1]),
          ),
        );
    for (final (image, row) in [
      (img[2], 0),
      (img[2], 1),
      (null, 0),
      (img[4], 0),
    ]) {
      await db
          .into(db.psfFieldTiles)
          .insert(
            PsfFieldTilesCompanion.insert(
              sessionId: Value(s0),
              capturedImageId: Value(image),
              tileRow: row,
              tileCol: 0,
            ),
          );
    }
    await db
        .into(db.photometryMeasurements)
        .insert(
          PhotometryMeasurementsCompanion.insert(
            sessionId: Value(s1),
            capturedImageId: Value(img[3]),
            objectId: 'star-1',
            x: 1,
            y: 2,
            flux: 3,
          ),
        );
    await db
        .into(db.scienceTileMetrics)
        .insert(
          ScienceTileMetricsCompanion.insert(
            sessionId: Value(s1),
            capturedImageId: Value(img[1]),
            layerType: 'fwhm',
            tileRow: 0,
            tileCol: 0,
          ),
        );
    await db
        .into(db.astrometryResidualVectors)
        .insert(
          AstrometryResidualVectorsCompanion.insert(
            sessionId: Value(s0),
            x: 1,
            y: 1,
            dxArcsec: 0.1,
            dyArcsec: 0.2,
            magnitudeArcsec: 0.22,
          ),
        );
    await pins(
      'science ids s0',
      () => science.getCapturedImageIdsWithScience(s0),
    );
    await pins(
      'science ids s1',
      () => science.getCapturedImageIdsWithScience(s1),
    );
    for (final product in ['psfTiles', 'tileMetrics', 'residuals']) {
      for (final session in [s0, s1]) {
        await pins(
          'spatial $product session $session',
          () => science.spatialMapVersions(session, product),
        );
      }
    }
    await pins(
      'spatial unknown product',
      () => science.spatialMapVersions(s0, 'x'),
    );
    pins.verify();
  });
}
