part of '../remote_sync_handler.dart';

void _applyDeviceConnectedFromSyncPayload(
  Object reader,
  Map<String, dynamic> data,
) {
  _applyConnectedDeviceFromPayload(
    reader,
    data['device_type'] as String? ?? data['deviceType'] as String?,
    data['device_id'] as String? ?? data['deviceId'] as String?,
    data['device_name'] as String? ?? data['deviceName'] as String?,
  );
}

void _applyDeviceDisconnectedFromSyncPayload(
  Object reader,
  Map<String, dynamic> data,
) {
  final deviceType =
      data['device_type'] as String? ?? data['deviceType'] as String?;
  if (deviceType == null) {
    return;
  }

  final parsed = deviceTypeFromWireName(deviceType);
  if (parsed == null) {
    return;
  }

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

void _applyConnectedDevice(Object reader, DeviceInfo device) {
  final notifier = readDeviceConnectionNotifier(reader, device.deviceType);
  if (!_isDeviceAlreadyConnected(reader, device.deviceType, device.id)) {
    notifier.setConnecting(device.id, device.name);
  }
  notifier.setConnected();
}
