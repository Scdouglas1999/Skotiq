import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/device_heartbeat_health_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';

import '../harness/in_memory_database.dart';
import '../mocks/mock_backend.dart';
import 'package:skotiq_core/src/models/backend/backend_types.dart';
import 'package:skotiq_core/src/providers/device_service_providers.dart';

/// Verifies that heartbeat events arriving on the equipment
/// event stream are routed into `deviceHeartbeatHealthProvider` by
/// `DeviceService`, and that a `Disconnected` event clears the entry.
class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  late ProviderContainer container;
  late MockBackend mockBackend;
  late StreamController<SkotiqEvent> events;

  setUpAll(() {
    registerMocktailFallbackValues();
  });

  setUp(() {
    mockBackend = MockBackend();
    events = StreamController<SkotiqEvent>.broadcast();
    when(() => mockBackend.eventStream).thenAnswer((_) => events.stream);
    when(
      () => mockBackend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    when(
      () => mockBackend.nativeReconnectedDeviceTypes,
    ).thenReturn(DeviceType.values.toSet());

    container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, mockBackend),
        ),
        inMemoryDatabaseOverride(),
      ],
    );

    // Wire up the event subscription.
    container.read(deviceServiceProvider);
  });

  tearDown(() async {
    await events.close();
    container.dispose();
  });

  SkotiqEvent makeEvent(String eventType, Map<String, dynamic> data) =>
      SkotiqEvent(
        timestamp: DateTime.now().millisecondsSinceEpoch,
        severity: EventSeverity.info,
        category: EventCategory.equipment,
        eventType: eventType,
        data: data,
      );

  test(
    'HeartbeatStatusChanged(degraded) updates the provider with reason',
    () async {
      const deviceId = 'native:zwo:0';
      events.add(
        makeEvent('HeartbeatStatusChanged', {
          'device_type': 'camera',
          'device_id': deviceId,
          'status': 'degraded',
          'consecutive_failures': 3,
          'last_rtt_ms': 250,
        }),
      );

      // Allow the stream listener to dispatch.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final state = container
          .read(deviceHeartbeatHealthProvider.notifier)
          .forDevice(deviceId);
      expect(state.health, HeartbeatHealth.degraded);
      // The reason must carry the real failure count, not a
      // generic placeholder.
      expect(state.reason, isNotNull);
      expect(state.reason!, contains('3'));
      expect(state.consecutiveFailures, 3);
    },
  );

  test('HeartbeatStatusChanged(healthy) routes to healthy state', () async {
    const deviceId = 'native:zwo:0';
    events.add(
      makeEvent('HeartbeatStatusChanged', {
        'device_type': 'camera',
        'device_id': deviceId,
        'status': 'healthy',
        'consecutive_failures': 0,
      }),
    );

    await Future<void>.delayed(const Duration(milliseconds: 50));

    final state = container
        .read(deviceHeartbeatHealthProvider.notifier)
        .forDevice(deviceId);
    expect(state.health, HeartbeatHealth.healthy);
  });

  test('HeartbeatReconnecting populates attempt counter in reason', () async {
    const deviceId = 'native:zwo:0';
    events.add(
      makeEvent('HeartbeatReconnecting', {
        'device_type': 'camera',
        'device_id': deviceId,
        'attempt': 2,
        'max_attempts': 5,
      }),
    );

    await Future<void>.delayed(const Duration(milliseconds: 50));

    final state = container
        .read(deviceHeartbeatHealthProvider.notifier)
        .forDevice(deviceId);
    expect(state.health, HeartbeatHealth.reconnecting);
    expect(state.reason, contains('attempt 2'));
  });

  test('Disconnected event clears the heartbeat entry when no reconnect is '
      'pending', () async {
    const deviceId = 'native:zwo:0';

    // Nothing reconnects the camera here, so the indicator must fall back to
    // gray "unknown" rather than getting stuck on a stale value. (A device
    // the native side reconnects reads "reconnecting", covered separately.)
    when(() => mockBackend.nativeReconnectedDeviceTypes).thenReturn(const {});

    // First, mark the device degraded.
    events.add(
      makeEvent('HeartbeatStatusChanged', {
        'device_type': 'camera',
        'device_id': deviceId,
        'status': 'degraded',
        'consecutive_failures': 2,
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final beforeState = container
        .read(deviceHeartbeatHealthProvider.notifier)
        .forDevice(deviceId);
    expect(beforeState.health, HeartbeatHealth.degraded);

    // Now disconnect — heartbeat entry should be cleared so the
    // indicator falls back to gray "unknown" rather than getting stuck.
    events.add(
      makeEvent('Disconnected', {
        'device_type': 'camera',
        'device_id': deviceId,
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final afterState = container
        .read(deviceHeartbeatHealthProvider.notifier)
        .forDevice(deviceId);
    expect(afterState.health, HeartbeatHealth.unknown);
  });

  test('HeartbeatStarted seeds device as healthy immediately', () async {
    const deviceId = 'native:zwo:0';
    events.add(
      makeEvent('HeartbeatStarted', {
        'device_type': 'camera',
        'device_id': deviceId,
        'interval_secs': BigInt.from(10),
      }),
    );

    await Future<void>.delayed(const Duration(milliseconds: 50));

    final state = container
        .read(deviceHeartbeatHealthProvider.notifier)
        .forDevice(deviceId);
    expect(state.health, HeartbeatHealth.healthy);
  });

  test('HeartbeatStopped clears the entry', () async {
    const deviceId = 'native:zwo:0';
    events.add(
      makeEvent('HeartbeatStarted', {
        'device_type': 'camera',
        'device_id': deviceId,
        'interval_secs': BigInt.from(10),
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      container
          .read(deviceHeartbeatHealthProvider.notifier)
          .forDevice(deviceId)
          .health,
      HeartbeatHealth.healthy,
    );

    events.add(
      makeEvent('HeartbeatStopped', {
        'device_type': 'camera',
        'device_id': deviceId,
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      container
          .read(deviceHeartbeatHealthProvider.notifier)
          .forDevice(deviceId)
          .health,
      HeartbeatHealth.unknown,
    );
  });

  test('HeartbeatStatusChanged(disconnected) drives the disconnect side '
      'effects (flips connection state + surfaces reconnecting)', () async {
    // The heartbeat-lost path emits no standalone `Disconnected` event (it is
    // deduped to one toast), so the canonical
    // `HeartbeatStatusChanged{Disconnected}` status itself drives the
    // load-bearing disconnect side effects: transitioning the device connection
    // state and showing the device as reconnecting while the native loop
    // brings it back: the health dot reads `reconnecting`, not gray "unknown".
    const deviceId = 'native:zwo:0';

    // Bring the camera "online" so the disconnect transition is observable.
    final camNotifier = container.read(cameraStateProvider.notifier);
    camNotifier.setConnecting(deviceId, 'Test Camera');
    camNotifier.setConnected();
    expect(
      container.read(cameraStateProvider).connectionState,
      DeviceConnectionState.connected,
    );

    // Degrade first so there is a health entry to transition.
    events.add(
      makeEvent('HeartbeatStatusChanged', {
        'device_type': 'camera',
        'device_id': deviceId,
        'status': 'degraded',
        'consecutive_failures': 4,
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      container
          .read(deviceHeartbeatHealthProvider.notifier)
          .forDevice(deviceId)
          .health,
      HeartbeatHealth.degraded,
    );

    // Cross the threshold: Rust emits HeartbeatStatusChanged{Disconnected}
    // (no standalone Disconnected event). This must flip the camera to
    // disconnected and surface the reconnecting indicator.
    events.add(
      makeEvent('HeartbeatStatusChanged', {
        'device_type': 'camera',
        'device_id': deviceId,
        'status': 'disconnected',
        'consecutive_failures': 5,
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      container
          .read(deviceHeartbeatHealthProvider.notifier)
          .forDevice(deviceId)
          .health,
      HeartbeatHealth.reconnecting,
      reason:
          'a lost device the native loop reconnects reads reconnecting, '
          'not gray "unknown"',
    );
    expect(
      container.read(cameraStateProvider).connectionState,
      DeviceConnectionState.disconnected,
      reason: 'the camera slot shows the device as lost',
    );
  });

  test(
    'mount heartbeat loss surfaces reconnecting WITHOUT an app connect',
    () async {
      // The native reconnection_loop performs the real reconnect; a second
      // connect from the app double-connected and thrashed the driver. The app
      // only lights the "reconnecting" indicator the native side never emits
      // an event for.
      const deviceId = 'ascom:ASCOM.Simulator.Telescope';

      final mountNotifier = container.read(mountStateProvider.notifier);
      mountNotifier.setConnecting(deviceId, 'Test Mount');
      mountNotifier.setConnected();

      events.add(
        makeEvent('HeartbeatStatusChanged', {
          'device_type': 'mount',
          'device_id': deviceId,
          'status': 'disconnected',
          'consecutive_failures': 5,
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(
        container
            .read(deviceHeartbeatHealthProvider.notifier)
            .forDevice(deviceId)
            .health,
        HeartbeatHealth.reconnecting,
        reason: 'the native reconnect must still light the indicator',
      );
      expect(
        container.read(mountStateProvider).connectionState,
        DeviceConnectionState.disconnected,
      );
      verifyNever(() => mockBackend.connectDevice(any(), any()));
    },
  );

  test(
    'Heartbeat dispatch does not interfere with the Disconnected handler',
    () async {
      // Heartbeat routing must not break connection-state handling. A
      // Disconnected event for a device with no heartbeat entry at all must
      // leave the heartbeat clear a no-op that does not raise, and the event
      // must still reach the existing handler.
      const deviceId = 'native:zwo:0';
      container.read(cameraStateProvider.notifier)
        ..setConnecting(deviceId, 'ZWO')
        ..setConnected();

      events.add(
        makeEvent('Disconnected', {
          'device_type': 'camera',
          'device_id': deviceId,
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        container.read(cameraStateProvider).connectionState,
        DeviceConnectionState.disconnected,
      );
    },
  );
}
