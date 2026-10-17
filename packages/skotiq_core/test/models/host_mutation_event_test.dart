import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('Host mutation event schema', () {
    test('buildHostMutationEvent uses standardized fields', () {
      final event = buildHostMutationEvent(
        entityType: HostMutationEntity.sequence,
        action: HostMutationAction.updated,
        entityId: '42',
        extra: const {'name': 'Test Seq'},
      );

      expect(event.eventType, hostStateChangedEventType);
      expect(event.category, EventCategory.system);
      expect(event.severity, EventSeverity.info);
      expect(event.timestamp, isPositive);
      expect(event.data['entityType'], HostMutationEntity.sequence);
      expect(event.data['action'], HostMutationAction.updated);
      expect(event.data['entityId'], '42');
      expect(event.data['name'], 'Test Seq');
    });

    test('toJson round-trips through fromJson', () {
      final original = buildHostMutationEvent(
        entityType: HostMutationEntity.equipment,
        action: HostMutationAction.connected,
        entityId: 'cam-1',
        extra: const {'deviceType': 'camera', 'deviceId': 'cam-1'},
      );

      final restored = SkotiqEvent.fromJson(original.toJson());
      expect(restored.eventType, hostStateChangedEventType);
      expect(restored.data['entityType'], HostMutationEntity.equipment);
      expect(restored.data['entityId'], 'cam-1');
    });

    test('headless WS wrapper round-trips HostStateChanged', () {
      final original = buildHostMutationEvent(
        entityType: HostMutationEntity.sequence,
        action: HostMutationAction.updated,
        entityId: '12',
      );

      final restored = SkotiqEvent.fromWireJson({
        'type': 'event',
        ...original.toJson(),
      });
      expect(restored.category, EventCategory.system);
      expect(restored.eventType, hostStateChangedEventType);
      expect(restored.data['entityType'], HostMutationEntity.sequence);
      expect(restored.data['entityId'], '12');
    });
  });

  group('HostMutationEventHub', () {
    test('publish invokes wsBroadcast sink', () {
      final hub = HostMutationEventHub();
      addTearDown(hub.dispose);

      SkotiqEvent? wsEvent;
      hub.wsBroadcast = (event) => wsEvent = event;

      hub.publish(
        entityType: HostMutationEntity.guider,
        action: HostMutationAction.connected,
        entityId: 'phd2_guider',
      );

      expect(wsEvent, isNotNull);
      expect(wsEvent!.eventType, hostStateChangedEventType);
      expect(wsEvent!.data['entityId'], 'phd2_guider');
    });

    test('publish reaches active stream listeners', () async {
      final hub = HostMutationEventHub();
      addTearDown(hub.dispose);

      final seen = <SkotiqEvent>[];
      final sub = hub.stream.listen(seen.add);
      addTearDown(sub.cancel);

      hub.publish(
        entityType: HostMutationEntity.sequencer,
        action: HostMutationAction.started,
      );

      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(1));
      expect(seen.single.data['entityType'], HostMutationEntity.sequencer);
    });
  });
}
