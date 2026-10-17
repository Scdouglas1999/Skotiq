import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('Headless API host mutation publishing', () {
    late ProviderContainer container;
    late List<SkotiqEvent> published;

    setUp(() {
      published = <SkotiqEvent>[];
      container = ProviderContainer();
      container.read(hostMutationEventHubProvider).wsBroadcast = published.add;
    });

    tearDown(() {
      container.read(hostMutationEventHubProvider).wsBroadcast = null;
      container.dispose();
    });

    test(
      'publishHostMutationFromContainer emits standardized HostStateChanged',
      () {
        publishHostMutationFromContainer(
          container,
          entityType: HostMutationEntity.equipment,
          action: HostMutationAction.connected,
          entityId: 'camera-1',
          extra: const {'deviceType': 'camera', 'deviceId': 'camera-1'},
        );

        expect(published, hasLength(1));
        final event = published.single;
        expect(event.eventType, hostStateChangedEventType);
        expect(event.category, EventCategory.system);
        expect(event.data['entityType'], HostMutationEntity.equipment);
        expect(event.data['action'], HostMutationAction.connected);
        expect(event.data['entityId'], 'camera-1');
        expect(event.data['deviceType'], 'camera');
      },
    );

    test(
      'notifySequenceCatalogChangedFromContainer publishes sequence mutation',
      () {
        notifySequenceCatalogChangedFromContainer(
          container,
          sequenceId: 7,
          action: 'saved',
          name: 'LRGB',
        );

        expect(published, hasLength(1));
        final event = published.single;
        expect(event.eventType, hostStateChangedEventType);
        expect(event.data['entityType'], HostMutationEntity.sequence);
        expect(event.data['action'], HostMutationAction.updated);
        expect(event.data['entityId'], '7');
        expect(event.data['name'], 'LRGB');
      },
    );

    test('sequence catalog bus still notifies local listeners', () async {
      final seen = <SequenceCatalogUpdate>[];
      final sub = container
          .read(sequenceCatalogUpdateBusProvider)
          .stream
          .listen(seen.add);
      addTearDown(sub.cancel);

      await Future<void>.delayed(Duration.zero);

      notifySequenceCatalogChangedFromContainer(
        container,
        sequenceId: 3,
        action: 'deleted',
      );

      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(1));
      expect(seen.single.sequenceId, 3);
      expect(seen.single.action, 'deleted');
      expect(published, hasLength(1));
    });
  });
}
