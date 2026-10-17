import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/services/switch_channel_service.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

ProviderContainer _container(_MockNetworkBackend backend) => ProviderContainer(
  overrides: [
    backendProvider.overrideWith((ref) => _FixedBackendNotifier(ref, backend)),
  ],
);

Provider<SwitchChannelService> _serviceProvider(_MockNetworkBackend backend) =>
    Provider<SwitchChannelService>(
      (ref) => SwitchChannelService(ref: ref, backend: backend),
    );

void main() {
  test(
    'remote refresh preserves capabilities and numeric write stays remote',
    () async {
      final backend = _MockNetworkBackend();
      when(
        () => backend.getSwitchStatus(deviceId: 'remote:switch:1'),
      ).thenAnswer(
        (_) async => {
          'connected': true,
          'switches': [
            {
              'id': 0,
              'name': 'Mount Power',
              'description': '12V relay',
              'type': 'boolean',
              'value': true,
              'canWrite': false,
            },
            {
              'id': 1,
              'name': 'Dew Heater',
              'description': 'PWM output',
              'type': 'analog',
              'value': 35.0,
              'minValue': 0.0,
              'maxValue': 100.0,
              'step': 5.0,
              'canWrite': true,
            },
          ],
        },
      );
      when(
        () => backend.setSwitch(
          deviceId: 'remote:switch:1',
          switchId: 1,
          value: 60.0,
        ),
      ).thenAnswer((_) async {});

      final serviceProvider = _serviceProvider(backend);
      final container = _container(backend);
      addTearDown(container.dispose);
      final notifier = container.read(switchStateProvider.notifier);
      notifier.setConnecting('remote:switch:1', 'Power Box');
      notifier.setConnected();

      final service = container.read(serviceProvider);
      await service.refreshChannels();

      var state = container.read(switchStateProvider);
      expect(state.channelNames, ['Mount Power', 'Dew Heater']);
      expect(state.channelDescriptions, ['12V relay', 'PWM output']);
      expect(state.channelIsBoolean, [true, false]);
      expect(state.channelValues, [1.0, 35.0]);
      expect(state.channelMinValues, [0.0, 0.0]);
      expect(state.channelMaxValues, [1.0, 100.0]);
      expect(state.channelSteps, [1.0, 5.0]);
      expect(state.channelCanWrite, [false, true]);

      await service.setChannelValue(1, 60);

      verify(
        () => backend.setSwitch(
          deviceId: 'remote:switch:1',
          switchId: 1,
          value: 60.0,
        ),
      ).called(1);
      state = container.read(switchStateProvider);
      expect(state.channelValues, [1.0, 60.0]);
      expect(state.channelStates, [true, true]);
    },
  );

  test('a late refresh cannot overwrite a newer connected switch', () async {
    final backend = _MockNetworkBackend();
    final oldResponse = Completer<Map<String, dynamic>>();
    when(
      () => backend.getSwitchStatus(deviceId: 'remote:switch:old'),
    ).thenAnswer((_) => oldResponse.future);
    when(
      () => backend.getSwitchStatus(deviceId: 'remote:switch:new'),
    ).thenAnswer(
      (_) async => {
        'switches': [
          {'name': 'New host channel', 'type': 'boolean', 'value': true},
        ],
      },
    );

    final container = _container(backend);
    addTearDown(container.dispose);
    final service = container.read(_serviceProvider(backend));
    final notifier = container.read(switchStateProvider.notifier);
    notifier.setConnecting('remote:switch:old', 'Old');
    notifier.setConnected();

    final staleRefresh = service.refreshChannels();
    await pumpEventQueue();
    notifier.setConnecting('remote:switch:new', 'New');
    notifier.setConnected();
    await service.refreshChannels();

    oldResponse.complete({
      'switches': [
        {'name': 'Stale host channel', 'type': 'boolean', 'value': false},
      ],
    });
    await staleRefresh;

    final state = container.read(switchStateProvider);
    expect(state.deviceId, 'remote:switch:new');
    expect(state.channelNames, ['New host channel']);
    expect(state.channelStates, [true]);
  });

  test(
    'a completed write cannot mutate a replacement switch snapshot',
    () async {
      final backend = _MockNetworkBackend();
      final write = Completer<void>();
      when(
        () => backend.setSwitch(
          deviceId: 'remote:switch:old',
          switchId: 0,
          value: true,
        ),
      ).thenAnswer((_) => write.future);

      final container = _container(backend);
      addTearDown(container.dispose);
      final service = container.read(_serviceProvider(backend));
      final notifier = container.read(switchStateProvider.notifier);
      notifier.setConnecting('remote:switch:old', 'Old');
      notifier.setConnected();
      notifier.setChannels(count: 1, names: ['Old'], states: [false]);

      final pending = service.setChannel(0, true);
      await pumpEventQueue();
      notifier.setConnecting('remote:switch:new', 'New');
      notifier.setConnected();
      notifier.setChannels(count: 1, names: ['New'], states: [false]);
      write.complete();
      await pending;

      final state = container.read(switchStateProvider);
      expect(state.deviceId, 'remote:switch:new');
      expect(state.channelNames, ['New']);
      expect(state.channelStates, [false]);
    },
  );

  test(
    'authoritative refresh failures remain observable to the caller',
    () async {
      final backend = _MockNetworkBackend();
      when(
        () => backend.getSwitchStatus(deviceId: 'remote:switch:1'),
      ).thenThrow(StateError('host offline'));
      final container = _container(backend);
      addTearDown(container.dispose);
      final notifier = container.read(switchStateProvider.notifier);
      notifier.setConnecting('remote:switch:1', 'Power Box');
      notifier.setConnected();

      await expectLater(
        container.read(_serviceProvider(backend)).refreshChannels(),
        throwsStateError,
      );
    },
  );
}
