part of '../remote_sync_handler.dart';

/// The host's own window following a device that connected or disconnected
/// through the server.
void _applyEquipmentEvent(Object reader, SkotiqEvent event) {
  final data = event.data;
  switch (event.eventType) {
    case 'Connecting':
      _applyConnectingDevice(
        reader,
        data['device_type'] as String?,
        data['device_id'] as String?,
        data['device_name'] as String?,
      );
    case 'Connected':
      _applyConnectedDeviceFromPayload(
        reader,
        data['device_type'] as String?,
        data['device_id'] as String?,
        data['device_name'] as String?,
      );
    case 'Disconnected':
      _applyDisconnectedDevice(reader, data);
  }
}

void _invalidateEquipmentSyncProviders(Object reader) {
  _invalidate(reader, equipmentProfilesProvider);
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
