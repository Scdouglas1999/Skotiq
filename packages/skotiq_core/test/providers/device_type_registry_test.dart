import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../harness/in_memory_database.dart';

// Parity pins for the one device-type table
// (`providers/equipment/device_type_registry.dart`).
//
// Every expectation below was read off the copies the registry replaced —
// `remote_sync_handler._parseDeviceType` / `._readDeviceNotifier` and the four
// eleven-case switches in `device_service/event_handling.dart`
// (`_applyDeviceConnected`, `_applyDeviceConnecting`, `_handleDeviceError`,
// `_handleDeviceDisconnected`) plus `connections._slotDeviceIdFor`. If a
// future edit changes what parses or which card a type lands on, one of these
// fails rather than a device silently never appearing.

/// Mirrors the shape of the notifier fakes real widget suites install: the
/// state object is honest, every notifier getter is not.
class _ThrowingCameraNotifier extends StateNotifier<CameraStateSnapshot>
    implements CameraStateNotifier {
  _ThrowingCameraNotifier()
    : super(
        const CameraStateSnapshot(
          connectionState: DeviceConnectionState.connected,
          deviceId: 'cam-1',
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('fake camera notifier: ${invocation.memberName}');
}

void main() {
  group('deviceTypeFromWireName', () {
    test('accepts every alias the retired switches enumerated', () {
      const accepted = <String, DeviceType>{
        'camera': DeviceType.camera,
        'mount': DeviceType.mount,
        'focuser': DeviceType.focuser,
        'filterwheel': DeviceType.filterWheel,
        'filter wheel': DeviceType.filterWheel,
        'guider': DeviceType.guider,
        'rotator': DeviceType.rotator,
        'dome': DeviceType.dome,
        'weather': DeviceType.weather,
        'safetymonitor': DeviceType.safetyMonitor,
        'safety monitor': DeviceType.safetyMonitor,
        'covercalibrator': DeviceType.coverCalibrator,
        'cover calibrator': DeviceType.coverCalibrator,
        'switch': DeviceType.switch_,
        'switch_': DeviceType.switch_,
      };

      accepted.forEach((wire, expected) {
        expect(deviceTypeFromWireName(wire), expected, reason: wire);
      });

      // Every DeviceType must be reachable from the wire, or a device that
      // connects natively can never light its card.
      expect(accepted.values.toSet(), DeviceType.values.toSet());
    });

    test('is case-insensitive, matching the `.toLowerCase()` it replaced', () {
      expect(deviceTypeFromWireName('Camera'), DeviceType.camera);
      expect(deviceTypeFromWireName('FILTER WHEEL'), DeviceType.filterWheel);
      expect(deviceTypeFromWireName('SafetyMonitor'), DeviceType.safetyMonitor);
      expect(
        deviceTypeFromWireName('Cover Calibrator'),
        DeviceType.coverCalibrator,
      );
    });

    test('rejects the spellings the retired switches also rejected', () {
      // These are real strings used elsewhere in the app — display labels
      // (`connection_diagnostic.dart`), the underscore spelling, and padded or
      // empty payloads. None of them is a wire name, so none may parse.
      const rejected = <String>[
        '',
        ' ',
        'camera ',
        ' camera',
        'filter_wheel',
        'filter-wheel',
        'safety_monitor',
        'weather station',
        'guide camera',
        'cover/calibrator',
        'switch device',
        'telescope',
        'observingconditions',
      ];
      for (final wire in rejected) {
        expect(deviceTypeFromWireName(wire), isNull, reason: '"$wire"');
      }
    });
  });

  group('readDeviceConnectionNotifier', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
      addTearDown(container.dispose);
    });

    /// The card each type owned in the retired per-type switches.
    Map<DeviceType, String?> slotDeviceIds() => <DeviceType, String?>{
      DeviceType.camera: container.read(cameraStateProvider).deviceId,
      DeviceType.mount: container.read(mountStateProvider).deviceId,
      DeviceType.focuser: container.read(focuserStateProvider).deviceId,
      DeviceType.filterWheel: container.read(filterWheelStateProvider).deviceId,
      DeviceType.guider: container.read(guiderStateProvider).deviceId,
      DeviceType.rotator: container.read(rotatorStateProvider).deviceId,
      DeviceType.dome: container.read(domeStateProvider).deviceId,
      DeviceType.weather: container.read(weatherStateProvider).deviceId,
      DeviceType.safetyMonitor: container
          .read(safetyMonitorStateProvider)
          .deviceId,
      DeviceType.coverCalibrator: container
          .read(coverCalibratorStateProvider)
          .deviceId,
      DeviceType.switch_: container.read(switchStateProvider).deviceId,
    };

    test('each type drives its own card and no other', () {
      for (final type in DeviceType.values) {
        readDeviceConnectionNotifier(
          container,
          type,
        ).setConnecting('dev-${type.name}', 'Device ${type.name}');
      }

      slotDeviceIds().forEach((type, deviceId) {
        expect(deviceId, 'dev-${type.name}', reason: type.name);
      });
    });

    test('deviceId reads the same value the retired _slotDeviceIdFor did', () {
      readDeviceConnectionNotifier(
        container,
        DeviceType.rotator,
      ).setConnecting('rot-7', 'Pegasus Falcon');

      expect(
        readDeviceConnectionNotifier(container, DeviceType.rotator).deviceId,
        container.read(rotatorStateProvider).deviceId,
      );
      expect(
        readDeviceConnectionNotifier(container, DeviceType.camera).deviceId,
        isNull,
      );
    });

    test('readDeviceSlot reads the state object, per type', () {
      for (final type in DeviceType.values) {
        expect(
          readDeviceSlot(container, type).connectionState,
          DeviceConnectionState.disconnected,
          reason: type.name,
        );
        expect(readDeviceSlot(container, type).deviceId, isNull);
      }

      for (final type in DeviceType.values) {
        readDeviceConnectionNotifier(container, type)
          ..setConnecting('dev-${type.name}', 'Device ${type.name}')
          ..setConnected();
      }

      // Same values the retired copies read straight off `<x>StateProvider`.
      slotDeviceIds().forEach((type, stateDeviceId) {
        final slot = readDeviceSlot(container, type);
        expect(slot.deviceId, stateDeviceId, reason: type.name);
        expect(
          slot.connectionState,
          DeviceConnectionState.connected,
          reason: type.name,
        );
      });
    });

    test('readDeviceSlot survives a notifier whose getters throw', () {
      // Several widget suites install a fake that `implements` the notifier
      // with a `noSuchMethod` body and publishes real snapshots — its
      // `connectionState` / `deviceId` getters throw. That is why the read path
      // goes through the state object and NOT through the notifier; if these
      // two ever collapse into one accessor, this fails.
      final scoped = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          cameraStateProvider.overrideWith((ref) => _ThrowingCameraNotifier()),
        ],
      );
      addTearDown(scoped.dispose);

      expect(
        readDeviceSlot(scoped, DeviceType.camera).connectionState,
        DeviceConnectionState.connected,
      );
      expect(readDeviceSlot(scoped, DeviceType.camera).deviceId, 'cam-1');
      expect(
        () => readDeviceConnectionNotifier(scoped, DeviceType.camera).deviceId,
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('setConnected / setDisconnected / setError land on that card', () {
      for (final type in DeviceType.values) {
        final notifier = readDeviceConnectionNotifier(container, type);
        notifier
          ..setConnecting('dev-${type.name}', 'Device ${type.name}')
          ..setConnected();
        expect(
          notifier.connectionState,
          DeviceConnectionState.connected,
          reason: type.name,
        );

        notifier.setError(Exception('driver said no'));
        expect(
          notifier.connectionState,
          DeviceConnectionState.error,
          reason: type.name,
        );

        notifier.setDisconnected();
        expect(
          notifier.connectionState,
          DeviceConnectionState.disconnected,
          reason: type.name,
        );
        expect(notifier.deviceId, isNull, reason: type.name);
      }
    });
  });
}
