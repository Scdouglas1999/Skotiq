part of '../remote_sync_handler.dart';

/// The host's own window following a device that connected or disconnected
/// through the server.
void _applyEquipmentEvent(ProviderContainer container, SkotiqEvent event) {
  switch (equipmentEventOf(event)) {
    case bridge.EquipmentEvent_Connecting(
      :final deviceType,
      :final deviceId,
      :final deviceName,
    ):
      _applyConnectingDevice(container, deviceType, deviceId, deviceName);
    case bridge.EquipmentEvent_Connected(
      :final deviceType,
      :final deviceId,
      :final deviceName,
    ):
      _applyConnectedDeviceFromPayload(
        container,
        deviceType,
        deviceId,
        deviceName,
      );
    case bridge.EquipmentEvent_Disconnected():
      _applyDisconnectedDevice(container, event.data);
    default:
      break;
  }
}

void _invalidateEquipmentSyncProviders(ProviderContainer container) {
  container.invalidate(equipmentProfilesProvider);
  // Deliberately NOT invalidating unifiedDiscoveryProvider here. It is a
  // StateNotifier whose state resets to an EMPTY device list on invalidation
  // and does not auto-rediscover, so invalidating it on every remote
  // Connected/Disconnected event wipes the user's scanned "Available Devices"
  // list (the whole panel goes blank the instant they connect a device in
  // remote-client mode). Device connection *status* is tracked by the
  // per-class device state providers (updated above via the sync payload),
  // not by the discovery list, so the discovered set is stable across
  // connect/disconnect and must be left intact.
}
