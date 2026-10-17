import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/providers/device_heartbeat_health_provider.dart';

/// Unit tests for the heartbeat-health provider.
///
/// We exercise the notifier directly (rather than going through the
/// `deviceServiceProvider` event-stream wiring) so the tests stay
/// independent of the event-routing scaffolding in
/// `device_service.dart`. The event-routing path is exercised by
/// `device_heartbeat_dispatch_test.dart`.
void main() {
  // A pinned clock so `lastChange` is deterministic across assertions.
  final fixedNow = DateTime.utc(2026, 1, 1, 12, 0, 0);
  DateTime clock() => fixedNow;

  group('DeviceHeartbeatHealthNotifier — happy path', () {
    test('forDevice returns unknown for absent ids', () {
      final notifier = DeviceHeartbeatHealthNotifier(now: clock);

      final s = notifier.forDevice('camera-1');
      expect(s.health, HeartbeatHealth.unknown);
      expect(s.reason, isNull);
      expect(s.consecutiveFailures, 0);
    });

    test('forDevice returns unknown for null / empty id', () {
      final notifier = DeviceHeartbeatHealthNotifier(now: clock);

      expect(notifier.forDevice(null).health, HeartbeatHealth.unknown);
      expect(notifier.forDevice('').health, HeartbeatHealth.unknown);
    });

    test('applyHeartbeatStarted marks device healthy', () {
      final notifier = DeviceHeartbeatHealthNotifier(now: clock);
      notifier.applyHeartbeatStarted(deviceId: 'camera-1');

      final s = notifier.forDevice('camera-1');
      expect(s.health, HeartbeatHealth.healthy);
      expect(s.lastChange, fixedNow);
    });

    test('applyStatusEvent("healthy") promotes device to healthy', () {
      final notifier = DeviceHeartbeatHealthNotifier(now: clock);
      notifier.applyStatusEvent(
        deviceId: 'mount-1',
        status: 'healthy',
        consecutiveFailures: 0,
        lastRttMs: 12,
      );

      final s = notifier.forDevice('mount-1');
      expect(s.health, HeartbeatHealth.healthy);
      expect(s.reason, isNull);
      expect(s.lastRttMs, 12);
    });
  });

  group('DeviceHeartbeatHealthNotifier — degraded', () {
    test(
      'HeartbeatDegraded event populates degraded state with actual reason',
      () {
        final notifier = DeviceHeartbeatHealthNotifier(now: clock);

        notifier.applyStatusEvent(
          deviceId: 'mount-1',
          status: 'degraded',
          consecutiveFailures: 3,
          lastRttMs: 450,
        );

        final s = notifier.forDevice('mount-1');
        expect(s.health, HeartbeatHealth.degraded);
        // The actual failure count must be in the reason text, because the
        // tooltip is where the operator reads it.
        expect(s.reason, contains('3'));
        expect(s.reason, contains('consecutive heartbeat'));
        expect(s.reason, contains('450ms'));
        expect(s.consecutiveFailures, 3);
      },
    );

    test(
      'degraded with no failure count still produces a non-empty reason',
      () {
        final notifier = DeviceHeartbeatHealthNotifier(now: clock);
        notifier.applyStatusEvent(
          deviceId: 'mount-1',
          status: 'degraded',
          consecutiveFailures: 0,
        );

        final s = notifier.forDevice('mount-1');
        expect(s.health, HeartbeatHealth.degraded);
        expect(s.reason, isNotNull);
        expect(s.reason, isNotEmpty);
      },
    );

    test('disconnected status maps to degraded with unresponsive message', () {
      final notifier = DeviceHeartbeatHealthNotifier(now: clock);
      notifier.applyStatusEvent(
        deviceId: 'mount-1',
        status: 'disconnected',
        consecutiveFailures: 5,
      );

      final s = notifier.forDevice('mount-1');
      expect(s.health, HeartbeatHealth.degraded);
      expect(s.reason, contains('unresponsive'));
      expect(s.reason, contains('5'));
    });

    test('unknown status string is surfaced verbatim in the reason', () {
      // Future Rust additions must not silently regress to "healthy".
      final notifier = DeviceHeartbeatHealthNotifier(now: clock);
      notifier.applyStatusEvent(
        deviceId: 'mount-1',
        status: 'newly_invented_status',
        consecutiveFailures: 0,
      );

      final s = notifier.forDevice('mount-1');
      expect(s.health, HeartbeatHealth.degraded);
      expect(s.reason, contains('newly_invented_status'));
    });
  });

  group('DeviceHeartbeatHealthNotifier — reconnecting / reconnected', () {
    test('applyReconnecting records attempt counter in tooltip', () {
      final notifier = DeviceHeartbeatHealthNotifier(now: clock);
      notifier.applyReconnecting(
        deviceId: 'camera-1',
        attempt: 2,
        maxAttempts: 5,
      );

      final s = notifier.forDevice('camera-1');
      expect(s.health, HeartbeatHealth.reconnecting);
      expect(s.reason, contains('attempt 2'));
      expect(s.reason, contains('5'));
    });

    test('applyReconnected returns to healthy with recovery note', () {
      final notifier = DeviceHeartbeatHealthNotifier(now: clock);
      // First degrade, then recover.
      notifier.applyStatusEvent(
        deviceId: 'camera-1',
        status: 'degraded',
        consecutiveFailures: 4,
      );
      notifier.applyReconnected(deviceId: 'camera-1', afterAttempts: 3);

      final s = notifier.forDevice('camera-1');
      expect(s.health, HeartbeatHealth.healthy);
      expect(s.reason, contains('3'));
      expect(s.reason, contains('attempt'));
    });
  });

  group('DeviceHeartbeatHealthNotifier — clearing', () {
    test('clearDevice resets entry so forDevice returns unknown again', () {
      final notifier = DeviceHeartbeatHealthNotifier(now: clock);
      notifier.applyStatusEvent(
        deviceId: 'mount-1',
        status: 'degraded',
        consecutiveFailures: 2,
      );
      expect(notifier.forDevice('mount-1').health, HeartbeatHealth.degraded);

      notifier.clearDevice('mount-1');

      expect(notifier.forDevice('mount-1').health, HeartbeatHealth.unknown);
      expect(notifier.state.containsKey('mount-1'), isFalse);
    });

    test('clearDevice on unknown id is a no-op', () {
      final notifier = DeviceHeartbeatHealthNotifier(now: clock);
      notifier.applyStatusEvent(deviceId: 'mount-1', status: 'healthy');
      final before = notifier.state;
      notifier.clearDevice('nonexistent');
      expect(notifier.state, same(before));
    });

    test('clearAll wipes every entry', () {
      final notifier = DeviceHeartbeatHealthNotifier(now: clock);
      notifier.applyStatusEvent(deviceId: 'a', status: 'healthy');
      notifier.applyStatusEvent(deviceId: 'b', status: 'degraded');
      expect(notifier.state.length, 2);

      notifier.clearAll();
      expect(notifier.state, isEmpty);
    });
  });

  group('DeviceHeartbeatHealthNotifier — state transitions', () {
    test('redundant healthy events do not bump lastChange', () {
      var ticks = 0;
      DateTime tick() {
        ticks++;
        return DateTime.utc(2026, 1, 1).add(Duration(seconds: ticks));
      }

      final notifier = DeviceHeartbeatHealthNotifier(now: tick);
      notifier.applyStatusEvent(deviceId: 'mount-1', status: 'healthy');
      final firstChange = notifier.forDevice('mount-1').lastChange;

      // A second healthy event with identical fields should not be
      // recorded as a transition — otherwise the indicator would pulse
      // on every routine heartbeat tick.
      notifier.applyStatusEvent(deviceId: 'mount-1', status: 'healthy');

      expect(notifier.forDevice('mount-1').lastChange, firstChange);
    });

    test(
      'healthy → degraded → healthy bumps lastChange for each transition',
      () {
        var ticks = 0;
        DateTime tick() {
          ticks++;
          return DateTime.utc(2026, 1, 1).add(Duration(seconds: ticks));
        }

        final notifier = DeviceHeartbeatHealthNotifier(now: tick);
        notifier.applyStatusEvent(deviceId: 'mount-1', status: 'healthy');
        final t1 = notifier.forDevice('mount-1').lastChange;

        notifier.applyStatusEvent(
          deviceId: 'mount-1',
          status: 'degraded',
          consecutiveFailures: 2,
        );
        final t2 = notifier.forDevice('mount-1').lastChange;
        expect(t2.isAfter(t1), isTrue);

        notifier.applyStatusEvent(deviceId: 'mount-1', status: 'healthy');
        final t3 = notifier.forDevice('mount-1').lastChange;
        expect(t3.isAfter(t2), isTrue);
      },
    );

    test('per-device entries are isolated', () {
      final notifier = DeviceHeartbeatHealthNotifier(now: clock);
      notifier.applyStatusEvent(
        deviceId: 'mount-1',
        status: 'degraded',
        consecutiveFailures: 1,
      );
      notifier.applyStatusEvent(deviceId: 'camera-1', status: 'healthy');

      expect(notifier.forDevice('mount-1').health, HeartbeatHealth.degraded);
      expect(notifier.forDevice('camera-1').health, HeartbeatHealth.healthy);
    });
  });

  group('Provider wiring', () {
    test('deviceHeartbeatHealthProvider yields a working notifier', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(deviceHeartbeatHealthProvider.notifier);
      notifier.applyHeartbeatStarted(deviceId: 'camera-1');

      final state = container.read(deviceHeartbeatHealthProvider);
      expect(state.containsKey('camera-1'), isTrue);
      expect(state['camera-1']!.health, HeartbeatHealth.healthy);
    });
  });
}
