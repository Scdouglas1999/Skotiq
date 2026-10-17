import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/skotiq_core.dart';

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
}
