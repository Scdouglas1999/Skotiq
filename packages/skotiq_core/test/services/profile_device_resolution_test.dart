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

    test('an unplugged device keeps its saved id so the connect reports it', () {
      final r = resolveProfileSlot(
        savedId: 'native:zwo:1',
        savedName: 'ZWO ASI1600MM-Cool',
        deviceLabel: 'camera',
        discovered: [_camera('native:zwo:0', 'ZWO ASI178MM')],
      );
      expect(r.deviceId, 'native:zwo:1');
      expect(r.corrected, isFalse);
    });

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
}
