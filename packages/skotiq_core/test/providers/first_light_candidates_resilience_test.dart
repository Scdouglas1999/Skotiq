// First Light's candidate feed must survive one bad row, and its Retry must
// genuinely re-query.
//
// Reproduced defect: a single transient_detections row whose tile_id held a
// TEXT value (SQLite type affinity permits it in an INTEGER column) made the
// generated drift mapper throw `FormatException: Invalid radix-10 number`, and
// that error killed the WHOLE candidate list — "Could not load candidates".
// Worse, it was unrecoverable: drift caches a query stream by its SQL, and a
// cached stream that has thrown replays the failure to every later subscriber
// without re-running the query. Verified in-process below: fixing the row
// through the same database and invalidating the provider still read back the
// original FormatException. Only an app restart cleared it.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/database/daos/transient_detections_dao.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/transient_detections_provider.dart';

const _columns =
    'session_id, captured_image_id, tile_id, detected_at, ra_deg, dec_deg, '
    'residual_flux, delta_mag, snr, fwhm, eccentricity, position_angle_deg, '
    'kind, catalog_match, confidence, reviewed, dismissed';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  /// Insert a row directly so a TEXT [tileId] can be written into the INTEGER
  /// column, exactly as an external tool would.
  Future<void> insertRaw({
    required String tileId,
    required int detectedAt,
    String kind = 'newSource',
  }) {
    return db.customStatement(
      'INSERT INTO transient_detections ($_columns) VALUES '
      '(NULL, NULL, $tileId, $detectedAt, 1.0, 2.0, 3.0, NULL, 4.0, 2.0, '
      "0.1, 0.0, '$kind', NULL, 0.9, 0, 0)",
    );
  }

  Future<List<T>> settle<T>(
    ProviderSubscription<AsyncValue<List<T>>> sub,
  ) async {
    for (var i = 0; i < 60; i++) {
      final value = sub.read();
      if (!value.isLoading) return value.value ?? <T>[];
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw StateError('feed never settled');
  }

  test('one undecodable row costs that row, not the whole feed', () async {
    await insertRaw(tileId: "'tile-042'", detectedAt: 2000);
    await insertRaw(tileId: '261982', detectedAt: 1000);

    final sub = container.listen(firstLightCandidatesProvider, (_, __) {});
    addTearDown(sub.close);
    final rows = await settle(sub);

    expect(sub.read().hasError, isFalse, reason: 'the feed must still load');
    expect(rows, hasLength(1));
    expect(rows.single.tileId, 261982);
  });

  test('the good rows still render even when the bad row is newest', () async {
    await insertRaw(tileId: "'tile-042'", detectedAt: 9999);
    for (var i = 0; i < 3; i++) {
      await insertRaw(tileId: '${100 + i}', detectedAt: 1000 + i);
    }

    final sub = container.listen(firstLightCandidatesProvider, (_, __) {});
    addTearDown(sub.close);
    final rows = await settle(sub);

    expect(rows.map((r) => r.tileId).toList(), [102, 101, 100]);
  });

  test(
    'a fixed row is picked up by a re-subscription, not only by a restart',
    () async {
      await insertRaw(tileId: "'tile-042'", detectedAt: 2000);

      final first = container.listen(firstLightCandidatesProvider, (_, __) {});
      await settle(first);
      first.close();

      // Correct the value the way the user would (in-app, same database).
      await db.customStatement(
        'UPDATE transient_detections SET tile_id = 261982',
      );

      // What the Retry button does.
      container.invalidate(firstLightCandidatesProvider);
      final retried = container.listen(
        firstLightCandidatesProvider,
        (_, __) {},
      );
      addTearDown(retried.close);

      // Settle on a *result*: a retry that keeps replaying drift's cached
      // failure stays an AsyncError forever and never yields a row.
      var rows = const <TransientDetectionRow>[];
      for (var i = 0; i < 60; i++) {
        final value = retried.read();
        expect(
          value.hasError,
          isFalse,
          reason: 'Retry replayed a cached failure instead of re-querying',
        );
        rows = value.value ?? const [];
        if (rows.isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(
        rows.single.tileId,
        261982,
        reason: 'the corrected row must appear without an app restart',
      );
    },
  );

  test('the DAO future read tolerates the same bad row', () async {
    await insertRaw(tileId: "'tile-042'", detectedAt: 2000);
    await insertRaw(tileId: '7', detectedAt: 1000);

    final dao = TransientDetectionsDao(db);
    final rows = await dao.recentDetections();
    expect(rows.map((r) => r.tileId).toList(), [7]);
  });
}
