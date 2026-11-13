import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/providers/device_heartbeat_health_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/ui_notification_provider.dart';
import 'package:skotiq_core/src/services/device_reconnect_coordinator.dart';

import '../mocks/mock_backend.dart';
import 'package:skotiq_core/src/models/backend/backend_types.dart';
import 'package:skotiq_core/src/providers/device_service_providers.dart';

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
    // The native policy: the heartbeat reconnects these itself.
    when(() => backend.nativeReconnectedDeviceTypes).thenReturn(const {
      DeviceType.mount,
      DeviceType.guider,
      DeviceType.dome,
      DeviceType.weather,
      DeviceType.coverCalibrator,
    });
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

  SkotiqEvent equipmentEvent(
    String type,
    String deviceId, {
    String deviceType = 'focuser',
    String? message,
  }) => SkotiqEvent(
    timestamp: DateTime.now().millisecondsSinceEpoch,
    severity: type == 'Error' ? EventSeverity.error : EventSeverity.info,
    category: EventCategory.equipment,
    eventType: type,
    data: {
      'device_type': deviceType,
      'device_id': deviceId,
      if (message != null) 'message': message,
    },
  );

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  List<UiNotification> notices() => container.read(uiNotificationProvider);

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
      container
          .read(deviceServiceProvider)
          .connect(DeviceType.focuser, deviceId),
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
      connect: (type, deviceId) async {},
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

  test('a Connected that arrives after its connect failed does not put the '
      'released device back in the slot', () async {
    const deviceId = 'sim_focuser';
    when(
      () => backend.connectDevice(DeviceType.focuser, deviceId),
    ).thenAnswer((_) async {});
    when(
      () => backend.getFocuserStatus(deviceId),
    ).thenThrow(StateError('USB cable unplugged'));
    when(
      () => backend.disconnectDevice(DeviceType.focuser, deviceId),
    ).thenAnswer((_) async {});

    await expectLater(
      container
          .read(deviceServiceProvider)
          .connect(DeviceType.focuser, deviceId),
      throwsA(isA<StateError>()),
    );
    // The driver's opening event and the release's are delivered only now,
    // behind the failure.
    events
      ..add(equipmentEvent('Connected', deviceId))
      ..add(equipmentEvent('Disconnected', deviceId));
    await settle();

    final slot = container.read(focuserStateProvider);
    expect(slot.connectionState, DeviceConnectionState.error);
    expect(slot.deviceId, isNull);
    expect(slot.lastError, isNotNull);
  });

  test('a connect that had failed and then comes up is connected and said '
      'so once', () async {
    const deviceId = 'sim_cover';
    when(
      () => backend.connectDevice(DeviceType.coverCalibrator, deviceId),
    ).thenThrow(TimeoutException('the host did not answer'));

    await expectLater(
      container
          .read(deviceServiceProvider)
          .connect(DeviceType.coverCalibrator, deviceId),
      throwsA(isA<TimeoutException>()),
    );
    expect(
      container.read(coverCalibratorStateProvider).connectionState,
      DeviceConnectionState.error,
    );
    expect(notices(), isEmpty);

    events.add(
      equipmentEvent('Connected', deviceId, deviceType: 'covercalibrator'),
    );
    await settle();

    final slot = container.read(coverCalibratorStateProvider);
    expect(slot.connectionState, DeviceConnectionState.connected);
    expect(slot.deviceId, deviceId);
    expect(slot.lastError, isNull);
    expect(notices().map((n) => n.message), [
      'The cover calibrator connected after all.',
    ]);
    verifyNever(
      () => backend.disconnectDevice(DeviceType.coverCalibrator, deviceId),
    );
  });

  test('the native error of a connect this app made raises no notice of '
      'its own', () async {
    const deviceId = 'sim_focuser';
    when(() => backend.connectDevice(DeviceType.focuser, deviceId)).thenAnswer((
      _,
    ) async {
      events
        ..add(equipmentEvent('Connecting', deviceId))
        ..add(equipmentEvent('Error', deviceId, message: 'no power'));
      // The events are delivered before the call's own failure.
      await settle();
      throw StateError('no power');
    });

    await expectLater(
      container
          .read(deviceServiceProvider)
          .connect(DeviceType.focuser, deviceId),
      throwsA(isA<StateError>()),
    );
    // And again behind it, as the stream is free to do.
    events.add(equipmentEvent('Error', deviceId, message: 'no power'));
    await settle();

    expect(notices(), isEmpty, reason: 'whoever asked for the connect tells');
    final slot = container.read(focuserStateProvider);
    expect(slot.connectionState, DeviceConnectionState.error);
    expect(slot.deviceId, isNull);
    expect(slot.retryDeviceId, deviceId);
  });

  test('a connect somebody else started that fails is told as a device '
      'that did not connect', () async {
    const deviceId = 'sim_focuser';
    events
      ..add(equipmentEvent('Connecting', deviceId))
      ..add(equipmentEvent('Error', deviceId, message: 'no power'));
    await settle();

    expect(notices(), hasLength(1));
    expect(
      notices().single.message,
      contains('The focuser did not connect: no power'),
    );
  });

  test('a failed slot keeps its failure through a Disconnected for the '
      'device', () async {
    const deviceId = 'sim_focuser';
    when(
      () => backend.connectDevice(DeviceType.focuser, deviceId),
    ).thenThrow(StateError('no power'));
    await expectLater(
      container
          .read(deviceServiceProvider)
          .connect(DeviceType.focuser, deviceId),
      throwsA(isA<StateError>()),
    );

    events.add(equipmentEvent('Disconnected', deviceId));
    await settle();

    final slot = container.read(focuserStateProvider);
    expect(slot.connectionState, DeviceConnectionState.error);
    expect(slot.retryDeviceId, deviceId);
  });
}
