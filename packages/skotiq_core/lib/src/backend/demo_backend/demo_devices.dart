import '../../errors/skotiq_error.dart' show BackendErrorCategory;
import '../../errors/skotiq_exception.dart' show SkotiqException;
import '../../models/backend/backend_types.dart';

/// The demo rig's devices. The ids follow the native simulators' `sim_*`
/// form, which `utils/device_id.dart` classifies as simulator ids.
abstract final class DemoDeviceIds {
  static const camera = 'sim_camera_1';
  static const guideCamera = 'sim_camera_2';
  static const mount = 'sim_mount_1';
  static const focuser = 'sim_focuser_1';
  static const filterWheel = 'sim_filterwheel_1';
  static const rotator = 'sim_rotator_1';
  static const guider = 'sim_guider_1';
  static const weather = 'sim_weather_1';
  static const safetyMonitor = 'sim_safety_monitor_1';
}

/// What the catch-all and every unsupported call of the demo rig answer.
SkotiqException demoRigUnavailable(String what) => SkotiqException(
  category: BackendErrorCategory.unsupported,
  message: 'Not available in the demo rig: $what',
  userMessage: 'Not available in the demo rig',
  isRecoverable: false,
);

/// A demo device id that names no device of the demo rig.
SkotiqException demoRigUnknownDevice(String deviceId) => SkotiqException(
  category: BackendErrorCategory.validation,
  message: 'The demo rig has no device "$deviceId"',
  userMessage: 'The demo rig has no such device',
  isRecoverable: false,
  deviceId: deviceId,
);

/// A command for a demo device that is not connected.
SkotiqException demoRigNotConnected(String deviceId) => SkotiqException(
  category: BackendErrorCategory.connection,
  message: 'Demo device $deviceId is not connected',
  userMessage: 'Connect the demo device first',
  deviceId: deviceId,
);

const _driverVersion = 'Skotiq demo rig';

DeviceInfo _device(
  String id,
  String name,
  DeviceType type,
  String description,
) => DeviceInfo(
  id: id,
  name: name,
  deviceType: type,
  driverType: DriverType.simulator,
  description: description,
  driverVersion: _driverVersion,
);

/// Every device the demo rig offers, by type. The guide camera is a second
/// camera, as a guide camera is on a real rig.
final Map<DeviceType, List<DeviceInfo>> demoRigDevices = {
  DeviceType.camera: [
    _device(
      DemoDeviceIds.camera,
      'Demo Camera',
      DeviceType.camera,
      'Simulated cooled mono camera on this phone',
    ),
    _device(
      DemoDeviceIds.guideCamera,
      'Demo Guide Camera',
      DeviceType.camera,
      'Simulated guide camera on this phone',
    ),
  ],
  DeviceType.mount: [
    _device(
      DemoDeviceIds.mount,
      'Demo Mount',
      DeviceType.mount,
      'Simulated equatorial mount on this phone',
    ),
  ],
  DeviceType.focuser: [
    _device(
      DemoDeviceIds.focuser,
      'Demo Focuser',
      DeviceType.focuser,
      'Simulated focuser on this phone',
    ),
  ],
  DeviceType.filterWheel: [
    _device(
      DemoDeviceIds.filterWheel,
      'Demo Filter Wheel',
      DeviceType.filterWheel,
      'Simulated 7-slot filter wheel on this phone',
    ),
  ],
  DeviceType.rotator: [
    _device(
      DemoDeviceIds.rotator,
      'Demo Rotator',
      DeviceType.rotator,
      'Simulated rotator on this phone',
    ),
  ],
  DeviceType.guider: [
    _device(
      DemoDeviceIds.guider,
      'Demo Guider',
      DeviceType.guider,
      'Simulated guider on this phone',
    ),
  ],
  DeviceType.weather: [
    _device(
      DemoDeviceIds.weather,
      'Demo Weather Station',
      DeviceType.weather,
      'Simulated weather station on this phone',
    ),
  ],
  DeviceType.safetyMonitor: [
    _device(
      DemoDeviceIds.safetyMonitor,
      'Demo Safety Monitor',
      DeviceType.safetyMonitor,
      'Simulated safety monitor on this phone, always safe',
    ),
  ],
};

/// The demo device [deviceId] of [type], or null when the demo rig has none.
DeviceInfo? demoRigDevice(DeviceType type, String deviceId) {
  for (final device in demoRigDevices[type] ?? const <DeviceInfo>[]) {
    if (device.id == deviceId) return device;
  }
  return null;
}

/// The demo filter wheel's slots.
const List<String> demoRigFilterNames = [
  'L',
  'R',
  'G',
  'B',
  'Ha',
  'OIII',
  'SII',
];
