import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/equipment/equipment_models.dart' show DeviceConnectionState;
import '../services/equipment_health_service.dart';
import 'database_provider.dart';
import 'device_last_contact_provider.dart';
import 'device_heartbeat_health_provider.dart';
import 'equipment/camera_state_provider.dart';
import 'equipment/filter_wheel_state_provider.dart';
import 'equipment/dome_state_provider.dart';
import 'equipment/focuser_state_provider.dart';
import 'equipment/guider_state_provider.dart';
import 'equipment/mount_state_provider.dart';
import 'equipment/profile_connection_status_provider.dart';
import 'equipment/rotator_state_provider.dart';
import 'equipment/safety_monitor_state_provider.dart';
import 'equipment/weather_state_provider.dart';
import 'usb_disconnect_log_provider.dart';

/// Service provider for EquipmentHealthService.
final equipmentHealthServiceProvider = Provider<EquipmentHealthService>((ref) {
  return const EquipmentHealthService();
});

/// The currently connected devices, as health descriptors.
///
/// Separate from [deviceHealthSnapshotsProvider] so the heartbeat poller
/// ([deviceLastContactProvider]) can follow the connected set without
/// depending on the snapshot list it feeds — the timestamps flow
/// descriptors → poller → snapshots, never in a cycle.
final connectedDeviceDescriptorsProvider = Provider<List<DeviceConnectionDescriptor>>((
  ref,
) {
  final descriptors = <DeviceConnectionDescriptor>[];

  // Camera carries an explicit health timer; the other notifiers only
  // track connection state + last error, so we synthesise an isHealthy
  // boolean from `connected && !hasError`. The pre-flight USB stability
  // rule reads `disconnectCountLast24h` directly so the exact value of
  // isHealthy doesn't matter for that path, but the EquipmentHealthReport
  // surfaces device-down warnings when isHealthy is false — so a
  // disconnected mount mid-session correctly raises a critical health
  // insight.
  final camera = ref.watch(cameraStateProvider);
  if (camera.deviceId != null &&
      camera.deviceId!.isNotEmpty &&
      camera.connectionState == DeviceConnectionState.connected) {
    descriptors.add(
      DeviceConnectionDescriptor(
        deviceId: camera.deviceId!,
        deviceLabel: camera.deviceName,
        isHealthy: camera.isHealthy,
        lastSuccessfulCommunication: camera.lastSuccessfulCommunication,
      ),
    );
  }

  // Only devices we are actually talking to belong in the heartbeat list. A
  // device id survives a refused connection — clicking Connect on the built-in
  // guider without a focal length left its id in the notifier — and admitting
  // that as an unhealthy heartbeat dropped System Health to "75 - Good / 1
  // issue" for a device that was never reached and still showed "Connect" with
  // a grey dot. The same held for a device the user deliberately disconnected.
  // Genuine mid-session drops are not lost: they arrive as `Disconnected`
  // events in the USB disconnect log, which `buildSnapshots` folds in.
  void addBasic(
    String? deviceId,
    String? deviceLabel,
    DeviceConnectionState connectionState,
    bool hasError,
  ) {
    if (deviceId == null || deviceId.isEmpty) return;
    if (connectionState != DeviceConnectionState.connected) return;
    descriptors.add(
      DeviceConnectionDescriptor(
        deviceId: deviceId,
        deviceLabel: deviceLabel,
        isHealthy: !hasError,
      ),
    );
  }

  final mount = ref.watch(mountStateProvider);
  addBasic(
    mount.deviceId,
    mount.deviceName,
    mount.connectionState,
    mount.hasError,
  );
  final focuser = ref.watch(focuserStateProvider);
  addBasic(
    focuser.deviceId,
    focuser.deviceName,
    focuser.connectionState,
    focuser.hasError,
  );
  final filterWheel = ref.watch(filterWheelStateProvider);
  addBasic(
    filterWheel.deviceId,
    filterWheel.deviceName,
    filterWheel.connectionState,
    filterWheel.hasError,
  );
  final rotator = ref.watch(rotatorStateProvider);
  addBasic(
    rotator.deviceId,
    rotator.deviceName,
    rotator.connectionState,
    rotator.hasError,
  );
  // The guider and the auxiliary devices were missing entirely, so an errored
  // guider deducted NOTHING from the health score — the observed failure where a
  // profile guider that never came up still rendered "100 - Excellent" in green.
  // Every device the app tracks a connection state for belongs here.
  final guider = ref.watch(guiderStateProvider);
  addBasic(
    guider.deviceId,
    guider.deviceName,
    guider.connectionState,
    guider.hasError,
  );
  final dome = ref.watch(domeStateProvider);
  addBasic(dome.deviceId, dome.deviceName, dome.connectionState, dome.hasError);
  final weather = ref.watch(weatherStateProvider);
  addBasic(
    weather.deviceId,
    weather.deviceName,
    weather.connectionState,
    weather.hasError,
  );
  final safetyMonitor = ref.watch(safetyMonitorStateProvider);
  addBasic(
    safetyMonitor.deviceId,
    safetyMonitor.deviceName,
    safetyMonitor.connectionState,
    safetyMonitor.hasError,
  );

  return descriptors;
});

