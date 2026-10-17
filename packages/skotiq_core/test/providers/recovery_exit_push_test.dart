// 4.0 Phase D (event-routing) — recovery-exit "and here's what I did" pushes.
//
// The entry push ("Recovering — <cause>") already existed. Phase D adds the
// EXIT push so an operator on cellular learns the *outcome* of every recovery
// loop, not just that one started. This test pins, for each operational
// problem the brief calls out (autofocus-failed, guiding-lost, weather-abort,
// device-disconnect) plus recovery exhaustion (`gaveUp`):
//
//   recovery event -> recoveryPushBridgeProvider -> enqueueCriticalNotification
//   -> PushNotificationService stream -> wire PushNotificationFrame
//   -> RemotePushDelivery.deliver (recorded)
//
// and asserts the delivered frame is `critical` and carries the right title +
// "here's what I did" body. The frame mapping mirrors the headless server's
// `_buildPushFrameFromNotification` (priority 'critical' -> severity
// 'critical'). A local recording [RemotePushDelivery] stands in for the wired
// FCM/APNs delivery so the whole path is exercised with zero cloud accounts.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/sequencer/recovery_status.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/recovery_provider.dart';
import 'package:skotiq_core/src/providers/push_notification_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/services/push_notification_service.dart';
// Import only the wire frame + severity const from the (stable) LAN push
// module. We deliberately do NOT import the protocol barrel or
// `remote_push_delivery.dart` so this routing test is decoupled from the
// FCM/APNs transport work landing in parallel — the routing area's contract is
// "produce the right critical PushNotificationFrame", which is exactly what
// the recording delivery below asserts.
import 'package:skotiq_remote_protocol/src/push/lan_push_broadcaster.dart'
    show PushNotificationFrame, kLanPushSeverityCritical;

/// In-memory recording delivery — stands in for the wired FCM/APNs delivery so
/// the full routing path is testable with no network and no cloud accounts.
/// Mirrors `RemotePushDelivery.deliver`'s signature without importing the
/// transport surface (kept decoupled from the parallel FCM/APNs work).
class _RecordingDelivery {
  final List<PushNotificationFrame> delivered = <PushNotificationFrame>[];

  Future<void> deliver(PushNotificationFrame frame) async {
    delivered.add(frame);
  }
}

/// AppSettings fake that resolves immediately so `appSettingsProvider` yields a
/// state with `pushCriticalAlerts` enabled without touching the database.
class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._initial);
  final AppSettingsState _initial;

  @override
  Future<AppSettingsState> build() async => _initial;
}

/// Captures the provider [Ref] so the test can drive `applyRecoveryEventForTest`
/// — the production code path — through the real bridge instead of reaching
/// into private helpers.
final _refCaptureProvider = Provider<Ref>((ref) => ref);

/// Maps a broadcast [PushNotification] onto the wire [PushNotificationFrame]
/// the headless server builds, so the delivered frame is exactly what cellular
/// would receive. Mirrors `event_forwarding._buildPushFrameFromNotification`'s
/// priority -> severity mapping.
PushNotificationFrame _frameFor(PushNotification n) {
  final severity = switch (n.priority) {
    PushNotificationPriority.critical => 'critical',
    PushNotificationPriority.high => 'warning',
    _ => 'info',
  };
  return PushNotificationFrame(
    id: 'test-${n.eventType}',
    severity: severity,
    title: n.title,
    body: n.body,
    data: {'eventType': n.eventType, 'category': n.category.name},
    timestamp: n.timestamp,
    serverFingerprint: 'test-fingerprint',
  );
}

RecoveryStatus _status(RecoveryCause cause, {int attemptCount = 2}) {
  return RecoveryStatus(
    startedAt: DateTime.utc(2026, 6, 8, 2),
    cause: cause,
    lastAttemptAt: DateTime.utc(2026, 6, 8, 2, 5),
    attemptCount: attemptCount,
    maxAttempts: 5,
    retryIntervalSecs: 300.0,
    maxDurationSecs: 1800.0,
    phase: RecoveryPhase.attempting,
    lastError: null,
  );
}

