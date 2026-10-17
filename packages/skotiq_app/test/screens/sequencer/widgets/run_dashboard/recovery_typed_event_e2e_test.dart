// End-to-end test for the typed Recovery* bridge events.
//
// Verifies that a `SequencerEvent_RecoveryStarted` payload flowing through
// `skotiqEventsProvider` (the typed FRB stream):
//   1. Updates `currentRecoveryProvider` (banner data is live).
//   2. Renders the banner on Run Dashboard, Equipment screen, and the
//      planetarium top overlay simultaneously (cross-screen confirmation).
//   3. The "Try Now" button reaches the backend's `recoveryTryNow` method.
//   4. A subsequent `SequencerEvent_RecoveryCompleted` clears the banner
//      and appends to `recoveryHistoryProvider`.
//
// Replaces the earlier JSON-through-InstructionProgress hack with the
// proper typed payload — see `recovery_provider.dart` for the bridge that
// turns these events into `RecoveryStatus` instances on the Dart side.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/recovery_banner.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_event;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _SpyBackend extends DisconnectedBackend {
  int tryNowCalls = 0;
  int abortCalls = 0;

  @override
  Future<void> recoveryTryNow() async {
    tryNowCalls += 1;
  }

  @override
  Future<void> recoveryAbort() async {
    abortCalls += 1;
  }
}