/// Device health snapshots derived from the live equipment-state notifiers
/// plus the rolling [UsbDisconnectLog]. A later change wired the production path
/// so `disconnectCountLast24h` actually carries non-zero values; before
/// this provider was a placeholder `StateProvider<[]>` that the UI never
/// populated, leaving the pre-flight USB stability check inert.
///
/// Tests can override this provider with a static list if they want to
/// bypass the live wiring (e.g. preflight_rules_test does exactly that).
final deviceHealthSnapshotsProvider = Provider<List<DeviceHealthSnapshot>>((
  ref,
) {
  final service = ref.watch(equipmentHealthServiceProvider);
  final disconnectLog = ref.watch(usbDisconnectLogProvider);
  // Last-contact times for every device the backend heartbeat is polling.
  // Only the camera notifier keeps a timestamp of its own, so without this
  // every other device arrived with none and the panel could only ever say
  // "last contact unknown" for them — see [deviceLastContactProvider].
  final contacts = ref.watch(deviceLastContactProvider);
  final heartbeats = ref.watch(deviceHeartbeatHealthProvider);

  final descriptors = [
    for (final descriptor in ref.watch(connectedDeviceDescriptorsProvider))
      _withHealth(
        descriptor,
        contacts[descriptor.deviceId],
        heartbeats[descriptor.deviceId]?.health,
      ),
  ];

  return service.buildSnapshots(
    connected: descriptors,
    disconnectLog: disconnectLog,
  );
});

/// Combine contact timestamps with immediate heartbeat status changes.
/// A failed heartbeat must show up before the next contact poll, while a
/// recovery must not override another source that still reports a failure.
DeviceConnectionDescriptor _withHealth(
  DeviceConnectionDescriptor descriptor,
  DeviceContact? contact,
  HeartbeatHealth? heartbeat,
) {
  final own = descriptor.lastSuccessfulCommunication;
  final lastContact =
      contact == null || (own != null && own.isAfter(contact.lastContact))
      ? own
      : contact.lastContact;
  return DeviceConnectionDescriptor(
    deviceId: descriptor.deviceId,
    deviceLabel: descriptor.deviceLabel,
    isHealthy:
        descriptor.isHealthy &&
        (contact?.isResponsive ?? true) &&
        heartbeat != HeartbeatHealth.degraded &&
        heartbeat != HeartbeatHealth.reconnecting,
    lastSuccessfulCommunication: lastContact,
  );
}

/// Reactive equipment health report built from session history and device
/// heartbeats.
///
/// Re-evaluates whenever the sessions stream or device-health state changes.
final equipmentHealthReportProvider =
    Provider<AsyncValue<EquipmentHealthReport>>((ref) {
      final sessionsAsync = ref.watch(allSessionsProvider);
      final deviceHealth = ref.watch(deviceHealthSnapshotsProvider);
      // A device the active profile assigns but that is not connected is the
      // failure mode the heartbeat-based score is structurally blind to: no
      // connection means no heartbeat means nothing to deduct. Feed it in
      // explicitly so a rig whose guider never came up cannot read
      // "100 - Excellent".
      final offlineProfileDevices = ref.watch(
        offlineProfileDeviceNamesProvider,
      );
      final service = ref.watch(equipmentHealthServiceProvider);

      return sessionsAsync.when(
        data: (sessions) {
          final report = service.analyze(
            sessions: sessions,
            deviceHealth: deviceHealth,
            offlineProfileDevices: offlineProfileDevices,
          );
          return AsyncValue.data(report);
        },
        loading: () => const AsyncValue.loading(),
        error: (error, stackTrace) => AsyncValue.error(error, stackTrace),
      );
    });
