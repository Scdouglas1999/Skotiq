import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';

import '../harness/frb_contract.dart';

void main() {
  test('FFI equipment profile preserves safety monitor in both directions', () {
    final backend = FfiBackend();
    const bridgeProfile = bridge.EquipmentProfile(
      id: 'profile-1',
      name: 'Remote observatory',
      cameraId: 'camera-1',
      safetyMonitorId: 'safety-1',
      coverCalibratorId: 'cover-1',
      telescopeFocalLength: 800,
      telescopeAperture: 100,
    );

    final model = backend.profileFromBridgeForTesting(bridgeProfile);
    expect(model.safetyMonitorId, 'safety-1');

    final outbound = backend.profileToBridgeForTesting(
      model.copyWith(safetyMonitorId: 'safety-2'),
    );
    expect(outbound.safetyMonitorId, 'safety-2');
    expect(outbound.coverCalibratorId, 'cover-1');
  });

  test('FFI profile exports effective modern optical fields', () {
    final backend = FfiBackend();
    const model = EquipmentProfile(
      id: 'profile-modern',
      name: 'Modern optics',
      focalLength: 1016,
      aperture: 254,
      telescopeFocalLength: 0,
      telescopeAperture: 0,
    );

    final outbound = backend.profileToBridgeForTesting(model);

    expect(outbound.telescopeFocalLength, 1016);
    expect(outbound.telescopeAperture, 254);
  });

  // The bridge profile carries these 16 fields and no more; the native side
  // reads the safety monitor, the telescope focal length and the guide
  // focal length from it, all among them.
  test('every bridge profile field survives the round trip', () {
    final backend = FfiBackend();
    const bridgeProfile = bridge.EquipmentProfile(
      id: 'p-7',
      name: 'Backyard',
      cameraId: 'native:zwo:0',
      mountId: 'alpaca:http://192.168.1.33:11111:telescope:0',
      focuserId: 'native:zwo:eaf:0',
      filterWheelId: 'native:zwo:efw:0',
      guiderId: 'phd2_guider',
      guideCameraId: 'native:zwo:1',
      guideFocalLengthMm: 162,
      rotatorId: 'ascom:ASCOM.Rotator',
      domeId: 'ascom:ASCOM.Dome',
      weatherId: 'ascom:ASCOM.Weather',
      safetyMonitorId: 'ascom:ASCOM.Safety',
      coverCalibratorId: 'ascom:ASCOM.Cover',
      telescopeFocalLength: 530,
      telescopeAperture: 106,
    );
    expect(
      backend.profileToBridgeForTesting(
        backend.profileFromBridgeForTesting(bridgeProfile),
      ),
      bridgeProfile,
    );
    expect(frbFields('state.dart', 'EquipmentProfile'), {
      'id',
      'name',
      'cameraId',
      'mountId',
      'focuserId',
      'filterWheelId',
      'guiderId',
      'guideCameraId',
      'guideFocalLengthMm',
      'rotatorId',
      'domeId',
      'weatherId',
      'safetyMonitorId',
      'coverCalibratorId',
      'telescopeFocalLength',
      'telescopeAperture',
    });
  });
}
