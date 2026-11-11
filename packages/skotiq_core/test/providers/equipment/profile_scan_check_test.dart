import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

DeviceInfo _device(
  String id,
  String name,
  DeviceType type,
  DriverType driver,
) => DeviceInfo(
  id: id,
  name: name,
  deviceType: type,
  driverType: driver,
  description: '',
  driverVersion: '',
);

BackendDiscoveryState _done(DriverType driver, List<DeviceInfo> devices) =>
    BackendDiscoveryState(
      backend: driver,
      status: DiscoveryStatus.completed,
      devices: devices,
      completedAt: DateTime(2026, 11, 11, 21, 4),
    );

UnifiedDiscoveryState _scan(Map<DriverType, BackendDiscoveryState> buckets) =>
    UnifiedDiscoveryState(
      backendStates: buckets,
      rawDevices: [for (final b in buckets.values) ...b.devices],
    );

const _simRig = EquipmentProfileModel(
  id: 1,
  name: 'Sim rig',
  cameraId: 'sim_camera_1',
  cameraName: 'Simulated Camera',
  mountId: 'sim_mount_1',
  mountName: 'Simulated Mount',
  focuserId: 'sim_focuser_1',
  guideCameraId: 'sim_camera_2',
  guideCameraName: 'Simulated Guide Camera',
);

void main() {
  group('checkProfileAgainstScan', () {
    test('says nothing before any scan has finished', () {
      final check = checkProfileAgainstScan(
        _simRig,
        const UnifiedDiscoveryState(),
        linkedHost: false,
      );
      expect(check.scannedAt, isNull);
      expect(check.notFound, isEmpty);
    });

    test('names the profile devices the scan did not list, in slot order', () {
      final check = checkProfileAgainstScan(
        _simRig,
        _scan({
          DriverType.simulator: _done(DriverType.simulator, [
            _device(
              'sim_mount_1',
              'Simulated Mount',
              DeviceType.mount,
              DriverType.simulator,
            ),
          ]),
        }),
        linkedHost: false,
      );
      expect(check.scannedAt, DateTime(2026, 11, 11, 21, 4));
      expect(
        [for (final d in check.notFound) '${d.slot}: ${d.name}'],
        [
          'camera: Simulated Camera',
          'focuser: Simulated Focuser',
          'guide camera: Simulated Guide Camera',
        ],
      );
    });

    test('a connected device is not reported missing', () {
      final check = checkProfileAgainstScan(
        _simRig,
        _scan({DriverType.simulator: _done(DriverType.simulator, const [])}),
        linkedHost: false,
        connected: {DeviceType.camera, DeviceType.mount, DeviceType.focuser},
      );
      expect([for (final d in check.notFound) d.slot], ['guide camera']);
    });

    test('a driver that failed or was not scanned says nothing', () {
      const profile = EquipmentProfileModel(
        id: 2,
        name: 'Alpaca rig',
        mountId: 'alpaca:http://10.0.0.5:11111:telescope:0',
        cameraId: 'sim_camera_1',
      );
      final check = checkProfileAgainstScan(
        profile,
        _scan({
          DriverType.simulator: _done(DriverType.simulator, const []),
          DriverType.alpaca: const BackendDiscoveryState(
            backend: DriverType.alpaca,
            status: DiscoveryStatus.error,
            error: 'Alpaca server connection failed',
          ),
        }),
        linkedHost: false,
      );
      expect([for (final d in check.notFound) d.slot], ['camera']);
    });

    test('a PHD2 guider is never judged by a scan', () {
      const profile = EquipmentProfileModel(
        id: 3,
        name: 'PHD2 rig',
        guiderId: 'phd2_guider',
      );
      final check = checkProfileAgainstScan(
        profile,
        _scan({DriverType.native: _done(DriverType.native, const [])}),
        linkedHost: false,
      );
      expect(check.notFound, isEmpty);
    });

    test('a positional camera that moved to another position is found', () {
      const profile = EquipmentProfileModel(
        id: 4,
        name: 'ZWO rig',
        cameraId: 'native:zwo:0',
        cameraName: 'ZWO ASI1600MM-Cool',
      );
      final check = checkProfileAgainstScan(
        profile,
        _scan({
          DriverType.native: _done(DriverType.native, [
            _device(
              'native:zwo:0',
              'ZWO ASI178MM',
              DeviceType.camera,
              DriverType.native,
            ),
            _device(
              'native:zwo:1',
              'ZWO ASI1600MM-Cool',
              DeviceType.camera,
              DriverType.native,
            ),
          ]),
        }),
        linkedHost: false,
      );
      expect(check.notFound, isEmpty);
    });

    test('a positional id now held by another model is not found', () {
      const profile = EquipmentProfileModel(
        id: 5,
        name: 'ZWO rig',
        cameraId: 'native:zwo:0',
        cameraName: 'ZWO ASI1600MM-Cool',
      );
      final check = checkProfileAgainstScan(
        profile,
        _scan({
          DriverType.native: _done(DriverType.native, [
            _device(
              'native:zwo:0',
              'ZWO ASI178MM',
              DeviceType.camera,
              DriverType.native,
            ),
          ]),
        }),
        linkedHost: false,
      );
      expect([for (final d in check.notFound) d.name], ['ZWO ASI1600MM-Cool']);
    });

    test('on a linked client the host sweep answers for every driver', () {
      final check = checkProfileAgainstScan(
        _simRig,
        _scan({
          linkedHostScanBucket: _done(linkedHostScanBucket, [
            _device(
              'sim_camera_1',
              'Simulated Camera',
              DeviceType.camera,
              DriverType.simulator,
            ),
            _device(
              'sim_camera_2',
              'Simulated Guide Camera',
              DeviceType.camera,
              DriverType.simulator,
            ),
            _device(
              'sim_mount_1',
              'Simulated Mount',
              DeviceType.mount,
              DriverType.simulator,
            ),
          ]),
        }),
        linkedHost: true,
      );
      expect([for (final d in check.notFound) d.slot], ['focuser']);
    });
  });
}
