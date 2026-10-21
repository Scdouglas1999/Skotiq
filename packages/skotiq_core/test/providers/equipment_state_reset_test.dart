import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:skotiq_core/skotiq_core.dart';

import '../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

void main() {
  setUpAll(() {
    registerFallbackValue(const Stream<SkotiqEvent>.empty());
  });

  void connectEverything(ProviderContainer container) {
    container.read(cameraStateProvider.notifier)
      ..setConnecting('cam')
      ..setConnected();
    container.read(mountStateProvider.notifier)
      ..setConnecting('mnt')
      ..setConnected();
    container.read(focuserStateProvider.notifier)
      ..setConnecting('foc')
      ..setConnected();
    container.read(filterWheelStateProvider.notifier)
      ..setConnecting('fw')
      ..setConnected();
    container.read(guiderStateProvider.notifier)
      ..setConnecting('gdr')
      ..setConnected();
    container.read(rotatorStateProvider.notifier)
      ..setConnecting('rot')
      ..setConnected();
    container.read(domeStateProvider.notifier)
      ..setConnecting('dome')
      ..setConnected();
    container.read(weatherStateProvider.notifier)
      ..setConnecting('wx')
      ..setConnected();
    container.read(safetyMonitorStateProvider.notifier)
      ..setConnecting('sm')
      ..setConnected();
    container.read(switchStateProvider.notifier)
      ..setConnecting('sw')
      ..setConnected();
    container.read(coverCalibratorStateProvider.notifier)
      ..setConnecting('cc')
      ..setConnected();
    container
        .read(deviceHeartbeatHealthProvider.notifier)
        .applyHeartbeatStarted(deviceId: 'cam');
  }

  group('resetAllEquipmentStateNotifiers', () {
    test('clears every device including the switch, and heartbeat health', () {
      final container = ProviderContainer(
        overrides: [inMemoryDatabaseOverride()],
      );
      addTearDown(container.dispose);

      connectEverything(container);
      resetAllEquipmentStateNotifiers(container);

      expect(
        container.read(switchStateProvider).connectionState,
        DeviceConnectionState.disconnected,
      );
      expect(
        container.read(guiderStateProvider).connectionState,
        DeviceConnectionState.disconnected,
      );
      expect(container.read(deviceHeartbeatHealthProvider), isEmpty);
    });

    test('includeGuider: false leaves the guider chip alone', () {
      final container = ProviderContainer(
        overrides: [inMemoryDatabaseOverride()],
      );
      addTearDown(container.dispose);

      connectEverything(container);
      resetAllEquipmentStateNotifiers(container, includeGuider: false);

      expect(
        container.read(guiderStateProvider).connectionState,
        DeviceConnectionState.connected,
      );
      expect(
        container.read(switchStateProvider).connectionState,
        DeviceConnectionState.disconnected,
      );
    });
  });

  group('slave reconnect hydration', () {
    test('drops the stale switch card and stale heartbeat health', () async {
      final backend = _MockNetworkBackend();
      when(() => backend.sequencerGetStatus()).thenAnswer(
        (_) async => const SequencerStatus(state: 'Idle', progress: 0),
      );
      when(
        () => backend.getConnectedDevices(),
      ).thenAnswer((_) async => const []);

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          loggingServiceProvider.overrideWithValue(LoggingService()),
        ],
      );
      addTearDown(container.dispose);

      connectEverything(container);

      await hydrateRemoteSessionState(container, backend);

      expect(
        container.read(switchStateProvider).connectionState,
        DeviceConnectionState.disconnected,
      );
      expect(container.read(deviceHeartbeatHealthProvider), isEmpty);
    });
  });

  group('slave periodic re-hydration', () {
    test(
      'a device the host still reports never passes through disconnected',
      () async {
        final backend = _MockNetworkBackend();
        when(() => backend.sequencerGetStatus()).thenAnswer(
          (_) async => const SequencerStatus(state: 'Idle', progress: 0),
        );
        when(() => backend.getConnectedDevices()).thenAnswer(
          (_) async => const [
            DeviceInfo(
              id: 'foc',
              name: 'EAF',
              deviceType: DeviceType.focuser,
              driverType: DriverType.native,
              description: '',
              driverVersion: '1.0',
            ),
          ],
        );

        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
            loggingServiceProvider.overrideWithValue(LoggingService()),
          ],
        );
        addTearDown(container.dispose);

        connectEverything(container);
        final seen = <DeviceConnectionState>[];
        container.listen<FocuserState>(
          focuserStateProvider,
          (_, next) => seen.add(next.connectionState),
        );

        try {
          await hydrateRemoteSessionState(
            container,
            backend,
            refreshCurrentFrame: false,
          );
        } catch (_) {
          // Later hydration steps are not stubbed; the device pass runs first.
        }

        expect(seen, isNot(contains(DeviceConnectionState.disconnected)));
        expect(
          container.read(focuserStateProvider).connectionState,
          DeviceConnectionState.connected,
        );
        expect(
          container.read(cameraStateProvider).connectionState,
          DeviceConnectionState.disconnected,
          reason: 'the camera is no longer reported, so its card is dropped',
        );
        expect(
          container.read(guiderStateProvider).connectionState,
          DeviceConnectionState.connected,
          reason: 'the guider is hydrated from phd2/status, not this list',
        );
      },
    );
  });
}
