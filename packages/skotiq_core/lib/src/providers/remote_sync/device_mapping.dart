part of '../remote_sync_handler.dart';

void _applyDisconnectedDevice(Object reader, Map<String, dynamic> data) {
  final deviceType = data['device_type'] as String?;
  if (deviceType == null) {
    return;
  }

  final parsed = deviceTypeFromWireName(deviceType);
  if (parsed == null) {
    return;
  }
  final deviceId = data['device_id'] as String?;
  if (_isHostGuideCamera(reader, parsed, deviceId)) return;

  readDeviceConnectionNotifier(reader, parsed).setDisconnected();
}

void _applyConnectingDevice(
  Object reader,
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

  if (_isHostGuideCamera(reader, parsed, deviceId)) return;
  final notifier = readDeviceConnectionNotifier(reader, parsed);
  if (!_isDeviceAlreadyConnected(reader, parsed, deviceId)) {
    notifier.setConnecting(deviceId, deviceName ?? deviceId);
  }
}

void _applyConnectedDeviceFromPayload(
  Object reader,
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
  if (_isHostGuideCamera(reader, parsed, deviceId)) return;

  final notifier = readDeviceConnectionNotifier(reader, parsed);
  if (!_isDeviceAlreadyConnected(reader, parsed, deviceId)) {
    notifier.setConnecting(deviceId, deviceName ?? deviceId);
  }
  notifier.setConnected();
}

bool _isDeviceAlreadyConnected(
  Object reader,
  DeviceType deviceType,
  String deviceId,
) {
  final notifier = readDeviceConnectionNotifier(reader, deviceType);
  return notifier.connectionState == DeviceConnectionState.connected &&
      notifier.deviceId == deviceId;
}

/// Whether a host device event is about the profile's guide camera, which has
/// no slot of its own and must not take the imaging camera's.
bool _isHostGuideCamera(Object reader, DeviceType? type, String? deviceId) =>
    type == DeviceType.camera &&
    isProfileGuideCamera(
      _read(reader, activeEquipmentProfileProvider),
      deviceId,
    );

void _applyConnectedDevice(Object reader, DeviceInfo device) {
  if (_isHostGuideCamera(reader, device.deviceType, device.id)) return;
  final notifier = readDeviceConnectionNotifier(reader, device.deviceType);
  if (!_isDeviceAlreadyConnected(reader, device.deviceType, device.id)) {
    notifier.setConnecting(device.id, device.name);
  }
  notifier.setConnected();
}