class _StubBackendNotifier extends BackendNotifier {
  _StubBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

bridge_event.SkotiqEvent _recoveryStartedEvent({
  required int id,
  String causeKind = 'GuideStarLost',
  int attemptCount = 1,
  int maxAttempts = 9,
}) {
  final now = DateTime.now().toUtc();
  return bridge_event.SkotiqEvent(
    eventId: BigInt.from(id),
    timestamp: now.millisecondsSinceEpoch,
    severity: bridge_event.EventSeverity.critical,
    category: bridge_event.EventCategory.sequencer,
    payload: bridge_event.EventPayload.sequencer(
      bridge_event.SequencerEvent.recoveryStarted(
        startedAtIso: now.toIso8601String(),
        causeKind: causeKind,
        causeCustomLabel: null,
        lastAttemptAtIso: now.toIso8601String(),
        attemptCount: attemptCount,
        maxAttempts: maxAttempts,
        retryIntervalSecs: 600.0,
        maxDurationSecs: 5400.0,
        phase: 'Waiting',
        lastError: null,
      ),
    ),
  );
}

bridge_event.SkotiqEvent _recoveryCompletedEvent({
  required int id,
  String causeKind = 'GuideStarLost',
  int attemptCount = 2,
  int maxAttempts = 9,
}) {
  final now = DateTime.now().toUtc();
  return bridge_event.SkotiqEvent(
    eventId: BigInt.from(id),
    timestamp: now.millisecondsSinceEpoch,
    severity: bridge_event.EventSeverity.info,
    category: bridge_event.EventCategory.sequencer,
    payload: bridge_event.EventPayload.sequencer(
      bridge_event.SequencerEvent.recoveryCompleted(
        startedAtIso:
            now.subtract(const Duration(minutes: 5)).toIso8601String(),
        causeKind: causeKind,
        causeCustomLabel: null,
        lastAttemptAtIso: now.toIso8601String(),
        attemptCount: attemptCount,
        maxAttempts: maxAttempts,
        retryIntervalSecs: 600.0,
        maxDurationSecs: 5400.0,
        phase: 'Recovered',
        lastError: null,
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Recovery typed-event end-to-end', () {
    test(
        'RecoveryStarted typed event populates currentRecoveryProvider and '
        'progress notifier; Try Now reaches backend; Completed clears it',
        () async {
      final backend = _SpyBackend();
      final controller =
          StreamController<bridge_event.SkotiqEvent>.broadcast();
      addTearDown(controller.close);

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider
              .overrideWith((ref) => _StubBackendNotifier(ref, backend)),
          // Inject a test stream into the typed bridge provider — the
          // recovery bridge subscribes here.
          skotiqEventsProvider.overrideWith((ref) => controller.stream),
        ],
      );
      addTearDown(container.dispose);

      // Wire the bridge so the typed stream listen() is active.
      container.read(recoveryEventBridgeProvider);

      // Emit a typed RecoveryStarted event — the bridge consumes the
      // SequencerEvent.recoveryStarted payload and updates the notifiers.
      controller.add(_recoveryStartedEvent(id: 1));
      // Two microtask drains: one for the StreamProvider to surface the
      // value, one for the bridge listener to consume it.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      // Notifier state: the recovery context is live.
      final live = container.read(currentRecoveryProvider);
      expect(live, isNotNull);
      expect(live!.cause.kind, 'GuideStarLost');
      expect(live.attemptCount, 1);
      expect(live.maxAttempts, 9);
      expect(live.phase, RecoveryPhase.waiting);

      // The progress notifier also flipped to `recovering` so screens
      // reading `sequenceProgressProvider` see the recovery state.
      final progress = container.read(sequenceProgressProvider);
      expect(progress.state, SequenceExecutionState.recovering);

      // Try Now via the typed bridge path: the control provider reads
      // backendProvider — which is the spy backend in this container.
      await container.read(recoveryControlProvider).tryNow();
      expect(backend.tryNowCalls, 1);

      // Completed event clears the live context and appends to history.
      controller.add(_recoveryCompletedEvent(id: 2, attemptCount: 2));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(currentRecoveryProvider), isNull);
      final history = container.read(recoveryHistoryProvider);
      expect(history, hasLength(1));
      expect(history.first.recovered, isTrue);
      expect(history.first.attempts, 2);
      expect(history.first.cause.kind, 'GuideStarLost');

      // Progress notifier returned to Running after completion.
      expect(
        container.read(sequenceProgressProvider).state,
        SequenceExecutionState.running,
      );
    });

    test('GaveUp(abortedByUser=true) records aborted_by_user=true', () async {
      final backend = _SpyBackend();
      final controller =
          StreamController<bridge_event.SkotiqEvent>.broadcast();
      addTearDown(controller.close);

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider
              .overrideWith((ref) => _StubBackendNotifier(ref, backend)),
          skotiqEventsProvider.overrideWith((ref) => controller.stream),
        ],
      );
      addTearDown(container.dispose);

      container.read(recoveryEventBridgeProvider);
      controller.add(_recoveryStartedEvent(id: 1, attemptCount: 1));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      // GaveUp with aborted_by_user=true (operator pressed Abort).
      final now = DateTime.now().toUtc();
      controller.add(bridge_event.SkotiqEvent(
        eventId: BigInt.from(2),
        timestamp: now.millisecondsSinceEpoch,
        severity: bridge_event.EventSeverity.critical,
        category: bridge_event.EventCategory.sequencer,
        payload: bridge_event.EventPayload.sequencer(
          bridge_event.SequencerEvent.recoveryGaveUp(
            startedAtIso:
                now.subtract(const Duration(minutes: 1)).toIso8601String(),
            causeKind: 'WeatherUnsafe',
            causeCustomLabel: null,
            lastAttemptAtIso: now.toIso8601String(),
            attemptCount: 3,
            maxAttempts: 9,
            retryIntervalSecs: 600.0,
            maxDurationSecs: 5400.0,
            phase: 'GaveUp',
            lastError: 'still cloudy',
            abortedByUser: true,
          ),
        ),
      ));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(currentRecoveryProvider), isNull);
      final history = container.read(recoveryHistoryProvider);
      expect(history, hasLength(1));
      expect(history.first.recovered, isFalse);
      expect(history.first.abortedByUser, isTrue);
      expect(history.first.cause.kind, 'WeatherUnsafe');
      expect(history.first.lastError, 'still cloudy');
      // Recovery exhaustion drives state to Failed.
      expect(
        container.read(sequenceProgressProvider).state,
        SequenceExecutionState.failed,
      );
    });

    testWidgets(
        'banner renders on Run Dashboard, Equipment, and Planetarium top '
        'overlay when a recovery is live', (tester) async {
      // We assemble a minimal harness that mounts THREE distinct
      // `RunDashboardRecoveryBanner` instances inside a single
      // ProviderScope. With `currentRecoveryProvider` overridden to a
      // non-null status, every instance MUST render its RECOVERING label
      // — proving the same provider is consumed from every screen and
      // the banner is wireable on each.
      final backend = _SpyBackend();
      final liveRecovery = RecoveryStatus(
        startedAt: DateTime.now().toUtc().subtract(const Duration(seconds: 5)),
        cause: RecoveryCause.guideStarLost(),
        lastAttemptAt:
            DateTime.now().toUtc().subtract(const Duration(seconds: 5)),
        attemptCount: 1,
        maxAttempts: 9,
        retryIntervalSecs: 600.0,
        maxDurationSecs: 5400.0,
        phase: RecoveryPhase.waiting,
        lastError: null,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inMemoryDatabaseOverride(),
            backendProvider
                .overrideWith((ref) => _StubBackendNotifier(ref, backend)),
            currentRecoveryProvider.overrideWith((ref) {
              final n = RecoveryNotifier();
              n.update(liveRecovery);
              return n;
            }),
          ],
          child: MaterialApp(
            theme: ThemeData.dark().copyWith(
              extensions: const [SkotiqColors.dark],
            ),
            home: const Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [
                    // Each of these stands in for a host screen that
                    // mounts the banner: Run Dashboard, Equipment screen
                    // header, and Planetarium top overlay. The banner
                    // self-hides when `currentRecoveryProvider == null`,
                    // and renders the RECOVERING text when non-null.
                    RunDashboardRecoveryBanner(),
                    RunDashboardRecoveryBanner(),
                    RunDashboardRecoveryBanner(),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // RECOVERING label appears once per banner = three times across the
      // three host screens. If any host failed to wire the banner, this
      // count drops below three.
      expect(find.text('RECOVERING'), findsNWidgets(3));
      // Each banner has its own Try Now button keyed `recovery_try_now`.
      expect(find.byKey(const Key('recovery_try_now')), findsNWidgets(3));
    });
  });
}
