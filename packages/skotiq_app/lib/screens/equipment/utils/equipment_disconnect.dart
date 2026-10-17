import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// One row in a bulk-disconnect sweep.
typedef EquipmentDisconnectTarget = ({
  Future<void> Function() disconnect,
  String label,
  DeviceConnectionState connectionState,
});

/// Targets every device type the equipment screen can disconnect.
List<EquipmentDisconnectTarget> equipmentDisconnectTargets(WidgetRef ref) {
  final camera = ref.read(cameraStateProvider);
  final mount = ref.read(mountStateProvider);
  final focuser = ref.read(focuserStateProvider);
  final filterWheel = ref.read(filterWheelStateProvider);
  final guider = ref.read(guiderStateProvider);
  final rotator = ref.read(rotatorStateProvider);
  final dome = ref.read(domeStateProvider);
  final weather = ref.read(weatherStateProvider);
  final safety = ref.read(safetyMonitorStateProvider);
  final switchDevice = ref.read(switchStateProvider);
  final cover = ref.read(coverCalibratorStateProvider);

  return [
    (
      disconnect: ref.read(deviceServiceProvider).disconnectCamera,
      label: 'camera',
      connectionState: camera.connectionState
    ),
    (
      disconnect: ref.read(deviceServiceProvider).disconnectMount,
      label: 'mount',
      connectionState: mount.connectionState
    ),
    (
      disconnect: ref.read(deviceServiceProvider).disconnectFocuser,
      label: 'focuser',
      connectionState: focuser.connectionState
    ),
    (
      disconnect: ref.read(deviceServiceProvider).disconnectFilterWheel,
      label: 'filter wheel',
      connectionState: filterWheel.connectionState
    ),
    (
      disconnect: ref.read(deviceServiceProvider).disconnectGuider,
      label: 'guider',
      connectionState: guider.connectionState
    ),
    (
      disconnect: ref.read(deviceServiceProvider).disconnectRotator,
      label: 'rotator',
      connectionState: rotator.connectionState
    ),
    (
      disconnect: ref.read(deviceServiceProvider).disconnectDome,
      label: 'dome',
      connectionState: dome.connectionState
    ),
    (
      disconnect: ref.read(deviceServiceProvider).disconnectWeather,
      label: 'weather station',
      connectionState: weather.connectionState
    ),
    (
      disconnect: ref.read(deviceServiceProvider).disconnectSafetyMonitor,
      label: 'safety monitor',
      connectionState: safety.connectionState
    ),
    (
      disconnect: ref.read(deviceServiceProvider).disconnectSwitch,
      label: 'switch',
      connectionState: switchDevice.connectionState
    ),
    (
      disconnect: ref.read(deviceServiceProvider).disconnectCoverCalibrator,
      label: 'cover calibrator',
      connectionState: cover.connectionState
    ),
  ];
}

/// Returns true when [state] means there is nothing useful to disconnect.
bool equipmentDisconnectShouldSkip(DeviceConnectionState state) =>
    state == DeviceConnectionState.disconnected;

/// Disconnect every target that is not already [DeviceConnectionState.disconnected].
///
/// Skips based on connection state (not error-message substring matching).
/// [DeviceNotConnectedException] is still caught as a race guard when state
/// flipped between the read and the disconnect call.
Future<EquipmentDisconnectSummary> runEquipmentDisconnectAll(
  WidgetRef ref,
) async {
  var successCount = 0;
  final failures = <String>[];

  for (final target in equipmentDisconnectTargets(ref)) {
    if (equipmentDisconnectShouldSkip(target.connectionState)) {
      continue;
    }
    try {
      await target.disconnect();
      successCount++;
    } on DeviceNotConnectedException {
      continue;
    } catch (e) {
      failures.add('${target.label}: $e');
    }
  }

  return (successCount: successCount, failures: failures);
}

typedef EquipmentDisconnectSummary = ({
  int successCount,
  List<String> failures,
});
