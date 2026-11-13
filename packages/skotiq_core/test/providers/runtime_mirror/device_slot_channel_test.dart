// A linked client shows the host's devices as the host's own window does:
// which device each slot holds, its connection state, and its readings.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import 'mirror_link.dart';

const _slotInterval = Duration(milliseconds: 1100);

void _connect(
  DeviceConnectionNotifier notifier,
  String deviceId,
  String deviceName,
) {
  notifier.setConnecting(deviceId, deviceName);
  notifier.setConnected();
}

/// What a client's own connect needs from its link to the host.
void _clientConnects(MockLinkBackend backend) {
  when(
    () => backend.polarAlignmentEvents,
  ).thenAnswer((_) => const Stream.empty());
  when(() => backend.getConnectedDevices()).thenAnswer((_) async => const []);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every row of the device table has a channel', () {
    final host = mirrorHost();
    final channels = host.container.read(runtimeMirrorChannelsProvider);
    for (final slot in deviceSlots) {
      expect(
        runtimeChannelFor(channels, 'device.${slot.wireNames.first}'),
        isA<DeviceSlotChannel>(),
        reason: slot.label,
      );
    }
  });

  test('a client that links after the host connected its devices shows them '
      'with their readings', () async {
    final host = mirrorHost();
    final camera = host.container.read(cameraStateProvider.notifier);
    _connect(camera, 'cam-1', 'Main camera');
    camera
      ..updateTemperature(-9.8, 41)
      ..setTargetTemp(-10)
      ..setCooling(true)
      ..updateReadout(gain: 100, offset: 50, binX: 2, binY: 2);
    final focuser = host.container.read(focuserStateProvider.notifier);
    focuser.setConnecting('foc-1', 'Focuser');
    focuser
      ..setConnected(
        maxPosition: 50000,
        stepSize: 1.2,
        isAbsolute: true,
        hasTemperature: true,
      )
      ..updatePosition(25010)
      ..updateTemperature(4.5);
    final wheel = host.container.read(filterWheelStateProvider.notifier);
    wheel.setConnecting('fw-1', 'Wheel');
    wheel
      ..setConnected(filterNames: const ['L', 'R', 'G'])
      ..updatePosition(1);
    await settle(_slotInterval);

    final client = mirrorClient(host.container);
    await hydrateHostRuntimeState(client.container, client.backend);

    final shownCamera = client.container.read(cameraStateProvider);
    expect(shownCamera.connectionState, DeviceConnectionState.connected);
    expect(shownCamera.deviceId, 'cam-1');
    expect(shownCamera.deviceName, 'Main camera');
    expect(shownCamera.temperature, -9.8);
    expect(shownCamera.coolerPower, 41);
    expect(shownCamera.targetTemp, -10);
    expect(shownCamera.isCooling, isTrue);
    expect(shownCamera.gain, 100);
    expect(shownCamera.offset, 50);
    expect(shownCamera.binning, '2x2');

    final shownFocuser = client.container.read(focuserStateProvider);
    expect(shownFocuser.connectionState, DeviceConnectionState.connected);
    expect(shownFocuser.position, 25010);
    expect(shownFocuser.maxPosition, 50000);
    expect(shownFocuser.isAbsolute, isTrue);
    expect(shownFocuser.temperature, 4.5);

    final shownWheel = client.container.read(filterWheelStateProvider);
    expect(shownWheel.filterNames, ['L', 'R', 'G']);
    expect(shownWheel.currentFilterName, 'R');

    expect(
      client.container.read(rotatorStateProvider).connectionState,
      DeviceConnectionState.disconnected,
    );
  });

  test('a mount reading reaches the client as one state change', () async {
    final host = mirrorHost();
    final mount = host.container.read(mountStateProvider.notifier);
    _connect(mount, 'mount-1', 'Mount');
    mount
      ..updatePosition(3.5, 40, 62, 180)
      ..setParked(false)
      ..setTracking(true);
    await settle(_slotInterval);
    final client = mirrorClient(host.container);
    await hydrateHostRuntimeState(client.container, client.backend);
    expect(client.container.read(mountStateProvider).isTracking, isTrue);
    expect(client.container.read(mountStateProvider).isParked, isFalse);

    var changes = 0;
    client.container.listen(mountStateProvider, (_, _) => changes++);
    mount.updatePosition(3.5, 40, 61.5, 181);
    await settle(_slotInterval);
    await hydrateHostRuntimeState(client.container, client.backend);

    expect(client.container.read(mountStateProvider).altitude, 61.5);
    expect(client.container.read(mountStateProvider).azimuth, 181);
    expect(changes, 1);
  });

  test('a tracking mount that drifts less than the cards show sends '
      'nothing', () async {
    final host = mirrorHost();
    final mount = host.container.read(mountStateProvider.notifier);
    _connect(mount, 'mount-1', 'Mount');
    mount.updatePosition(3.5, 40, 62.01, 180.02);
    await settle(_slotInterval);
    host.sent.clear();

    mount.updatePosition(3.5, 40, 62.03, 180.04);
    await settle(_slotInterval);
    expect(host.sent.where((u) => u.channel == 'device.mount'), isEmpty);

    mount.updatePosition(3.5, 40, 62.11, 180.04);
    await settle(_slotInterval);
    final sent = host.sent.where((u) => u.channel == 'device.mount');
    expect(sent, hasLength(1));
    expect((sent.single.value?['readings'] as Map)['altitude'], 62.1);
  });

  test('the periodic re-read of unchanged devices changes no client state', () async {
    final host = mirrorHost();
    _connect(host.container.read(mountStateProvider.notifier), 'm', 'Mount');
    _connect(host.container.read(focuserStateProvider.notifier), 'f', 'Foc');
    _connect(host.container.read(filterWheelStateProvider.notifier), 'w', 'W');
    _connect(host.container.read(guiderStateProvider.notifier), 'g', 'Guider');
    await settle(_slotInterval);
    final client = mirrorClient(host.container);
    await hydrateHostRuntimeState(client.container, client.backend);

    var changes = 0;
    for (final slot in deviceSlots) {
      client.container.listen(slot.state, (_, _) => changes++);
    }
    await hydrateHostRuntimeState(client.container, client.backend);
    await hydrateHostRuntimeState(client.container, client.backend);

    expect(changes, 0);
  });

  test('a device the host disconnects leaves the client, and the reason a '
      'device dropped arrives with it', () async {
    final host = mirrorHost();
    final camera = host.container.read(cameraStateProvider.notifier);
    _connect(camera, 'cam-1', 'Main camera');
    await settle(_slotInterval);
    final client = mirrorClient(host.container);
    await hydrateHostRuntimeState(client.container, client.backend);
    expect(client.container.read(cameraStateProvider).deviceId, 'cam-1');

    camera.setError(StateError('USB link dropped'));
    await settle(_slotInterval);
    await hydrateHostRuntimeState(client.container, client.backend);
    final dropped = client.container.read(cameraStateProvider);
    expect(dropped.connectionState, DeviceConnectionState.error);
    expect(dropped.lastError?.message, contains('USB link dropped'));

    camera.setDisconnected();
    await settle(_slotInterval);
    await hydrateHostRuntimeState(client.container, client.backend);
    final gone = client.container.read(cameraStateProvider);
    expect(gone.connectionState, DeviceConnectionState.disconnected);
    expect(gone.deviceId, isNull);
  });

  test('a connect tried from the client that failed keeps showing why while '
      'the host slot stays empty', () async {
    final host = mirrorHost();
    final client = mirrorClient(host.container);
    await hydrateHostRuntimeState(client.container, client.backend);
    final rotator = client.container.read(rotatorStateProvider.notifier);
    rotator.setConnecting('rot-1', 'Rotator');
    rotator.connectFailed(StateError('No such device'));

    await hydrateHostRuntimeState(client.container, client.backend);

    final shown = client.container.read(rotatorStateProvider);
    expect(shown.connectionState, DeviceConnectionState.error);
    expect(shown.lastError?.message, contains('No such device'));
  });

  test('a state the client showed for a command the host refused goes back '
      'to the host\'s at the next re-read', () async {
    final host = mirrorHost();
    final mount = host.container.read(mountStateProvider.notifier);
    _connect(mount, 'mount-1', 'Mount');
    mount.setParked(true);
    await settle(_slotInterval);
    final client = mirrorClient(host.container);
    await hydrateHostRuntimeState(client.container, client.backend);

    // The client's Unpark button shows the mount unparked; the host never
    // unparks it.
    client.container.read(mountStateProvider.notifier).setParked(false);
    await hydrateHostRuntimeState(client.container, client.backend);

    expect(client.container.read(mountStateProvider).isParked, isTrue);
  });

  test('an exposure the client follows from events is not ended by a camera '
      'reading', () async {
    final host = mirrorHost();
    final camera = host.container.read(cameraStateProvider.notifier);
    _connect(camera, 'cam-1', 'Main camera');
    await settle(_slotInterval);
    final client = mirrorClient(host.container);
    await hydrateHostRuntimeState(client.container, client.backend);
    client.container
        .read(cameraStateProvider.notifier)
        .setExposing(true, progress: 0.4);

    camera.updateTemperature(-10, 40);
    await settle(_slotInterval);
    await hydrateHostRuntimeState(client.container, client.backend);

    final shown = client.container.read(cameraStateProvider);
    expect(shown.temperature, -10);
    expect(shown.isExposing, isTrue);
    expect(shown.exposureProgress, 0.4);
  });

  test('each re-read says the host still holds the camera, so it does not '
      'go unheard', () async {
    final host = mirrorHost();
    _connect(host.container.read(cameraStateProvider.notifier), 'c', 'Cam');
    await settle(_slotInterval);
    final client = mirrorClient(host.container);
    await hydrateHostRuntimeState(client.container, client.backend);
    final first = client.container
        .read(cameraStateProvider)
        .lastSuccessfulCommunication!;

    await settle(const Duration(milliseconds: 20));
    await hydrateHostRuntimeState(client.container, client.backend);

    final camera = client.container.read(cameraStateProvider);
    expect(camera.lastSuccessfulCommunication!.isAfter(first), isTrue);
    expect(camera.isHealthy, isTrue);
  });

  group('what the client does with a slot it did not get from the host', () {
    // A linked client's Disconnect all let go of the guide camera first; the
    // host's notice of that emptied the client's camera slot, so the client
    // never asked for the imaging camera and the host kept it connected.
    test('the host letting go of the guide camera leaves the imaging camera '
        'in its slot', () async {
      final host = mirrorHost();
      final camera = host.container.read(cameraStateProvider.notifier);
      _connect(camera, 'sim_camera_1', 'Simulated Camera');
      await settle(_slotInterval);
      final client = mirrorClient(host.container);
      await hydrateHostRuntimeState(client.container, client.backend);

      // The host's own window applies the guider releasing its camera; the
      // camera slot is not the guide camera's.
      await applyRemoteSyncEvent(
        host.container,
        buildHostMutationEvent(
          entityType: HostMutationEntity.equipment,
          action: HostMutationAction.disconnected,
          entityId: 'sim_camera_2',
          extra: {'deviceType': 'camera', 'deviceId': 'sim_camera_2'},
        ),
      );
      await settle(_slotInterval);
      await hydrateHostRuntimeState(client.container, client.backend);

      final shown = client.container.read(cameraStateProvider);
      expect(shown.deviceId, 'sim_camera_1');
      expect(shown.connectionState, DeviceConnectionState.connected);

      camera.setDisconnected();
      await settle(_slotInterval);
      await hydrateHostRuntimeState(client.container, client.backend);
      expect(
        client.container.read(cameraStateProvider).connectionState,
        DeviceConnectionState.disconnected,
      );
    });

    test('a slot showing a failed connect keeps showing it through the '
        'host\'s Disconnected and its empty slot', () async {
      final host = mirrorHost();
      final client = mirrorClient(host.container);
      client.container.read(focuserStateProvider.notifier)
        ..setConnecting('sim_focuser_1', 'Simulated Focuser')
        ..connectFailed(StateError('unplugged'));

      await applyRemoteSyncEvent(
        client.container,
        const SkotiqEvent(
          timestamp: 1,
          severity: EventSeverity.info,
          category: EventCategory.equipment,
          eventType: 'Disconnected',
          data: {'device_type': 'focuser', 'device_id': 'sim_focuser_1'},
        ),
        networkBackend: client.backend,
      );
      await hydrateHostRuntimeState(client.container, client.backend);

      final slot = client.container.read(focuserStateProvider);
      expect(slot.connectionState, DeviceConnectionState.error);
      expect(slot.retryDeviceId, 'sim_focuser_1');
    });

    // The host's refusal can reach a client ahead of the host's value from
    // while the connect ran; that value put the failed slot back to
    // connecting, where nothing ended it.
    test('a host value from before the refusal of this client\'s connect '
        'leaves the slot failed', () async {
      final client = mirrorClient(
        null,
        snapshot: () => const [
          HostRuntimeUpdate(
            channel: 'device.focuser',
            revision: 5,
            value: {
              'state': 'connecting',
              'deviceId': 'sim_focuser_1',
              'deviceName': 'Simulated Focuser',
            },
          ),
        ],
      );
      _clientConnects(client.backend);
      when(
        () => client.backend.connectDevice(DeviceType.focuser, 'sim_focuser_1'),
      ).thenThrow(StateError('unplugged'));
      await expectLater(
        client.container
            .read(deviceServiceProvider)
            .connect(DeviceType.focuser, 'sim_focuser_1'),
        throwsA(isA<StateError>()),
      );

      await hydrateHostRuntimeState(client.container, client.backend);

      final slot = client.container.read(focuserStateProvider);
      expect(slot.connectionState, DeviceConnectionState.error);
      expect(slot.retryDeviceId, 'sim_focuser_1');
    });

    test('a connect this client asked for and still in flight is not undone '
        'by a host that does not show the device yet', () async {
      final host = mirrorHost();
      final client = mirrorClient(host.container);
      _clientConnects(client.backend);
      final hostAnswers = Completer<void>();
      when(
        () => client.backend.connectDevice(DeviceType.focuser, 'sim_focuser_1'),
      ).thenAnswer((_) => hostAnswers.future);
      final connecting = client.container
          .read(deviceServiceProvider)
          .connect(DeviceType.focuser, 'sim_focuser_1');
      await settle();
      expect(
        client.container.read(focuserStateProvider).connectionState,
        DeviceConnectionState.connecting,
      );

      await hydrateHostRuntimeState(client.container, client.backend);
      await mirrorDevicesOfOlderHost(
        client.container,
        client.backend,
        isCurrent: () => true,
      );

      final slot = client.container.read(focuserStateProvider);
      expect(slot.connectionState, DeviceConnectionState.connecting);
      expect(slot.deviceId, 'sim_focuser_1');
      hostAnswers.completeError(StateError('gave up'));
      await expectLater(connecting, throwsA(isA<StateError>()));
    });

    test('a slot holding no device is never touched', () async {
      final host = mirrorHost();
      final client = mirrorClient(host.container);
      var changes = 0;
      for (final slot in deviceSlots) {
        client.container.listen(slot.state, (_, _) => changes++);
      }
      await hydrateHostRuntimeState(client.container, client.backend);
      await hydrateHostRuntimeState(client.container, client.backend);
      expect(changes, 0);
    });
  });

  group('a host older than the device channels', () {
    final olderHostState = [
      const HostRuntimeUpdate(
        channel: 'scheduledStart',
        revision: 10,
        value: null,
      ),
    ];
    DeviceInfo device(String id, String name, DeviceType type) => DeviceInfo(
      id: id,
      name: name,
      deviceType: type,
      driverType: DriverType.simulator,
      description: '',
      driverVersion: '',
    );

    test('shows which devices it has connected, and says once that it '
        'needs an update', () async {
      final client = mirrorClient(null, snapshot: () => olderHostState);
      when(() => client.backend.getConnectedDevices()).thenAnswer(
        (_) async => [
          device('cam-1', 'Main camera', DeviceType.camera),
          device('mount-1', 'Mount', DeviceType.mount),
        ],
      );
      Future<void> link() async {
        await hydrateHostRuntimeState(client.container, client.backend);
        await mirrorDevicesOfOlderHost(
          client.container,
          client.backend,
          isCurrent: () => true,
        );
      }

      await link();
      await link();

      final camera = client.container.read(cameraStateProvider);
      expect(camera.connectionState, DeviceConnectionState.connected);
      expect(camera.deviceName, 'Main camera');
      expect(camera.temperature, isNull);
      expect(
        client.container.read(mountStateProvider).connectionState,
        DeviceConnectionState.connected,
      );
      expect(
        client.container.read(focuserStateProvider).connectionState,
        DeviceConnectionState.disconnected,
      );
      final notices = client.container.read(uiNotificationProvider);
      expect(notices, hasLength(1));
      expect(notices.single.title, 'Host needs an update');

      when(
        () => client.backend.getConnectedDevices(),
      ).thenAnswer((_) async => const []);
      await link();
      expect(
        client.container.read(cameraStateProvider).connectionState,
        DeviceConnectionState.disconnected,
      );
    });

    test('a host that sends the device channels is not asked for its '
        'device list', () async {
      final host = mirrorHost();
      final client = mirrorClient(host.container);
      await hydrateHostRuntimeState(client.container, client.backend);
      await mirrorDevicesOfOlderHost(
        client.container,
        client.backend,
        isCurrent: () => true,
      );
      verifyNever(() => client.backend.getConnectedDevices());
      expect(client.container.read(uiNotificationProvider), isEmpty);
    });
  });

  test('a client older than a channel ignores it', () async {
    final client = mirrorClient(
      null,
      snapshot: () => [
        const HostRuntimeUpdate(
          channel: 'device.spectrograph',
          revision: 10,
          value: {'state': 'connected', 'deviceId': 'spec-1'},
        ),
      ],
    );
    await hydrateHostRuntimeState(client.container, client.backend);
    expect(
      client.container.read(cameraStateProvider).connectionState,
      DeviceConnectionState.disconnected,
    );
  });
}
