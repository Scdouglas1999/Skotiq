import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('remote Home Assistant settings come from the imaging host', () async {
    final events = StreamController<SkotiqEvent>.broadcast();
    addTearDown(events.close);
    final backend = _MockNetworkBackend();
    var hostSettings = const HomeAssistantHostSettings(
      config: HomeAssistantDiscoveryConfig(
        enabled: true,
        deviceName: 'Remote Observatory',
        allowControl: true,
      ),
      broker: MqttTransportConfig(
        host: 'host-broker.local',
        port: 8883,
        username: 'skotiq',
        topic: 'skotiq/host',
        qos: 1,
        useTls: true,
        clientId: 'skotiq-host',
      ),
      brokerPasswordConfigured: true,
    );
    when(() => backend.eventStream).thenAnswer((_) => events.stream);
    when(
      () => backend.getHomeAssistantHostSettings(),
    ).thenAnswer((_) async => hostSettings);

    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      remoteHomeAssistantHostSettingsProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    final initial = await container.read(
      remoteHomeAssistantHostSettingsProvider.future,
    );
    expect(initial!.config.deviceName, 'Remote Observatory');
    expect(initial.broker.host, 'host-broker.local');
    expect(initial.broker.password, isNull);
    expect(initial.brokerPasswordConfigured, isTrue);
    verify(() => backend.getHomeAssistantHostSettings()).called(1);

    hostSettings = const HomeAssistantHostSettings(
      config: HomeAssistantDiscoveryConfig(deviceName: 'Updated on host'),
      broker: MqttTransportConfig(host: 'replacement-broker.local'),
      brokerPasswordConfigured: false,
    );
    events.add(
      buildHostMutationEvent(
        entityType: HostMutationEntity.settings,
        action: HostMutationAction.updated,
        extra: const {'namespace': 'home-assistant'},
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final updated = await container.read(
      remoteHomeAssistantHostSettingsProvider.future,
    );
    expect(updated!.config.deviceName, 'Updated on host');
    expect(updated.broker.host, 'replacement-broker.local');
    expect(updated.brokerPasswordConfigured, isFalse);
    verify(() => backend.getHomeAssistantHostSettings()).called(1);
  });
}
