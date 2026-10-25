import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/src/backend/bridge_event_mapper.dart';
import 'package:skotiq_core/src/models/backend/event_types.dart' as core;

void main() {
  group('bridgeEventFromCoreEvent', () {
    test('reconstructs RecoveryStarted typed sequencer payload', () {
      final now = DateTime.utc(2026, 5, 23, 12);
      final coreEvent = core.SkotiqEvent(
        timestamp: now.millisecondsSinceEpoch,
        severity: core.EventSeverity.critical,
        category: core.EventCategory.sequencer,
        eventType: 'RecoveryStarted',
        data: recoveryFieldsFromTyped(
          startedAtIso: now.toIso8601String(),
          causeKind: 'GuideStarLost',
          causeCustomLabel: null,
          lastAttemptAtIso: now.toIso8601String(),
          attemptCount: 1,
          maxAttempts: 9,
          retryIntervalSecs: 600.0,
          maxDurationSecs: 5400.0,
          phase: 'Waiting',
          lastError: 'star lost',
        ),
      );

      final bridgeEvent = bridgeEventFromCoreEvent(coreEvent);
      expect(bridgeEvent.category, bridge.EventCategory.sequencer);
      expect(bridgeEvent.payload, isA<bridge.EventPayload_Sequencer>());

      final inner =
          (bridgeEvent.payload as bridge.EventPayload_Sequencer).field0;
      expect(inner, isA<bridge.SequencerEvent_RecoveryStarted>());
      final recovery = inner as bridge.SequencerEvent_RecoveryStarted;
      expect(recovery.causeKind, 'GuideStarLost');
      expect(recovery.attemptCount, 1);
      expect(recovery.maxAttempts, 9);
      expect(recovery.phase, 'Waiting');
      expect(recovery.lastError, 'star lost');
    });

    test('reconstructs RecoveryGaveUp with aborted_by_user flag', () {
      final now = DateTime.utc(2026, 5, 23, 12, 30);
      final coreEvent = core.SkotiqEvent(
        timestamp: now.millisecondsSinceEpoch,
        severity: core.EventSeverity.critical,
        category: core.EventCategory.sequencer,
        eventType: 'RecoveryGaveUp',
        data: recoveryFieldsFromTyped(
          startedAtIso: now.toIso8601String(),
          causeKind: 'SlewFailed',
          causeCustomLabel: null,
          lastAttemptAtIso: now.toIso8601String(),
          attemptCount: 3,
          maxAttempts: 3,
          retryIntervalSecs: 120.0,
          maxDurationSecs: 3600.0,
          phase: 'GaveUp',
          lastError: 'timeout',
          abortedByUser: true,
        ),
      );

      final bridgeEvent = bridgeEventFromCoreEvent(coreEvent);
      final inner =
          (bridgeEvent.payload as bridge.EventPayload_Sequencer).field0;
      expect(inner, isA<bridge.SequencerEvent_RecoveryGaveUp>());
      final gaveUp = inner as bridge.SequencerEvent_RecoveryGaveUp;
      expect(gaveUp.abortedByUser, isTrue);
      expect(gaveUp.causeKind, 'SlewFailed');
    });

    test('reconstructs guiding lost-star for scheduler triggers', () {
      const coreEvent = core.SkotiqEvent(
        timestamp: 1,
        severity: core.EventSeverity.warning,
        category: core.EventCategory.guiding,
        eventType: 'StarLost',
        data: {},
      );

      final bridgeEvent = bridgeEventFromCoreEvent(coreEvent);
      final inner = (bridgeEvent.payload as bridge.EventPayload_Guiding).field0;
      expect(inner, isA<bridge.GuidingEvent_LostStar>());
    });

    test('a settle timeout and a stop reason cross the wire as themselves', () {
      final settle = bridgeEventFromCoreEvent(
        const core.SkotiqEvent(
          timestamp: 1,
          severity: core.EventSeverity.warning,
          category: core.EventCategory.guiding,
          eventType: 'SettleTimedOut',
          data: {'error': 'timed-out waiting for guider to settle'},
        ),
      );
      final settleInner =
          (settle.payload as bridge.EventPayload_Guiding).field0;
      expect(settleInner, isA<bridge.GuidingEvent_SettleTimedOut>());
      expect(settleInner, isNot(isA<bridge.GuidingEvent_LostStar>()));

      final reason = bridgeEventFromCoreEvent(
        const core.SkotiqEvent(
          timestamp: 1,
          severity: core.EventSeverity.info,
          category: core.EventCategory.guiding,
          eventType: 'StopReason',
          data: {'reason': 'meridian_flip'},
        ),
      );
      final reasonInner =
          (reason.payload as bridge.EventPayload_Guiding).field0;
      expect(
        (reasonInner as bridge.GuidingEvent_StopReason).reason,
        'meridian_flip',
      );
    });

    test('reconstructs mount park completed for scheduler triggers', () {
      const coreEvent = core.SkotiqEvent(
        timestamp: 1,
        severity: core.EventSeverity.info,
        category: core.EventCategory.equipment,
        eventType: 'MountParkCompleted',
        data: {},
      );

      final bridgeEvent = bridgeEventFromCoreEvent(coreEvent);
      final inner =
          (bridgeEvent.payload as bridge.EventPayload_Equipment).field0;
      expect(inner, isA<bridge.EquipmentEvent_MountParkCompleted>());
    });

    test('reconstructs DeviceDiscovered hot-plug arrival', () {
      // Mirrors the data shape `_extractEquipmentEventInfo` serializes for the
      // typed `EquipmentEvent::DeviceDiscovered` variant so the network path
      // rebuilds the same typed event the local FFI path delivers.
      const coreEvent = core.SkotiqEvent(
        timestamp: 1,
        severity: core.EventSeverity.info,
        category: core.EventCategory.equipment,
        eventType: 'DeviceDiscovered',
        data: {
          'device_class': 'camera',
          'driver': 'native',
          'id': 'native:zwo:0',
          'name': 'ZWO ASI 533',
          'display_name': 'ZWO ASI 533',
          'unique_id': 'usb-533',
        },
      );

      final bridgeEvent = bridgeEventFromCoreEvent(coreEvent);
      final inner =
          (bridgeEvent.payload as bridge.EventPayload_Equipment).field0;
      expect(inner, isA<bridge.EquipmentEvent_DeviceDiscovered>());
      final discovered = inner as bridge.EquipmentEvent_DeviceDiscovered;
      expect(discovered.deviceClass, 'camera');
      expect(discovered.driver, 'native');
      expect(discovered.id, 'native:zwo:0');
      expect(discovered.name, 'ZWO ASI 533');
      expect(discovered.displayName, 'ZWO ASI 533');
      expect(discovered.uniqueId, 'usb-533');
    });

    test('reconstructs DeviceDiscovered without a unique id', () {
      const coreEvent = core.SkotiqEvent(
        timestamp: 1,
        severity: core.EventSeverity.info,
        category: core.EventCategory.equipment,
        eventType: 'DeviceDiscovered',
        data: {
          'device_class': 'mount',
          'driver': 'native',
          'id': 'native:sw:0',
          'name': 'AZ-GTi',
          'display_name': 'AZ-GTi',
        },
      );

      final bridgeEvent = bridgeEventFromCoreEvent(coreEvent);
      final discovered =
          (bridgeEvent.payload as bridge.EventPayload_Equipment).field0
              as bridge.EquipmentEvent_DeviceDiscovered;
      expect(discovered.uniqueId, isNull);
    });

    test('reconstructs DeviceLost hot-plug removal', () {
      const coreEvent = core.SkotiqEvent(
        timestamp: 1,
        severity: core.EventSeverity.warning,
        category: core.EventCategory.equipment,
        eventType: 'DeviceLost',
        data: {
          'device_class': 'focuser',
          'driver': 'native',
          'id': 'native:zwo:0',
        },
      );

      final bridgeEvent = bridgeEventFromCoreEvent(coreEvent);
      final inner =
          (bridgeEvent.payload as bridge.EventPayload_Equipment).field0;
      expect(inner, isA<bridge.EquipmentEvent_DeviceLost>());
      final lost = inner as bridge.EquipmentEvent_DeviceLost;
      expect(lost.deviceClass, 'focuser');
      expect(lost.driver, 'native');
      expect(lost.id, 'native:zwo:0');
    });
  });
}
