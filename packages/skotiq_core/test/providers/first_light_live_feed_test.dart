// The First Light candidate feed must be LIVE, not a snapshot.
//
// The panel's own header promises "Every solved frame is differenced against
// your deep sky atlas ... Anything that appeared, moved, or brightened on a
// deep patch lands here to review". A feed that misses a detection is the app
// stating something untrue, and the miss is silent: nothing on screen says a
// candidate was dropped, so the operator's only symptom is a transient they
// never got to triage.
//
// The awkward case is a detection persisted in the gap between the feed's first
// read and its subscription to the change stream. Nothing is listening yet, so
// the write's notification has no one to reach; the row can then only arrive as
// the stream's first event on subscription, which is exactly the event a
// count-based `.skip(1)` throws away.
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/database/daos/transient_detections_dao.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/transient_detections_provider.dart';

TransientDetectionsCompanion _detection(int tileId, int detectedAtEpochMs) {
  return TransientDetectionsCompanion.insert(
    tileId: tileId,
    detectedAt: Value(
      DateTime.fromMillisecondsSinceEpoch(detectedAtEpochMs, isUtc: true),
    ),
    raDeg: 202.4,
    decDeg: 47.2,
    residualFlux: 3.0,
    snr: 12.0,
    fwhm: 2.4,
    eccentricity: 0.1,
    kind: 'newSource',
    confidence: 0.9,
  );
}

/// A DAO that persists a detection in the exact window the feed is blind to:
/// after its opening read has returned, before it has subscribed to the change
/// stream. This is the difference pipeline landing a candidate while the panel
/// is opening — a normal thing to happen during a run, not a contrived one.
class _WritesDuringFirstReadDao extends TransientDetectionsDao {
  _WritesDuringFirstReadDao(super.db);

  bool _raced = false;

  @override
  Future<List<TransientDetectionRow>> recentDetections({
    int limit = 200,
    int offset = 0,
  }) async {
    final rows = await super.recentDetections(limit: limit, offset: offset);
    if (!_raced) {
      _raced = true;
      await insertDetection(_detection(777, 5000));
    }
    return rows;
  }
}

/// A DAO whose change stream is stuck in the failed state drift leaves a cached
/// query stream in, while a fresh read of the same query succeeds — i.e. the
/// database is fine and only the cached stream still remembers the failure.
/// This is the state the surface could not get out of without an app restart.
class _StuckWatchDao extends TransientDetectionsDao {
  _StuckWatchDao(super.db);

  @override
  Stream<List<TransientDetectionRow>> watchRecentDetections({int limit = 200}) {
    return Stream<List<TransientDetectionRow>>.error(
      const FormatException(
        'Invalid radix-10 number (at character 1)\ntile-042',
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  /// Poll the feed for up to ~2s for a row with [tileId].
  Future<bool> awaitTile(
    ProviderSubscription<AsyncValue<List<TransientDetectionRow>>> sub,
    int tileId,
  ) async {
    for (var i = 0; i < 100; i++) {
      final rows = sub.read().value ?? const <TransientDetectionRow>[];
      if (rows.any((r) => r.tileId == tileId)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return false;
  }

  test('a detection persisted after the feed is live shows up', () async {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    final sub = container.listen(firstLightCandidatesProvider, (_, __) {});
    addTearDown(sub.close);
    expect(await awaitTile(sub, 111), isFalse, reason: 'nothing stored yet');

    await TransientDetectionsDao(db).insertDetection(_detection(111, 1000));

    expect(
      await awaitTile(sub, 111),
      isTrue,
      reason: 'the feed must carry a detection written while it is live',
    );
  });

  test('a detection persisted while the feed is opening is not lost', () async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        transientDetectionsDaoProvider.overrideWith(
          (ref) => _WritesDuringFirstReadDao(ref.watch(databaseProvider)),
        ),
      ],
    );
    addTearDown(container.dispose);

    final sub = container.listen(firstLightCandidatesProvider, (_, __) {});
    addTearDown(sub.close);

    expect(
      await awaitTile(sub, 777),
      isTrue,
      reason:
          'a candidate written between the opening read and the '
          'subscription must still reach the feed',
    );
  });

  test(
    'a replayed cached failure does not resurrect the error state',
    () async {
      await TransientDetectionsDao(
        db,
      ).insertDetection(_detection(261982, 2000));

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          transientDetectionsDaoProvider.overrideWith(
            (ref) => _StuckWatchDao(ref.watch(databaseProvider)),
          ),
        ],
      );
      addTearDown(container.dispose);

      final sub = container.listen(firstLightCandidatesProvider, (_, __) {});
      addTearDown(sub.close);

      expect(
        await awaitTile(sub, 261982),
        isTrue,
        reason: 'the candidate the database actually holds must render',
      );
      // And it must STAY rendered: forwarding the stream's error would put
      // "Could not load candidates" back on screen over good data.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        sub.read().hasError,
        isFalse,
        reason:
            'a stale cached stream failure must not become the feed state '
            'when the query itself succeeds',
      );
    },
  );

  // The export hub (science_export_hub.dart) renders its own Retry on
  // allTransientDetectionsProvider, and the alert bell listens to it for new
  // candidates. It is the same feed with the same two hazards, so it gets the
  // same guarantees rather than only the First Light surface being fixed.
  group('the across-sessions feed behind the export hub and alert bell', () {
    test('recovers from a replayed cached failure', () async {
      await TransientDetectionsDao(db).insertDetection(_detection(4242, 2000));

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          transientDetectionsDaoProvider.overrideWith(
            (ref) => _StuckWatchDao(ref.watch(databaseProvider)),
          ),
        ],
      );
      addTearDown(container.dispose);

      final sub = container.listen(allTransientDetectionsProvider, (_, __) {});
      addTearDown(sub.close);

      expect(await awaitTile(sub, 4242), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(sub.read().hasError, isFalse);
    });

    test('does not lose a detection written while it is opening', () async {
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          transientDetectionsDaoProvider.overrideWith(
            (ref) => _WritesDuringFirstReadDao(ref.watch(databaseProvider)),
          ),
        ],
      );
      addTearDown(container.dispose);

      final sub = container.listen(allTransientDetectionsProvider, (_, __) {});
      addTearDown(sub.close);

      expect(await awaitTile(sub, 777), isTrue);
    });
  });
}
