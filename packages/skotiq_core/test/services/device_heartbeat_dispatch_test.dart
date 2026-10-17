import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart'
    hide CameraState;
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/device_heartbeat_health_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/services/device_reconnect_coordinator.dart';
import 'package:skotiq_core/src/services/device_service.dart';

import '../mocks/mock_backend.dart';

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

    container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, mockBackend),
        ),
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

    // Disable auto-reconnect so the Disconnected event has no reconnect to
    // schedule: the indicator must then fall back to gray "unknown" rather
    // than getting stuck on a stale value. (With auto-reconnect ON the
    // indicator would correctly read "reconnecting" — covered separately.)
    container.read(cameraStateProvider.notifier).setAutoReconnect(false);

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
    // state, which is what arms the auto-reconnect path.
    //
    // The camera is a Dart-owned reconnect type (native
    // HeartbeatConfig::for_camera has auto_reconnect = false), so the Dart
    // coordinator schedules the reconnect AND surfaces the "reconnecting"
    // indicator immediately — the health dot reads `reconnecting`, not gray
    // "unknown", while a reconnect is in flight.
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
          'a Dart-owned reconnect must light the reconnecting indicator, '
          'not fall back to gray "unknown" while the attempt is in flight',
    );
    expect(
      container.read(cameraStateProvider).connectionState,
      DeviceConnectionState.disconnected,
      reason: 'connection state must transition so auto-reconnect can arm',
    );
  });

  test('native-owned mount heartbeat loss surfaces reconnecting WITHOUT a '
      'competing Dart connect (single-owner de-dup)', () async {
    // DEV-P1 dual-reconnect race. The mount is a native-owned reconnect
    // type (HeartbeatConfig::for_mount sets auto_reconnect = true), so the
    // native reconnection_loop performs the real reconnect. The Dart
    // coordinator must DEFER — it must not schedule its own connect, or the
    // two engines double-connect / thrash the driver — while still lighting
    // the "reconnecting" indicator the native side never emits an event for.
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
    // Give the unawaited reconnect path time to run its synchronous
    // ownership decision. The Dart coordinator's own backoff is 5s, so a
    // 100ms wait is well short of any (incorrect) Dart connect attempt.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(
      container
          .read(deviceHeartbeatHealthProvider.notifier)
          .forDevice(deviceId)
          .health,
      HeartbeatHealth.reconnecting,
      reason: 'native-owned reconnect must still light the indicator',
    );
    expect(
      container.read(mountStateProvider).connectionState,
      DeviceConnectionState.disconnected,
    );
    // The Dart coordinator deferred: it must NOT have driven a connect of
    // its own against the device the native loop already owns.
    verifyNever(() => mockBackend.connectDevice(any(), any()));
  });

  group('DeviceReconnectCoordinator.nativeOwnsReconnect policy table', () {
    // This table MUST mirror the native source of truth exactly:
    // `DeviceManager::get_heartbeat_config(device_type)` →
    // `HeartbeatConfig::for_*()` in
    // native/skotiq_native/bridge/src/device_manager/. A drift here
    // re-opens the dual-reconnect race (Dart competes with the native
    // loop) or strands a device with no reconnect engine at all.
    const nativeOwned = <DeviceType>{
      DeviceType.mount, // for_mount: auto_reconnect = true
      DeviceType.dome, // for_dome: auto_reconnect = true
      DeviceType.weather, // for_weather: auto_reconnect = true
      DeviceType.safetyMonitor, // for_safety_monitor: auto_reconnect = true
      DeviceType.guider, // for_guider: auto_reconnect = true
      DeviceType.coverCalibrator, // for_cover_calibrator: auto_reconnect = true
    };
    const dartOwned = <DeviceType>{
      DeviceType.camera, // for_camera: auto_reconnect = false
      DeviceType.focuser, // for_focuser: auto_reconnect = false
      DeviceType.filterWheel, // for_filter_wheel: auto_reconnect = false
      DeviceType.rotator, // for_rotator: auto_reconnect = false
      DeviceType.switch_, // for_switch: auto_reconnect = false
    };

    test('every DeviceType is classified exactly once', () {
      // Guards against a new DeviceType being added without a matching
      // native-ownership decision (the switch in nativeOwnsReconnect would
      // fail to compile, but the test also documents the full set).
      expect(
        {...nativeOwned, ...dartOwned},
        DeviceType.values.toSet(),
        reason: 'all DeviceTypes must appear in exactly one ownership set',
      );
      expect(nativeOwned.intersection(dartOwned), isEmpty);
    });

    for (final type in nativeOwned) {
      test('${type.name} is native-owned', () {
        expect(DeviceReconnectCoordinator.nativeOwnsReconnect(type), isTrue);
      });
    }
    for (final type in dartOwned) {
      test('${type.name} is Dart-owned', () {
        expect(DeviceReconnectCoordinator.nativeOwnsReconnect(type), isFalse);
      });
    }
  });

  group('DeviceReconnectCoordinator reconnect outcome', () {
    test('connected state is accepted as success', () {
      expect(
        () => DeviceReconnectCoordinator.validateReconnectOutcome(
          type: DeviceType.focuser,
          connectionState: DeviceConnectionState.connected,
        ),
        returnsNormally,
      );
    });

    test('terminal notifier error is not misreported as success', () {
      expect(
        () => DeviceReconnectCoordinator.validateReconnectOutcome(
          type: DeviceType.focuser,
          connectionState: DeviceConnectionState.error,
          lastError: StateError('ASCOM connect failed'),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(contains('Focuser'), contains('ASCOM connect failed')),
          ),
        ),
      );
    });
  });

  test('Dart reconnect coalesces cleanup events, exhausts once, and resets on '
      'authoritative connection', () async {
    var reconnectCalls = 0;
    var shouldFail = true;
    late DeviceReconnectCoordinator coordinator;

    final coordinatorProvider = Provider<DeviceReconnectCoordinator>((ref) {
      coordinator = DeviceReconnectCoordinator(
        ref: ref,
        backend: mockBackend,
        resumeSequence: () async {},
        pauseSequence: () async {},
        surfaceReconnecting: (deviceId, {attempt = 0, maxAttempts = 0}) {},
        retryDelays: const [
          Duration(milliseconds: 2),
          Duration(milliseconds: 2),
          Duration(milliseconds: 2),
        ],
        reconnectAttempt: (type, deviceId) async {
          reconnectCalls++;
          // Reproduce the backend cleanup Disconnected event racing the
          // timer's own failure path.
          unawaited(coordinator.attemptReconnect(type, deviceId));
          if (shouldFail) {
            throw StateError('driver unavailable');
          }
        },
      );
      return coordinator;
    });

    coordinator = container.read(coordinatorProvider);
    const deviceId = 'ascom:ASCOM.ZWO.EAF.Focuser';

    // Duplicate disconnects before the first timer fires must also coalesce.
    await coordinator.attemptReconnect(DeviceType.focuser, deviceId);
    await coordinator.attemptReconnect(DeviceType.focuser, deviceId);
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(
      reconnectCalls,
      DeviceReconnectCoordinator.maxReconnectAttempts,
      reason: 'one bounded 1/3..3/3 batch must run',
    );

    // Late cleanup events after exhaustion must not open a fresh batch.
    await coordinator.attemptReconnect(DeviceType.focuser, deviceId);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(reconnectCalls, DeviceReconnectCoordinator.maxReconnectAttempts);

    // A real/manual connection is the explicit reset condition.
    shouldFail = false;
    await coordinator.onAuthoritativeDeviceConnected('focuser', deviceId);
    await coordinator.attemptReconnect(DeviceType.focuser, deviceId);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(reconnectCalls, DeviceReconnectCoordinator.maxReconnectAttempts + 1);

    coordinator.cancelAll();
  });

  test(
    'Heartbeat dispatch does not interfere with the Disconnected handler',
    () async {
      // Heartbeat routing must not break connection-state handling. A
      // Disconnected event for a device with no heartbeat entry at all must
      // leave the heartbeat clear a no-op that does not raise, and the event
      // must still reach the existing handler.
      const deviceId = 'native:zwo:0';

      expect(
        () => events.add(
          makeEvent('Disconnected', {
            'device_type': 'camera',
            'device_id': deviceId,
          }),
        ),
        returnsNormally,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    },
  );
}
