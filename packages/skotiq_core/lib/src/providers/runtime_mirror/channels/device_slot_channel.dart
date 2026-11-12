import '../../../backend/skotiq_backend.dart';
import '../../../models/equipment/equipment_models.dart';
import '../../../services/device_service_lifecycle.dart';
import '../../device_heartbeat_health_provider.dart';
import '../../equipment/device_slots.dart';
import '../../profiles_provider.dart';
import '../../ui_notification_provider.dart';
import '../client_runtime_mirror.dart';
import '../runtime_mirror_channel.dart';
import '../runtime_mirror_codec.dart';

/// One device slot of the host: which device it holds, its connection state
/// and error, and the readings its card shows.
///
/// There is one channel per row of the device table, so a client that links
/// (or links again after a host restart) shows the host's devices as the
/// host's own window does, and a device type added to the table is mirrored
/// without anything written here.
class DeviceSlotChannel
    extends RuntimeMirrorChannel<DeviceSlotState<Object?>> {
  const DeviceSlotChannel(this.slot);

  final DeviceSlot slot;

  @override
  String get key => 'device.${slot.wireNames.first}';

  @override
  get source => slot.state;

  /// A reading can change with every poll of the device.
  @override
  Duration get minInterval => const Duration(seconds: 1);

  /// A command a client sends shows its result at once; when the host then
  /// refuses it, the host's state comes back with the next re-read. The
  /// re-read is also the host saying it still holds the device.
  @override
  bool get reappliesOnReread => true;

  @override
  Map<String, dynamic>? encode(DeviceSlotState<Object?> value) {
    final error = value.lastError;
    final deviceId = value.deviceId;
    if (deviceId == null && error == null) return null;
    final readings = slot.readings;
    return {
      'state': value.connectionState.name,
      'deviceId': deviceId,
      'deviceName': value.deviceName,
      if (error != null)
        'error': {
          'type': error.type.name,
          'message': error.message,
          'code': error.code,
          'deviceId': error.deviceId,
          'recoverable': error.recoverable,
        },
      if (readings != null && deviceId != null)
        'readings': readings.encode(value),
    };
  }

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    if (context.networkBackend == null) return;
    final notifier = readDeviceConnectionNotifier(context.reader, slot.type);
    final shownId = notifier.deviceId;
    final deviceId = jsonString(value?['deviceId']);
    if (_ownConnectHolds(context.reader, deviceId)) return;
    final state = jsonString(value?['state']);
    final readings = value?['readings'];
    final decoder = slot.readings;
    notifier.mirrorHost(
      connectionState: DeviceConnectionState.values.firstWhere(
        (candidate) => candidate.name == state,
        orElse: () => DeviceConnectionState.disconnected,
      ),
      deviceId: deviceId,
      deviceName: jsonString(value?['deviceName']),
      lastError: _error(value?['error']),
      readings: decoder != null && readings is Map
          ? (current) =>
                decoder.decode(current, Map<String, dynamic>.from(readings))
          : null,
    );
    if (shownId != null && shownId != deviceId) {
      context
          .read(deviceHeartbeatHealthProvider.notifier)
          .clearDevice(shownId);
    }
  }

  /// Whether a connect this client asked for owns the slot: in flight (the
  /// host shows the device only once it is up) or just failed (a host value
  /// from before the refusal would put the failed slot back to connecting).
  bool _ownConnectHolds(Object reader, String? hostDeviceId) {
    final shown = readDeviceSlot(reader, slot.type).retryDeviceId;
    return (shown != null && DeviceServiceLifecycle.hasOwnConnectOf(shown)) ||
        (hostDeviceId != null &&
            DeviceServiceLifecycle.hasOwnConnectOf(hostDeviceId));
  }

  static DeviceError? _error(Object? json) {
    if (json is! Map) return null;
    final type = jsonString(json['type']);
    return DeviceError(
      type: DeviceErrorType.values.firstWhere(
        (candidate) => candidate.name == type,
        orElse: () => DeviceErrorType.unknown,
      ),
      message: jsonString(json['message']) ?? '',
      code: jsonString(json['code']),
      timestamp: DateTime.now(),
      deviceId: jsonString(json['deviceId']),
      recoverable: json['recoverable'] != false,
    );
  }
}

/// The device channels, one per row of the device table.
final List<DeviceSlotChannel> deviceSlotChannels = List.unmodifiable([
  for (final slot in deviceSlots) DeviceSlotChannel(slot),
]);

/// Show what a host older than the device channels has connected.
///
/// Such a host sends no device channel, so its connected-device list fills
/// the slots: a client can still see which devices the rig holds and start
/// its run. Readings, the guider's state and the host's open plan need the
/// host updated; the operator is told once per link.
Future<void> mirrorDevicesOfOlderHost(
  Object reader,
  SkotiqBackend backend, {
  required bool Function() isCurrent,
}) async {
  final mirror = RuntimeApplyContext(
    reader,
    networkBackend: backend,
  ).read(clientRuntimeMirrorStateProvider);
  if (mirror.hostPublishes(deviceSlotChannels.first.key)) return;
  final devices = await backend.getConnectedDevices();
  if (!isCurrent()) return;
  final context = RuntimeApplyContext(reader, networkBackend: backend);
  // The guide camera has no slot of its own and must not take the imaging
  // camera's.
  final guideProfile = context.read(activeEquipmentProfileProvider);
  for (final channel in deviceSlotChannels) {
    final type = channel.slot.type;
    // PHD2 is not always in an older host's device list.
    if (type == DeviceType.guider) continue;
    final device = devices
        .where(
          (candidate) =>
              candidate.deviceType == type &&
              !(type == DeviceType.camera &&
                  isProfileGuideCamera(guideProfile, candidate.id)),
        )
        .firstOrNull;
    final shown = readDeviceSlot(reader, type);
    if (device == null && shown.deviceId == null) continue;
    final ownConnect = shown.retryDeviceId ?? device?.id;
    if (ownConnect != null &&
        DeviceServiceLifecycle.hasOwnConnectOf(ownConnect)) {
      continue;
    }
    if (device != null &&
        shown.deviceId == device.id &&
        shown.connectionState == DeviceConnectionState.connected) {
      continue;
    }
    readDeviceConnectionNotifier(reader, type).mirrorHost(
      connectionState: device == null
          ? DeviceConnectionState.disconnected
          : DeviceConnectionState.connected,
      deviceId: device?.id,
      deviceName: device?.name,
      lastError: null,
    );
  }
  if (mirror.olderHostNoticed) return;
  mirror.olderHostNoticed = true;
  context
      .read(uiNotificationProvider.notifier)
      .showWarning(
        'This host runs an older Skotiq: device readings, guider state and '
        'its open plan are not shown here. Update the host.',
        title: 'Host needs an update',
      );
}
