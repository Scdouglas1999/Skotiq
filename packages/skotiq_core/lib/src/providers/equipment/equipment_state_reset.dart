import '../device_heartbeat_health_provider.dart';
import '../provider_reader.dart';
import 'camera_state_provider.dart';
import 'cover_calibrator_state_provider.dart';
import 'dome_state_provider.dart';
import 'filter_wheel_state_provider.dart';
import 'focuser_state_provider.dart';
import 'guider_state_provider.dart';
import 'mount_state_provider.dart';
import 'rotator_state_provider.dart';
import 'safety_monitor_state_provider.dart';
import 'switch_state_provider.dart';
import 'weather_state_provider.dart';

/// Reset every equipment-state notifier to disconnected baseline.
///
/// Called when the active [SkotiqBackend] is swapped, and on a remote
/// companion before re-hydrating the host's device list, so the UI does not
/// keep showing devices as connected against a backend that never opened them.
///
/// [reader] is a `Ref` in the app and a `ProviderContainer` on the headless
/// server. Pass `includeGuider: false` when the guider is re-hydrated from a
/// separate source (PHD2 is not always in the host's device list, and clearing
/// it here would blank the chip before that poll lands).
void resetAllEquipmentStateNotifiers(
  Object reader, {
  bool includeGuider = true,
  bool clearHeartbeatHealth = true,
}) {
  readProvider(reader, cameraStateProvider.notifier).setDisconnected();
  readProvider(reader, mountStateProvider.notifier).setDisconnected();
  readProvider(reader, focuserStateProvider.notifier).setDisconnected();
  readProvider(reader, filterWheelStateProvider.notifier).setDisconnected();
  if (includeGuider) {
    readProvider(reader, guiderStateProvider.notifier).setDisconnected();
  }
  readProvider(reader, rotatorStateProvider.notifier).setDisconnected();
  readProvider(reader, domeStateProvider.notifier).setDisconnected();
  readProvider(reader, weatherStateProvider.notifier).setDisconnected();
  readProvider(reader, safetyMonitorStateProvider.notifier).setDisconnected();
  readProvider(reader, switchStateProvider.notifier).setDisconnected();
  readProvider(reader, coverCalibratorStateProvider.notifier).setDisconnected();

  if (!clearHeartbeatHealth) return;
  try {
    readProvider(reader, deviceHeartbeatHealthProvider.notifier).clearAll();
  } on Object {
    // Heartbeat provider may be unavailable mid-disposal during shutdown.
  }
}