void main() {
  group('recovery-exit critical push (and here is what I did)', () {
    late _RecordingDelivery mock;
    late ProviderContainer container;
    late Ref ref;
    late StreamSubscription<PushNotification> sub;
    late List<PushNotification> pushes;

    setUp(() async {
      mock = _RecordingDelivery();
      pushes = <PushNotification>[];
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          appSettingsProvider.overrideWith(
            () => _FakeAppSettingsNotifier(const AppSettingsState()),
          ),
        ],
      );
      addTearDown(container.dispose);

      // Resolve the async settings before firing events — the push bridge gates
      // on `appSettingsProvider.valueOrNull`, so an unresolved future would make
      // every push no-op.
      await container.read(appSettingsProvider.future);

      // Activate the bridge (side-effect provider) and capture the ref so the
      // synthetic recovery events run the production routing.
      container.read(recoveryPushBridgeProvider);
      ref = container.read(_refCaptureProvider);

      // Forward every broadcast push through the mock delivery, exactly as the
      // headless server's fan-out tap would.
      final service = container.read(pushNotificationServiceProvider);
      // The broadcaster now starts fail-closed and only enables once the push
      // config resolves authoritatively. Load it (fresh DB → enabled defaults)
      // and let the service provider's listener apply it before firing events,
      // matching a running app that has its config provisioned.
      await container.read(pushNotificationConfigProvider.future);
      await Future<void>.delayed(Duration.zero);
      sub = service.notifications.listen((n) {
        pushes.add(n);
        // ignore: discarded_futures
        mock.deliver(_frameFor(n));
      });
      addTearDown(() => sub.cancel());
    });

    Future<PushNotificationFrame> fireExit({
      required RecoveryCause cause,
      required RecoveryEventKind kind,
      bool abortedByUser = false,
      int attemptCount = 2,
    }) async {
      // The history-growth listener drives the exit push; fire the production
      // apply helper so the same code path the live stream uses runs here.
      applyRecoveryEventForTest(
        ref,
        RecoveryEventEnvelope(
          kind: kind,
          context: _status(cause, attemptCount: attemptCount),
          abortedByUser: kind == RecoveryEventKind.gaveUp
              ? abortedByUser
              : null,
        ),
      );
      // Let the ref.listen microtask + the stream event flush.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        mock.delivered,
        isNotEmpty,
        reason: 'exit event should produce a delivered frame',
      );
      return mock.delivered.last;
    }

    test('guiding-lost recovered -> critical "re-acquired" frame', () async {
      final frame = await fireExit(
        cause: RecoveryCause.guideStarLost(),
        kind: RecoveryEventKind.completed,
        attemptCount: 2,
      );
      expect(frame.severity, 'critical');
      expect(frame.severityCode, kLanPushSeverityCritical);
      expect(frame.title, 'Recovered - Guide star lost');
      expect(
        frame.body,
        'Guide star lost -> re-acquired after 2 attempts, imaging resumed.',
      );
      expect(frame.data['eventType'], 'recovery_recovered_guide_star_lost');
    });

    test('autofocus-failed recovered -> critical frame', () async {
      final frame = await fireExit(
        cause: RecoveryCause.focusDriftCritical(),
        kind: RecoveryEventKind.completed,
        attemptCount: 1,
      );
      expect(frame.severity, 'critical');
      expect(frame.title, 'Recovered - Critical focus drift');
      expect(
        frame.body,
        'Critical focus drift -> re-acquired after 1 attempt, imaging resumed.',
      );
      expect(
        frame.data['eventType'],
        'recovery_recovered_focus_drift_critical',
      );
    });

    test('weather-abort gave up -> critical "gave up" frame', () async {
      final frame = await fireExit(
        cause: RecoveryCause.weatherUnsafe(),
        kind: RecoveryEventKind.gaveUp,
        attemptCount: 3,
      );
      expect(frame.severity, 'critical');
      expect(frame.title, 'Recovery failed - Weather unsafe');
      expect(
        frame.body,
        'Weather unsafe -> gave up after 3 attempts; sequence stopped, mount safe.',
      );
      expect(frame.data['eventType'], 'recovery_gave_up_weather_unsafe');
    });

    test('device-disconnect gave up -> critical exhaustion frame', () async {
      final frame = await fireExit(
        cause: RecoveryCause.deviceDisconnected(),
        kind: RecoveryEventKind.gaveUp,
        attemptCount: 5,
      );
      expect(frame.severity, 'critical');
      expect(frame.title, 'Recovery failed - Device disconnected');
      expect(
        frame.body,
        'Device disconnected -> gave up after 5 attempts; sequence stopped, mount safe.',
      );
      expect(frame.data['eventType'], 'recovery_gave_up_device_disconnected');
    });

    test('operator-aborted recovery -> "aborted" critical frame', () async {
      final frame = await fireExit(
        cause: RecoveryCause.guideStarLost(),
        kind: RecoveryEventKind.gaveUp,
        abortedByUser: true,
        attemptCount: 2,
      );
      expect(frame.severity, 'critical');
      expect(frame.title, 'Recovery aborted - Guide star lost');
      expect(
        frame.body,
        'Guide star lost -> recovery aborted by operator after 2 attempts.',
      );
      expect(frame.data['eventType'], 'recovery_gave_up_guide_star_lost');
    });

    test(
      'push respects the pushCriticalAlerts gate (off => no frame)',
      () async {
        // Rebuild with the gate disabled.
        await sub.cancel();
        container.dispose();
        mock = _RecordingDelivery();
        pushes = <PushNotification>[];
        final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            appSettingsProvider.overrideWith(
              () => _FakeAppSettingsNotifier(
                const AppSettingsState(pushCriticalAlerts: false),
              ),
            ),
          ],
        );
        // Resolve settings so the gate (disabled here) is actually consulted —
        // proving suppression, not just an unresolved-future no-op.
        await container.read(appSettingsProvider.future);
        container.read(recoveryPushBridgeProvider);
        ref = container.read(_refCaptureProvider);
        final service = container.read(pushNotificationServiceProvider);
        // Enable the broadcaster authoritatively so this subtest proves the
        // pushCriticalAlerts gate suppresses the push — not merely that the
        // fail-closed broadcaster swallowed it.
        await container.read(pushNotificationConfigProvider.future);
        await Future<void>.delayed(Duration.zero);
        sub = service.notifications.listen((n) {
          // ignore: discarded_futures
          mock.deliver(_frameFor(n));
        });

        applyRecoveryEventForTest(
          ref,
          RecoveryEventEnvelope(
            kind: RecoveryEventKind.completed,
            context: _status(RecoveryCause.guideStarLost()),
            abortedByUser: null,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(
          mock.delivered,
          isEmpty,
          reason: 'a disabled pushCriticalAlerts gate suppresses the push',
        );
      },
    );
  });
}
