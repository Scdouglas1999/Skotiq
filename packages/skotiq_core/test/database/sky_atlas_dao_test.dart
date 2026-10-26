import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Exercises the v52 personal sky atlas tables end-to-end through
/// [SkyAtlasDao]: region upsert + point lookup, tile upsert keyed by HEALPix
/// pixel identity, the append-only fold timeline, and the "scrub a region
/// across time" ordering the UI relies on.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late SkyAtlasDao dao;

  setUp(() async {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    dao = SkyAtlasDao(db);
    // Seed the imaging_sessions rows folds reference (FKs are enforced).
    for (final id in [1, 2, 3]) {
      await db
          .into(db.imagingSessions)
          .insert(
            ImagingSessionsCompanion.insert(
              id: Value(id),
              startTime: DateTime.utc(2026, 6, 11, 21),
            ),
          );
    }
  });

  tearDown(() async {
    await db.close();
  });

  test('upsertRegion inserts then updates the same row by name', () async {
    final id = await dao.upsertRegion(
      name: 'M31',
      kind: 'target',
      centerRaDeg: 10.68,
      centerDecDeg: 41.27,
      radiusDeg: 1.5,
    );

    final again = await dao.upsertRegion(
      name: 'M31',
      kind: 'target',
      centerRaDeg: 10.68,
      centerDecDeg: 41.27,
      radiusDeg: 2.0,
      targetId: null,
    );

    expect(again, id, reason: 'same name reuses the row');
    final all = await dao.getAllRegions();
    expect(all, hasLength(1));
    expect(all.single.radiusDeg, 2.0, reason: 'geometry was refreshed');
  });

  test('getRegionForPoint returns the tightest covering cone', () async {
    final wide = await dao.upsertRegion(
      name: 'wide field',
      kind: 'custom',
      centerRaDeg: 10.0,
      centerDecDeg: 41.0,
      radiusDeg: 5.0,
    );
    final tight = await dao.upsertRegion(
      name: 'tight target',
      kind: 'target',
      centerRaDeg: 10.68,
      centerDecDeg: 41.27,
      radiusDeg: 1.0,
    );

    // A point inside both cones resolves to the smaller-radius region.
    final inside = await dao.getRegionForPoint(10.68, 41.27);
    expect(inside?.id, tight);

    // A point inside only the wide cone resolves to it.
    final wideOnly = await dao.getRegionForPoint(13.0, 41.0);
    expect(wideOnly?.id, wide);

    // A point outside every cone resolves to null.
    final outside = await dao.getRegionForPoint(200.0, -40.0);
    expect(outside, isNull);
  });

  test('upsertTile is keyed by (tileId, healpixOrder)', () async {
    final first = await dao.upsertTile(
      tileId: 42,
      channels: 1,
      centerRaDeg: 10.0,
      centerDecDeg: 41.0,
      coverageMean: 3.0,
      totalFrames: 5,
      integrationSeconds: 1500,
      sidecarPath: '/atlas/9/42.skt',
      lastFoldSessionId: 1,
      lastFoldAt: DateTime.utc(2026, 6, 11, 22),
    );

    final second = await dao.upsertTile(
      tileId: 42,
      channels: 1,
      centerRaDeg: 10.0,
      centerDecDeg: 41.0,
      coverageMean: 6.0,
      totalFrames: 11,
      integrationSeconds: 3300,
      sidecarPath: '/atlas/9/42.skt',
      lastFoldSessionId: 2,
      lastFoldAt: DateTime.utc(2026, 6, 12, 22),
    );

    expect(second, first, reason: 'same pixel reuses the tile row');
    final tile = await dao.getTile(42);
    expect(tile, isNotNull);
    expect(tile!.totalFrames, 11);
    expect(tile.integrationSeconds, 3300);
    expect(tile.healpixOrder, skyAtlasHealpixOrder);

    // A different order is a distinct tile.
    final other = await dao.upsertTile(
      tileId: 42,
      healpixOrder: 8,
      channels: 1,
      centerRaDeg: 10.0,
      centerDecDeg: 41.0,
      coverageMean: 1.0,
      totalFrames: 1,
      integrationSeconds: 100,
      sidecarPath: '/atlas/8/42.skt',
    );
    expect(other, isNot(first));
    expect(await dao.getAllTiles(), hasLength(2));
  });

  test('refreshRegionRollups counts each frame in the region once', () async {
    final region = await dao.upsertRegion(
      name: 'rollup',
      kind: 'custom',
      centerRaDeg: 10.0,
      centerDecDeg: 41.0,
      radiusDeg: 5.0,
    );
    final tileA = await dao.upsertTile(
      tileId: 1,
      channels: 1,
      centerRaDeg: 10.0,
      centerDecDeg: 41.0,
      coverageMean: 1,
      totalFrames: 3,
      integrationSeconds: 600,
      sidecarPath: '/a.skt',
      regionId: region,
    );
    await dao.upsertTile(
      tileId: 2,
      channels: 1,
      centerRaDeg: 10.1,
      centerDecDeg: 41.1,
      coverageMean: 1,
      totalFrames: 4,
      integrationSeconds: 900,
      sidecarPath: '/b.skt',
      regionId: region,
    );
    // A tile NOT in the region must be excluded.
    await dao.upsertTile(
      tileId: 3,
      channels: 1,
      centerRaDeg: 50.0,
      centerDecDeg: 0.0,
      coverageMean: 1,
      totalFrames: 99,
      integrationSeconds: 9999,
      sidecarPath: '/c.skt',
    );

    // One 600 s frame lands in both region tiles, a 900 s frame only in
    // tile 2, and a frame outside the region in tile 3.
    Future<void> fold(int tile, String label, double seconds) => dao.recordFold(
      tileId: tile,
      framesAdded: 1,
      weightAdded: 1,
      integrationSecondsAdded: seconds,
      label: label,
    );
    await fold(1, '2026-10-24T01:00:00Z', 600);
    await fold(2, '2026-10-24T01:00:00Z', 600);
    await fold(2, '2026-10-24T01:10:00Z', 900);
    await fold(3, '2026-10-24T01:20:00Z', 9999);

    await dao.refreshRegionRollups(region);
    final row = await dao.getRegion(region);
    expect(row!.tileCount, 2);
    // Each frame counts once, although the first lands in two tiles.
    expect(row.integrationSeconds, 1500);
    final totals = await dao.regionTotals(region);
    expect(totals.frames, 2);
    expect(tileA, isNotNull);
  });

  test(
    'recordFold + listFoldsForRegionOverTime replays a region chronologically',
    () async {
      final region = await dao.upsertRegion(
        name: 'timeline',
        kind: 'target',
        centerRaDeg: 10.0,
        centerDecDeg: 41.0,
        radiusDeg: 5.0,
      );
      await dao.upsertTile(
        tileId: 7,
        channels: 1,
        centerRaDeg: 10.0,
        centerDecDeg: 41.0,
        coverageMean: 1,
        totalFrames: 0,
        integrationSeconds: 0,
        sidecarPath: '/7.skt',
        regionId: region,
      );

      // Insert folds out of chronological order to prove the query sorts.
      await dao.recordFold(
        tileId: 7,
        sessionId: 2,
        framesAdded: 4,
        weightAdded: 4.0,
        integrationSecondsAdded: 1200,
        label: 'night 2',
        foldedAt: DateTime.utc(2026, 6, 12, 22),
      );
      await dao.recordFold(
        tileId: 7,
        sessionId: 1,
        framesAdded: 3,
        weightAdded: 3.0,
        integrationSecondsAdded: 900,
        label: 'night 1',
        foldedAt: DateTime.utc(2026, 6, 11, 22),
      );
      // A fold for a tile NOT in the region must be excluded.
      await dao.recordFold(
        tileId: 999,
        sessionId: 3,
        framesAdded: 1,
        weightAdded: 1.0,
        integrationSecondsAdded: 1,
        label: 'unrelated',
      );

      final timeline = await dao.listFoldsForRegionOverTime(region);
      expect(timeline.map((f) => f.label), ['night 1', 'night 2']);
      expect(timeline.first.sessionId, 1);
      expect(timeline.last.integrationSecondsAdded, 1200);
    },
  );
}
