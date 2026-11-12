import 'dart:async';
import 'dart:math';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';

void main() {
  late SkotiqDatabase db;

  setUp(() => db = SkotiqDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<int> session() => db
      .into(db.imagingSessions)
      .insert(ImagingSessionsCompanion.insert(startTime: DateTime(2026, 11)));

  Future<int> frame(int sessionId) => db
      .into(db.capturedImages)
      .insert(
        CapturedImagesCompanion.insert(
          filePath: '/f/${Random().nextInt(1 << 30)}.fits',
          fileName: 'f.fits',
          exposureDuration: 60,
          capturedAt: DateTime(2026, 11),
          sessionId: Value(sessionId),
        ),
      );

  Future<void> tiles(
    int sessionId,
    int? imageId,
    int seconds, {
    int rows = 2,
    String layer = 'uniformity',
  }) => db.scienceDao.insertTileMetrics([
    for (var r = 0; r < rows; r++)
      ScienceTileMetricsCompanion.insert(
        capturedImageId: Value(imageId),
        sessionId: Value(sessionId),
        timestamp: Value(
          DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true),
        ),
        layerType: layer,
        tileRow: r,
        tileCol: 0,
      ),
  ]);

  Future<List<ScienceTileMetricRow>> frameTiles(int sessionId, [int? image]) =>
      db.scienceDao
          .watchFrameTileMetrics(sessionId, capturedImageId: image)
          .first;

  Future<List<ScienceTileMetricRow>> sessionRows(int sessionId) =>
      (db.select(db.scienceTileMetrics)
            ..where((t) => t.sessionId.equals(sessionId))
            ..orderBy([
              (t) => OrderingTerm.desc(t.timestamp),
              (t) => OrderingTerm.asc(t.tileRow),
              (t) => OrderingTerm.asc(t.tileCol),
            ]))
          .get();

  test('gives the asked frame, else the frame measured last', () async {
    final s = await session();
    final older = await frame(s);
    final newer = await frame(s);
    final unmeasured = await frame(s);
    await tiles(s, newer, 100);
    await tiles(s, older, 200, rows: 3);

    expect((await frameTiles(s, newer)).map((t) => t.capturedImageId).toSet(), {
      newer,
    });
    // Measured last, not the highest id.
    final fallback = await frameTiles(s, unmeasured);
    expect(fallback, hasLength(3));
    expect(fallback.every((t) => t.capturedImageId == older), isTrue);
    expect(await frameTiles(s), hasLength(3));
  });

  test('never reads another session', () async {
    final s = await session();
    final other = await session();
    final mine = await frame(s);
    final theirs = await frame(other);
    await tiles(s, mine, 100);
    await tiles(other, theirs, 500);

    expect(
      (await frameTiles(s, theirs)).map((t) => t.capturedImageId).toSet(),
      {mine},
    );
    expect(await frameTiles(await session()), isEmpty);
  });

  test('rows with no frame count only when no row has one', () async {
    final s = await session();
    final measured = await frame(s);
    await tiles(s, measured, 100);
    await tiles(s, null, 900);
    expect(
      (await frameTiles(s)).map((t) => t.capturedImageId).toSet(),
      {measured},
    );

    final bare = await session();
    await tiles(bare, null, 10);
    await tiles(bare, null, 20, rows: 1);
    expect(await frameTiles(bare), hasLength(3));
  });

  test('answers again when a frame is measured', () async {
    final s = await session();
    final first = await frame(s);
    await tiles(s, first, 100);
    final second = await frame(s);

    final seen = <Set<int?>>[];
    final settled = Completer<void>();
    final sub = db.scienceDao
        .watchFrameTileMetrics(s, capturedImageId: second)
        .listen((rows) {
          seen.add(rows.map((t) => t.capturedImageId).toSet());
          if (seen.last.contains(second)) settled.complete();
        });
    await pumpEventQueue();
    await tiles(s, second, 200);
    await settled.future.timeout(const Duration(seconds: 5));
    await sub.cancel();

    expect(seen.first, {first});
    expect(seen.last, {second});
  });

  // The rule the views applied to the whole session's rows before they asked
  // for one frame.
  test('agrees with selectFrameScienceRows over the session', () async {
    final random = Random(7);
    for (var round = 0; round < 25; round++) {
      final s = await session();
      final frames = [for (var i = 0; i < 4; i++) await frame(s)];
      for (var i = 0; i < 6; i++) {
        final imageId = random.nextInt(6) == 0
            ? null
            : frames[random.nextInt(frames.length)];
        await tiles(
          s,
          imageId,
          random.nextInt(5),
          rows: 1 + random.nextInt(3),
          layer: random.nextBool() ? 'snr' : 'clip_low',
        );
      }
      final all = await sessionRows(s);
      for (final asked in [null, ...frames, 999999]) {
        final expected = selectFrameScienceRows(
          all,
          capturedImageId: asked,
          imageIdOf: (t) => t.capturedImageId,
          timestampOf: (t) => t.timestamp,
        );
        final actual = await frameTiles(s, asked);
        expect(
          actual.map((t) => t.id).toList(),
          expected.map((t) => t.id).toList(),
          reason: 'round $round, asked $asked',
        );
      }
    }
  });
}
