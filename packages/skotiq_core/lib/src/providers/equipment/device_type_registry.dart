/// The one device-type table.
///
/// Consumers — the remote-sync mirror (`remote_sync_handler.dart`), the local
/// device-event router (`device_service/event_handling.dart`) — read these
/// tables rather than carrying their own switch: a device type missing from
/// one copy connects but never appears, or appears but never clears.
///
/// Three mappings live here:
///
/// * [deviceTypeFromWireName] — the wire-name alias table.
/// * [readDeviceConnectionNotifier] — the device-type → notifier table, for
///   callers that DRIVE a slot (`setConnecting` / `setConnected` /
///   `setDisconnected` / `setError`).
/// * [readDeviceSlot] — the device-type → state-object table, for callers that
///   READ a slot's `connectionState` / `deviceId`.
///
/// The last two are deliberately NOT one function. Reading `deviceId` off the
/// notifier and off the state object return the same value in production, but
/// not under test: several suites install a fake that
/// `implements <X>StateNotifier` with a `noSuchMethod` body and publishes real
/// snapshots (e.g. `_FakeCameraNotifier` in
/// `skotiq_app/test/screens/equipment/discovery_toast_currency_test.dart`),
/// so the notifier's getters throw while the state object answers correctly.
///
/// Deliberately NOT consolidated here (they answer different questions and
/// collapsing them would change behaviour):
///
/// * `DeviceService._disconnectForType` — routes to eleven distinct disconnect
///   *flows*, not to a uniform accessor.
/// * `DeviceTypeDisplayExtension.displayName` and
///   `connection_diagnostic.dart`'s label table — human-facing strings, and the
///   two disagree deliberately ("Guider" vs "guide camera").
/// * `NetworkBackend._tryParseCachedDeviceType` — a normalising parser
///   (strips every non-alphanumeric, matches against `DeviceType.values`) that
///   accepts strictly more spellings than [deviceTypeFromWireName]; it parses
///   cached server payloads, not equipment events.
library;

import '../../models/backend/device_types.dart';
import '../../models/equipment/equipment_models.dart'
    show DeviceConnectionState;
import '../provider_reader.dart';
import 'camera_state_provider.dart';
import 'cover_calibrator_state_provider.dart';
import 'device_connection_notifier.dart';
import 'dome_state_provider.dart';
import 'filter_wheel_state_provider.dart';
import 'focuser_state_provider.dart';
import 'guider_state_provider.dart';
import 'mount_state_provider.dart';
import 'rotator_state_provider.dart';
import 'safety_monitor_state_provider.dart';
import 'switch_state_provider.dart';
import 'weather_state_provider.dart';

/// Parse a device type as it arrives on the wire from the Rust bridge, the
/// headless host, or a remote-sync payload.
///
/// Case-insensitive. The alias pairs are the spellings the native side actually
/// emits: `filterwheel`/`filter wheel`, `safetymonitor`/`safety monitor`,
/// `covercalibrator`/`cover calibrator`, `switch`/`switch_`. Anything else
/// returns `null` — callers treat an unparseable type as "not one of ours" and
/// leave every notifier untouched.
DeviceType? deviceTypeFromWireName(String raw) {
  switch (raw.toLowerCase()) {
    case 'camera':
      return DeviceType.camera;
    case 'mount':
      return DeviceType.mount;
    case 'focuser':
      return DeviceType.focuser;
    case 'filterwheel':
    case 'filter wheel':
      return DeviceType.filterWheel;
    case 'guider':
      return DeviceType.guider;
    case 'rotator':
      return DeviceType.rotator;
    case 'dome':
      return DeviceType.dome;
    case 'weather':
      return DeviceType.weather;
    case 'safetymonitor':
    case 'safety monitor':
      return DeviceType.safetyMonitor;
    case 'covercalibrator':
    case 'cover calibrator':
      return DeviceType.coverCalibrator;
    case 'switch':
    case 'switch_':
      return DeviceType.switch_;
    default:
      return null;
  }
}

/// The live connection slot for [deviceType], read from that device's state
/// object.
///
/// Use this to ASK about a slot. To drive one, use
/// [readDeviceConnectionNotifier] — the two are not interchangeable under the
/// `implements`-plus-`noSuchMethod` notifier fakes several widget suites
/// install; see the library doc.
({DeviceConnectionState connectionState, String? deviceId}) readDeviceSlot(
  Object reader,
  DeviceType deviceType,
) {
  switch (deviceType) {
    case DeviceType.camera:
      final state = readProvider(reader, cameraStateProvider);
      return (connectionState: state.connectionState, deviceId: state.deviceId);
    case DeviceType.mount:
      final state = readProvider(reader, mountStateProvider);
      return (connectionState: state.connectionState, deviceId: state.deviceId);
    case DeviceType.focuser:
      final state = readProvider(reader, focuserStateProvider);
      return (connectionState: state.connectionState, deviceId: state.deviceId);
    case DeviceType.filterWheel:
      final state = readProvider(reader, filterWheelStateProvider);
      return (connectionState: state.connectionState, deviceId: state.deviceId);
    case DeviceType.guider:
      final state = readProvider(reader, guiderStateProvider);
      return (connectionState: state.connectionState, deviceId: state.deviceId);
    case DeviceType.rotator:
      final state = readProvider(reader, rotatorStateProvider);
      return (connectionState: state.connectionState, deviceId: state.deviceId);
    case DeviceType.dome:
      final state = readProvider(reader, domeStateProvider);
      return (connectionState: state.connectionState, deviceId: state.deviceId);
    case DeviceType.weather:
      final state = readProvider(reader, weatherStateProvider);
      return (connectionState: state.connectionState, deviceId: state.deviceId);
    case DeviceType.safetyMonitor:
      final state = readProvider(reader, safetyMonitorStateProvider);
      return (connectionState: state.connectionState, deviceId: state.deviceId);
    case DeviceType.coverCalibrator:
      final state = readProvider(reader, coverCalibratorStateProvider);
      return (connectionState: state.connectionState, deviceId: state.deviceId);
    case DeviceType.switch_:
      final state = readProvider(reader, switchStateProvider);
      return (connectionState: state.connectionState, deviceId: state.deviceId);
  }
}

/// The equipment-state notifier that owns [deviceType]'s card.
///
/// [reader] is a `Ref` in the app and a `ProviderContainer` on the headless
/// server — see [readProvider].
DeviceConnectionNotifier readDeviceConnectionNotifier(
  Object reader,
  DeviceType deviceType,
) {
  switch (deviceType) {
    case DeviceType.camera:
      return readProvider(reader, cameraStateProvider.notifier);
    case DeviceType.mount:
      return readProvider(reader, mountStateProvider.notifier);
    case DeviceType.focuser:
      return readProvider(reader, focuserStateProvider.notifier);
    case DeviceType.filterWheel:
      return readProvider(reader, filterWheelStateProvider.notifier);
    case DeviceType.guider:
      return readProvider(reader, guiderStateProvider.notifier);
    case DeviceType.rotator:
      return readProvider(reader, rotatorStateProvider.notifier);
    case DeviceType.dome:
      return readProvider(reader, domeStateProvider.notifier);
    case DeviceType.weather:
      return readProvider(reader, weatherStateProvider.notifier);
    case DeviceType.safetyMonitor:
      return readProvider(reader, safetyMonitorStateProvider.notifier);
    case DeviceType.coverCalibrator:
      return readProvider(reader, coverCalibratorStateProvider.notifier);
    case DeviceType.switch_:
      return readProvider(reader, switchStateProvider.notifier);
  }
}
