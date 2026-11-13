part of '../remote_sync_handler.dart';

void _applyDisconnectedDevice(ProviderContainer container, Map<String, dynamic> data) {
  final deviceType = data['device_type'] as String?;
  if (deviceType == null) {
    return;
  }

  final parsed = deviceTypeFromWireName(deviceType);
  if (parsed == null) {
    return;
  }
  final deviceId = data['device_id'] as String?;
  if (_isHostGuideCamera(container, parsed, deviceId)) return;
  _emptySlotFor(container, parsed, deviceId);
}

/// Empty [type]'s slot because the host let go of [deviceId].
///
/// Only when the slot holds that device. Emptying it for another device's
/// disconnect leaves this client showing nothing where the host still holds
/// a device (its own Disconnect all then skips it), and a slot that holds
/// no device but shows why a connect failed keeps saying so.
void _emptySlotFor(ProviderContainer container, DeviceType type, String? deviceId) {
  final notifier = readDeviceConnectionNotifier(container, type);
  final held = notifier.deviceId;
  if (held == null || held.isEmpty) {
    if (notifier.connectionState == DeviceConnectionState.error) return;
  } else if (deviceId != null && deviceId.isNotEmpty && held != deviceId) {
    return;
  }
  notifier.setDisconnected();
}

void _applyConnectingDevice(
  ProviderContainer container,
  String? deviceType,
  String? deviceId,
  String? deviceName,
) {
  if (deviceType == null || deviceId == null) {
    return;
  }

  final parsed = deviceTypeFromWireName(deviceType);
  if (parsed == null) {
    return;
  }

  if (_isHostGuideCamera(container, parsed, deviceId)) return;
  // The host announcing a connect this client asked for: the connect call
  // has set the slot, and when the announcement arrives behind the host's
  // refusal the slot already shows why it failed.
  if (container.read(connectAttemptsProvider).isOwn(deviceId)) return;
  final notifier = readDeviceConnectionNotifier(container, parsed);
  if (!_isDeviceAlreadyConnected(container, parsed, deviceId)) {
    notifier.setConnecting(deviceId, deviceName ?? deviceId);
  }
}

void _applyConnectedDeviceFromPayload(
  ProviderContainer container,
  String? deviceType,
  String? deviceId,
  String? deviceName,
) {
  if (deviceType == null || deviceId == null) {
    return;
  }

  final parsed = deviceTypeFromWireName(deviceType);
  if (parsed == null) {
    return;
  }
  if (_isHostGuideCamera(container, parsed, deviceId)) return;

  final notifier = readDeviceConnectionNotifier(container, parsed);
  if (!_isDeviceAlreadyConnected(container, parsed, deviceId)) {
    notifier.setConnecting(deviceId, deviceName ?? deviceId);
  }
  notifier.setConnected();
}

bool _isDeviceAlreadyConnected(
  ProviderContainer container,
  DeviceType deviceType,
  String deviceId,
) {
  final notifier = readDeviceConnectionNotifier(container, deviceType);
  return notifier.connectionState == DeviceConnectionState.connected &&
      notifier.deviceId == deviceId;
}

/// Whether a host device event is about the profile's guide camera, which has
/// no slot of its own and must not take the imaging camera's.
bool _isHostGuideCamera(ProviderContainer container, DeviceType? type, String? deviceId) =>
    type == DeviceType.camera &&
    isProfileGuideCamera(
      container.read(activeEquipmentProfileProvider),
      deviceId,
    );
