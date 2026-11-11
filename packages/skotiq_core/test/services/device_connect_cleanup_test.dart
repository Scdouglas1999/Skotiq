import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart' hide CameraState;
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/device_heartbeat_health_provider.dart';
import 'package:skotiq_core/src/services/device_reconnect_coordinator.dart';
import 'package:skotiq_core/src/services/device_service.dart';

import '../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

final _refProvider = Provider<Ref>((ref) => ref);

void main() {
  late ProviderContainer container;
  late MockBackend backend;
  late StreamController<SkotiqEvent> events;

  setUpAll(registerMocktailFallbackValues);

  setUp(() {
    backend = MockBackend();
    events = StreamController<SkotiqEvent>.broadcast();
    when(() => backend.eventStream).thenAnswer((_) => events.stream);
    when(
      () => backend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());
    container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
      ],
    );
    container.read(deviceServiceProvider);
  });

  tearDown(() async {
    await events.close();
    container.dispose();
  });

  SkotiqEvent equipmentEvent(String type, String deviceId) => SkotiqEvent(
    timestamp: DateTime.now().millisecondsSinceEpoch,
    severity: EventSeverity.info,
    category: EventCategory.equipment,
    eventType: type,
    data: {'device_type': 'focuser', 'device_id': deviceId},
  );

  test('the disconnect that lets go of a focuser whose bring-up failed is '
      'not a dropout', () async {
    const deviceId = 'sim_focuser';
    // The driver opens and says so before the app reads the focuser; the
    // clean-up disconnect is announced the same way.
    when(() => backend.connectDevice(DeviceType.focuser, deviceId)).thenAnswer((
      _,
    ) async {
      events.add(equipmentEvent('Connected', deviceId));
    });
    when(
      () => backend.getFocuserStatus(deviceId),
    ).thenThrow(StateError('USB cable unplugged'));
    when(
      () => backend.disconnectDevice(DeviceType.focuser, deviceId),
    ).thenAnswer((_) async {
      events.add(equipmentEvent('Disconnected', deviceId));
    });

    await expectLater(
      container.read(deviceServiceProvider).connect(DeviceType.focuser, deviceId),
      throwsA(isA<StateError>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    verify(
      () => backend.disconnectDevice(DeviceType.focuser, deviceId),
    ).called(1);
    expect(
      container
          .read(deviceHeartbeatHealthProvider.notifier)
          .forDevice(deviceId)
          .health,
      isNot(HeartbeatHealth.reconnecting),
      reason: 'a connect the user made that failed is reported, not retried',
    );
  });

  test('a reconnect whose driver opens but whose bring-up fails counts '
      'toward the limit', () async {
    const deviceId = 'sim_focuser';
    var attempts = 0;
    late DeviceReconnectCoordinator coordinator;
    coordinator = DeviceReconnectCoordinator(
      ref: container.read(_refProvider),
      backend: backend,
      resumeSequence: () async {},
      pauseSequence: () async {},
      surfaceReconnecting: (deviceId, {attempt = 0, maxAttempts = 0}) {},
      retryDelays: const [Duration(milliseconds: 1)],
      reconnectAttempt: (type, id) async {
        attempts++;
        // The driver reports Connected as soon as it opens.
        await coordinator.onAuthoritativeDeviceConnected(type.name, id);
        throw StateError('the focuser did not report its position');
      },
    );
    addTearDown(coordinator.cancelAll);

    await coordinator.attemptReconnect(DeviceType.focuser, deviceId);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(attempts, DeviceReconnectCoordinator.maxReconnectAttempts);
  });
}
