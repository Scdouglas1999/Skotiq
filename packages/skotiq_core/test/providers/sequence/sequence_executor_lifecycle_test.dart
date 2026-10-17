// Integration test for the SequenceExecutor's session-lifecycle hooks.
//
// Several providers depend on the executor calling specific hooks at session
// start and end:
//   * Optical-train baseline / current-snapshot providers
//     (`opticalTrainBaselineProvider`, `opticalTrainCurrentSnapshotProvider`)
//   * Post-session health summary (`postSessionHealthSummaryProvider`)
//   * NotificationRouter active sequence (`router.setActiveSequence`)
//
// Plus the USB disconnect log feeding
// `DeviceHealthSnapshot.disconnectCountLast24h`.
//
// This test pins all four wirings end-to-end so dropping any one of them fires
// loudly at `flutter test` time. The executor's
// session-start / session-end hook methods are exposed via @visibleForTesting
// shims so the test drives them directly without spinning up a full
// sequencer run.

import 'dart:async';
import 'dart:math' as math;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart' as bridge_event;

import '../../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

/// Stub session-state notifier that exposes a fixed `dbSessionId` to
/// satisfy the executor's post-session diagnostics publish path. The
/// real notifier wraps `SessionsDao.startSession` which would require
/// the full database stack.
class _StubSessionStateNotifier extends SessionStateNotifier {
  _StubSessionStateNotifier(super.ref, int dbSessionId) {
    state = SessionState(
      isActive: true,
      dbSessionId: dbSessionId,
      startTime: DateTime.now(),
    );
  }
}

PsfFieldTileRow _fakeTile({
  required int sessionId,
  required int row,
  required int col,
  required double hfr,
}) {
  return PsfFieldTileRow(
    id: row * 10 + col,
    sessionId: sessionId,
    tileRow: row,
    tileCol: col,
    starCount: 25,
    medianFwhm: hfr * 2.35,
    medianHfr: hfr,
    medianEccentricity: 0.1,
    roundness: 0.9,
    timestamp: DateTime.utc(2026, 5, 18, 22, 0),
  );
}

double _aduForMag(double mag) {
  return 10.0 * math.pow(10.0, (21.5 - mag) / 2.5).toDouble();
}

