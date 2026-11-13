import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/backend/device_info.dart';
import 'package:skotiq_core/src/models/backend/device_types.dart';
import 'package:skotiq_core/src/services/device_service/profile_device_resolution.dart';

DeviceInfo _camera(String id, String name) => DeviceInfo(
  id: id,
  name: name,
  deviceType: DeviceType.camera,
  driverType: DriverType.native,
  description: '',
  driverVersion: '',
);

void main() {
  group('resolveProfileSlot', () {
    test('a second camera plugged in ahead of the profile camera moves it '
        '(the imaging laptop, 2026-10-17)', () {
      // Saved on a night when the 1600 was the only camera, so it was #0.
      final r = resolveProfileSlot(
        savedId: 'native:zwo:0',
        savedName: 'ZWO ASI1600MM-Cool',
        deviceLabel: 'camera',
        discovered: [
          _camera('native:zwo:0', 'ZWO ASI178MM'),
          _camera('native:zwo:1', 'ZWO ASI1600MM-Cool'),
        ],
      );
      expect(r.deviceId, 'native:zwo:1');
      expect(r.corrected, isTrue);
      expect(r.refusal, isNull);
    });

    test('the saved position still holding the named device is kept', () {
      final r = resolveProfileSlot(
        savedId: 'native:zwo:1',
        savedName: 'ZWO ASI1600MM-Cool',
        deviceLabel: 'camera',
        discovered: [
          _camera('native:zwo:0', 'ZWO ASI178MM'),
          _camera('native:zwo:1', 'ZWO ASI1600MM-Cool'),
        ],
      );
      expect(r.deviceId, 'native:zwo:1');
      expect(r.corrected, isFalse);
    });

    test('discovery\'s same-model suffix does not defeat the match', () {
      final r = resolveProfileSlot(
        savedId: 'native:zwo:0',
        savedName: 'ZWO ASI1600MM-Cool',
        deviceLabel: 'camera',
        discovered: [
          _camera('native:zwo:0', 'ZWO ASI178MM #1'),
          _camera('native:zwo:1', 'zwo asi1600mm-cool  #2'),
        ],
      );
      expect(r.deviceId, 'native:zwo:1');
    });

    test('two cameras of the saved model and the wrong one at the saved '
        'position is refused, not guessed', () {
      final r = resolveProfileSlot(
        savedId: 'native:zwo:0',
        savedName: 'ZWO ASI1600MM-Cool',
        deviceLabel: 'camera',
        discovered: [
          _camera('native:zwo:0', 'ZWO ASI178MM'),
          _camera('native:zwo:1', 'ZWO ASI1600MM-Cool #1'),
          _camera('native:zwo:2', 'ZWO ASI1600MM-Cool #2'),
        ],
      );
      expect(r.deviceId, isNull);
      expect(r.refusal, contains('native:zwo:0 is now ZWO ASI178MM'));
      expect(r.refusal, contains('2 connected cameras have that name'));
    });

    test('a different model at the saved position and none named like the '
        'profile is refused', () {
      final r = resolveProfileSlot(
        savedId: 'native:zwo:0',
        savedName: 'ZWO ASI1600MM-Cool',
        deviceLabel: 'camera',
        discovered: [_camera('native:zwo:0', 'ZWO ASI178MM')],
      );
      expect(r.deviceId, isNull);
      expect(r.refusal, contains('no connected camera has that name'));
    });

    test(
      'an unplugged device keeps its saved id so the connect reports it',
      () {
        final r = resolveProfileSlot(
          savedId: 'native:zwo:1',
          savedName: 'ZWO ASI1600MM-Cool',
          deviceLabel: 'camera',
          discovered: [_camera('native:zwo:0', 'ZWO ASI178MM')],
        );
        expect(r.deviceId, 'native:zwo:1');
        expect(r.corrected, isFalse);
      },
    );

    test('ids that already name a device, unnamed slots and an empty '
        'discovery are left alone', () {
      final discovered = [_camera('native:zwo:0', 'ZWO ASI178MM')];
      expect(
        resolveProfileSlot(
          savedId: 'ascom:ASCOM.ASICamera2.Camera',
          savedName: 'ZWO ASI1600MM-Cool',
          deviceLabel: 'camera',
          discovered: discovered,
        ).deviceId,
        'ascom:ASCOM.ASICamera2.Camera',
      );
      expect(
        resolveProfileSlot(
          savedId: 'native:zwo:0',
          savedName: null,
          deviceLabel: 'camera',
          discovered: discovered,
        ).deviceId,
        'native:zwo:0',
      );
      expect(
        resolveProfileSlot(
          savedId: 'native:zwo:0',
          savedName: 'ZWO ASI1600MM-Cool',
          deviceLabel: 'camera',
          discovered: const [],
        ).deviceId,
        'native:zwo:0',
      );
    });

    test('a focuser or wheel only matches within its own vendor family', () {
      final r = resolveProfileSlot(
        savedId: 'native:zwo_eaf:0',
        savedName: 'EAF',
        deviceLabel: 'focuser',
        discovered: [
          DeviceInfo(
            id: 'native:zwo_eaf:0',
            name: 'EAF',
            deviceType: DeviceType.focuser,
            driverType: DriverType.native,
            description: '',
            driverVersion: '',
          ),
        ],
      );
      expect(r.deviceId, 'native:zwo_eaf:0');
      expect(isPositionalDeviceId('native:zwo_eaf:1'), isTrue);
      expect(isPositionalDeviceId('native:qhy:QHY600M-12345'), isFalse);
      expect(isPositionalDeviceId('native:builtin_guider:multi_star'), isFalse);
    });
  });

  group('resolveProfileSlots', () {
    // The rig, Nov 8 2026: the hub with both cameras dropped and the SDK
    // enumerated them in the other order. Saved: 1600 at 1, 178 at 0.
    test('both cameras follow their names when the bus swaps them', () {
      final r = resolveProfileSlots(
        [
          (
            label: 'camera',
            savedId: 'native:zwo:1',
            savedName: 'ZWO ASI1600MM-Cool',
          ),
          (
            label: 'guide camera',
            savedId: 'native:zwo:0',
            savedName: 'ZWO ASI178MM',
          ),
        ],
        (_) => [
          _camera('native:zwo:0', 'ZWO ASI1600MM-Cool #1'),
          _camera('native:zwo:1', 'ZWO ASI178MM #2'),
        ],
      );
      expect(r['camera']!.deviceId, 'native:zwo:0');
      expect(r['camera']!.corrected, isTrue);
      expect(r['guide camera']!.deviceId, 'native:zwo:1');
      expect(r['guide camera']!.corrected, isTrue);
    });

    test('the guide camera is never given the main camera\'s device', () {
      // Discovery did not answer, so both slots keep their saved ids, and
      // the guide camera was saved at the id the main camera now has.
      final r = resolveProfileSlots(
        [
          (
            label: 'camera',
            savedId: 'native:zwo:0',
            savedName: 'ZWO ASI1600MM-Cool',
          ),
          (
            label: 'guide camera',
            savedId: 'native:zwo:0',
            savedName: 'ZWO ASI178MM',
          ),
        ],
        (_) => const [],
      );
      expect(r['camera']!.deviceId, 'native:zwo:0');
      expect(r['guide camera']!.deviceId, isNull);
      expect(r['guide camera']!.refusal, contains('which is the camera'));
    });

    test('simulator cameras resolve like a USB bus', () {
      final r = resolveProfileSlots(
        [
          (
            label: 'camera',
            savedId: 'sim_camera_1',
            savedName: 'Simulated Camera',
          ),
        ],
        (_) => [
          _camera('sim_camera_1', 'Simulated Guide Camera'),
          _camera('sim_camera_2', 'Simulated Camera'),
        ],
      );
      expect(r['camera']!.deviceId, 'sim_camera_2');
    });
  });

  group('saved serial', () {
    test('two bodies of one model are told apart by the saved serial', () {
      final r = resolveProfileSlot(
        savedId: 'native:qhy:0',
        savedName: 'QHY268M (A1B2)',
        deviceLabel: 'camera',
        discovered: [
          _camera('native:qhy:0', 'QHY268M (C3D4)'),
          _camera('native:qhy:1', 'QHY268M (A1B2)'),
        ],
      );
      expect(r.deviceId, 'native:qhy:1');
      expect(r.corrected, isTrue);
    });
  });
}
