import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_core/skotiq_core.dart';

import '../harness/in_memory_database.dart';

SkotiqEvent _equipmentEvent(String eventType, Map<String, dynamic> data) {
  return SkotiqEvent(
    timestamp: DateTime.now().millisecondsSinceEpoch,
    severity: EventSeverity.info,
    category: EventCategory.equipment,
    eventType: eventType,
    data: data,
  );
}

void main() {
  group('mirrored device disconnect', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
      addTearDown(container.dispose);
    });

    void markSwitchConnected() {
      container.read(switchStateProvider.notifier)
        ..setConnecting('switch-1', 'Pegasus UPB')
        ..setConnected();
      expect(
        container.read(switchStateProvider).connectionState,
        DeviceConnectionState.connected,
      );
    }

    test('equipment Disconnected clears the switch card', () async {
      markSwitchConnected();

      await applyRemoteSyncEvent(
        container,
        _equipmentEvent('Disconnected', const {
          'device_type': 'switch',
          'device_id': 'switch-1',
        }),
      );

      expect(
        container.read(switchStateProvider).connectionState,
        DeviceConnectionState.disconnected,
      );
    });

    test('device_disconnected sync payload clears the switch card', () async {
      markSwitchConnected();

      await applyRemoteSyncEvent(
        container,
        remoteSyncEvent(
          eventType: RemoteSyncEventTypes.deviceDisconnected,
          data: const {'device_type': 'switch_', 'device_id': 'switch-1'},
        ),
      );

      expect(
        container.read(switchStateProvider).connectionState,
        DeviceConnectionState.disconnected,
      );
    });

    test('every device type parseable on connect also disconnects', () async {
      // The connect and disconnect mirrors must agree on the type table: a
      // device the slave can be told to show as connected must be a device it
      // can be told to drop.
      const wireTypes = <String>[
        'camera',
        'mount',
        'focuser',
        'filterwheel',
        'filter wheel',
        'guider',
        'rotator',
        'dome',
        'weather',
        'safetymonitor',
        'safety monitor',
        'covercalibrator',
        'cover calibrator',
        'switch',
        'switch_',
      ];

      for (final wireType in wireTypes) {
        await applyRemoteSyncEvent(
          container,
          _equipmentEvent('Connected', {
            'device_type': wireType,
            'device_id': 'dev-$wireType',
            'device_name': wireType,
          }),
        );
        await applyRemoteSyncEvent(
          container,
          _equipmentEvent('Disconnected', {
            'device_type': wireType,
            'device_id': 'dev-$wireType',
          }),
        );
      }

      final leftConnected = <String, DeviceConnectionState>{
        'camera': container.read(cameraStateProvider).connectionState,
        'mount': container.read(mountStateProvider).connectionState,
        'focuser': container.read(focuserStateProvider).connectionState,
        'filterWheel': container.read(filterWheelStateProvider).connectionState,
        'guider': container.read(guiderStateProvider).connectionState,
        'rotator': container.read(rotatorStateProvider).connectionState,
        'dome': container.read(domeStateProvider).connectionState,
        'weather': container.read(weatherStateProvider).connectionState,
        'safetyMonitor': container
            .read(safetyMonitorStateProvider)
            .connectionState,
        'coverCalibrator': container
            .read(coverCalibratorStateProvider)
            .connectionState,
        'switch': container.read(switchStateProvider).connectionState,
      }..removeWhere((_, s) => s == DeviceConnectionState.disconnected);

      expect(leftConnected, isEmpty);
    });
  });
}