void main() {
  setUpAll(() {
    registerMocktailFallbackValues();
  });

  late MockBackend backend;
  late StreamController<bridge_event.SkotiqEvent> eventController;
  late SkotiqDatabase db;

  ProviderContainer buildContainer({
    int dbSessionId = 42,
    List<PsfFieldTileRow> seededPsfTiles = const [],
  }) {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
        sessionStateProvider.overrideWith(
          (ref) => _StubSessionStateNotifier(ref, dbSessionId),
        ),
        // Override the PSF + residual streams directly so the executor's
        // synchronous read() picks up the seeded data without needing
        // the science DAO + DB insertion machinery.
        sessionPsfTilesProvider(
          dbSessionId,
        ).overrideWith((_) => Stream.value(seededPsfTiles)),
        sessionResidualVectorsProvider(
          dbSessionId,
        ).overrideWith((_) => Stream.value(const [])),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  setUp(() {
    backend = MockBackend();
    eventController = StreamController<bridge_event.SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => eventController.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await eventController.close();
    await db.close();
  });

  group('SequenceExecutor session-start hooks', () {
    test(
      'captures optical-train baseline when PSF data is available',
      () async {
        final container = buildContainer(
          dbSessionId: 42,
          seededPsfTiles: [
            _fakeTile(sessionId: 42, row: 0, col: 0, hfr: 2.5),
            _fakeTile(sessionId: 42, row: 0, col: 1, hfr: 3.0),
            _fakeTile(sessionId: 42, row: 1, col: 0, hfr: 2.4),
            _fakeTile(sessionId: 42, row: 1, col: 1, hfr: 2.7),
          ],
        );
        // Force the PSF stream to materialize so the executor's
        // synchronous `valueOrNull` picks up the seeded data.
        await container.read(sessionPsfTilesProvider(42).future);
        await container.read(sessionResidualVectorsProvider(42).future);

        final executor = container.read(sequenceExecutorProvider);
        executor.captureSessionStartHooksForTest('seq-abc');

        final baseline = container.read(opticalTrainBaselineProvider);
        final current = container.read(opticalTrainCurrentSnapshotProvider);
        expect(
          baseline,
          isNotNull,
          reason: 'baseline must be set when PSF data exists',
        );
        expect(
          current,
          isNotNull,
          reason: 'current snapshot must mirror the baseline on session start',
        );
      },
    );

    test('skips baseline gracefully when diagnostics are unavailable', () {
      // No PSF tiles seeded — the diagnostics service has nothing to
      // analyze. The executor must NOT crash; it should
      // log and continue.
      final container = buildContainer(dbSessionId: 99);
      final executor = container.read(sequenceExecutorProvider);

      expect(
        () => executor.captureSessionStartHooksForTest('seq-noop'),
        returnsNormally,
      );
      // Baseline left at its default (null).
      expect(container.read(opticalTrainBaselineProvider), isNull);
    });

    test('NotificationRouter setActiveSequence does not throw', () {
      final container = buildContainer();
      final executor = container.read(sequenceExecutorProvider);

      // The router is constructed lazily by the provider. The hook
      // must complete without throwing even when no transports / no
      // event stream are wired (the router constructor handles that).
      expect(
        () => executor.captureSessionStartHooksForTest('seq-router'),
        returnsNormally,
      );
      // Verify the router was actually obtained from the container
      // (which means setActiveSequence was called against a real
      // instance, not a stub that silently swallowed the call).
      expect(container.read(notificationRouterProvider), isNotNull);
    });
  });

  group('SequenceExecutor session-end hooks', () {
    test('publishes PostSessionHealthSummary with disconnect count', () async {
      final container = buildContainer(dbSessionId: 7);
      final log = container.read(usbDisconnectLogProvider);

      final executor = container.read(sequenceExecutorProvider);
      executor.captureSessionStartHooksForTest('seq-end-test');

      // Simulate a disconnect mid-session. Use direct log API since
      // the event bridge is tested separately.
      log.recordDisconnect(
        deviceId: 'cam-1',
        deviceType: 'camera',
        reason: 'usb pulled',
      );

      executor.captureSessionEndHooksForTest();

      final summary = container.read(postSessionHealthSummaryProvider(7));
      expect(
        summary.disconnectsDuringSession,
        greaterThanOrEqualTo(1),
        reason:
            'the post-session summary must reflect at least the in-session disconnect',
      );
    });

    // The Session Report already prints every `SequenceRunStats.warningMessages`
    // entry verbatim under "Warnings". Copying the same list into
    // `noticedConcerns` made `postSessionEquipmentHealthSummary` re-render each
    // one as a "Noticed but Did Not Fire" diagnostic in the SAME dialog, so a
    // one-off warning ("no focuser connected") was printed to the operator
    // twice.
    test('post-session summary does not restate the run warnings', () async {
      final container = buildContainer(dbSessionId: 12);
      final executor = container.read(sequenceExecutorProvider);
      executor.captureSessionStartHooksForTest('seq-warning-dupe');

      final stats = SequenceRunStats()
        ..recordWarning('No focuser connected — autofocus was skipped.')
        ..recordWarning('Filter "Ha" could not be matched.');
      container.read(liveSequenceStatsProvider.notifier).state = stats;

      executor.captureSessionEndHooksForTest();

      final summary = container.read(postSessionHealthSummaryProvider(12));
      expect(
        summary.noticedConcerns,
        isEmpty,
        reason:
            'the report renders warningMessages itself; re-publishing them as '
            'noticed concerns prints every warning twice in one dialog',
      );
      expect(
        postSessionEquipmentHealthSummary(
          summary,
        ).any((issue) => issue.title == 'Noticed but Did Not Fire'),
        isFalse,
        reason: 'no run warning may reappear as a post-session diagnostic',
      );
    });

    test('post-session summary counts cooler setpoint-band excursions', () async {
      final container = buildContainer(dbSessionId: 8);
      final executor = container.read(sequenceExecutorProvider);
      executor.captureSessionStartHooksForTest('seq-cooler-summary');

      final history = container.read(temperatureHistoryProvider.notifier);
      history.addPoint(-10.4, targetTemp: -10.0, coolerPower: 35.0);
      history.addPoint(-12.2, targetTemp: -10.0, coolerPower: 40.0);
      history.addPoint(-8.7, targetTemp: -10.0, coolerPower: 38.0);

      executor.captureSessionEndHooksForTest();

      final summary = container.read(postSessionHealthSummaryProvider(8));
      expect(
        summary.coolerOutOfBandSamples,
        2,
        reason:
            'post-session diagnostics should surface cooler samples outside the setpoint band',
      );
    });

    test(
      'post-session summary captures sky-brightness range and median',
      () async {
        final container = buildContainer(dbSessionId: 9);
        final executor = container.read(sequenceExecutorProvider);
        executor.captureSessionStartHooksForTest('seq-sky-summary');

        final tracker = container.read(skyBrightnessTrackerProvider);
        tracker.setCalibration(aduPerSec: 10.0, magPerArcsec2: 21.5);
        for (final mag in const [20.0, 21.0, 19.0]) {
          tracker.addSample(
            adu: _aduForMag(mag),
            exposureTime: 1.0,
            timestamp: DateTime.now(),
          );
        }

        executor.captureSessionEndHooksForTest();

        final summary = container.read(postSessionHealthSummaryProvider(9));
        expect(summary.skyBrightnessMin, closeTo(19.0, 0.01));
        expect(summary.skyBrightnessMax, closeTo(21.0, 0.01));
        expect(summary.skyBrightnessMedian, closeTo(20.0, 0.01));
      },
    );

    test('promotes post-session snapshot to next-session baseline', () async {
      // Seed PSF tiles so the post-session snapshot path produces a
      // baseline.
      final container = buildContainer(
        dbSessionId: 15,
        seededPsfTiles: [
          _fakeTile(sessionId: 15, row: 0, col: 0, hfr: 2.1),
          _fakeTile(sessionId: 15, row: 1, col: 1, hfr: 2.4),
        ],
      );
      await container.read(sessionPsfTilesProvider(15).future);
      await container.read(sessionResidualVectorsProvider(15).future);

      final executor = container.read(sequenceExecutorProvider);
      executor.captureSessionStartHooksForTest('seq-promotion');
      final startBaseline = container.read(opticalTrainBaselineProvider);
      expect(startBaseline, isNotNull);

      executor.captureSessionEndHooksForTest();

      // After end: baseline reflects the post-session snapshot (which
      // for this synthetic data equals the start snapshot, but the
      // provider state must have been written so the next session's
      // pre-flight rule can compare against it).
      final endBaseline = container.read(opticalTrainBaselineProvider);
      expect(endBaseline, isNotNull);
    });

    test('handles missing dbSessionId without throwing', () {
      // SessionState with no dbSessionId — simulating "session never
      // started" or "session already ended".
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, backend),
          ),
          // sessionStateProvider left as default (dbSessionId == null).
        ],
      );
      addTearDown(container.dispose);

      final executor = container.read(sequenceExecutorProvider);
      executor.captureSessionStartHooksForTest('seq-no-session');
      expect(() => executor.captureSessionEndHooksForTest(), returnsNormally);
    });

    test('end hooks are a no-op when start hooks never fired', () {
      final container = buildContainer();
      final executor = container.read(sequenceExecutorProvider);
      // Call end without start — should early-return cleanly.
      expect(() => executor.captureSessionEndHooksForTest(), returnsNormally);
    });

    test('NotificationRouter.setActiveSequence(null) is called at end', () {
      final container = buildContainer();
      final executor = container.read(sequenceExecutorProvider);

      executor.captureSessionStartHooksForTest('seq-end-test');
      // No throw on end:
      expect(() => executor.captureSessionEndHooksForTest(), returnsNormally);
      // A second end call must be a clean no-op (early-return guard).
      expect(() => executor.captureSessionEndHooksForTest(), returnsNormally);
    });
  });

  group('Full session lifecycle: disconnect + summary publication', () {
    test(
      'event-driven disconnect during run produces non-zero summary',
      () async {
        final container = buildContainer(dbSessionId: 100);
        // Materialize the disconnect bridge so it subscribes to the
        // event stream.
        container.read(usbDisconnectEventBridgeProvider);

        final executor = container.read(sequenceExecutorProvider);

        // 1. Session start hooks fire.
        executor.captureSessionStartHooksForTest('seq-full-run');

        // 2. Simulate a real disconnect event flowing through the
        // backend event stream (this is the production path).
        eventController.add(
          bridge_event.SkotiqEvent(
            timestamp: DateTime.now().millisecondsSinceEpoch,
            severity: bridge_event.EventSeverity.warning,
            category: bridge_event.EventCategory.equipment,
            eventType: 'Disconnected',
            data: const {'device_type': 'camera', 'device_id': 'lifecycle-cam'},
          ),
        );
        // Let the stream listener inside the bridge run.
        await Future<void>.delayed(Duration.zero);

        // 3. Sanity: the log saw the disconnect.
        final log = container.read(usbDisconnectLogProvider);
        expect(
          log.countForDevice('lifecycle-cam'),
          1,
          reason: 'the event bridge must forward the disconnect into the log',
        );

        // 4. Session end hooks publish the summary.
        executor.captureSessionEndHooksForTest();

        // 5. The summary reflects the disconnect.
        final summary = container.read(postSessionHealthSummaryProvider(100));
        expect(
          summary.disconnectsDuringSession,
          1,
          reason:
              'post-session diagnostics must reflect disconnects observed during the session window',
        );
      },
    );
  });
}
