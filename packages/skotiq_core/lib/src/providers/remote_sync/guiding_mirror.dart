part of '../remote_sync_handler.dart';

/// The host's own window following a guider that connected or disconnected
/// through the server.
void _applyGuidingEvent(ProviderContainer container, SkotiqEvent event) {
  switch (guidingEventOf(event)) {
    case bridge.GuidingEvent_Connected():
      _noteGuiderConnected(container);
    case bridge.GuidingEvent_Disconnected():
      readDeviceConnectionNotifier(
        container,
        DeviceType.guider,
      ).setDisconnected();
    case _:
      break;
  }
}

/// A guiding Connected event names PHD2 only when no guider is in the slot.
/// A built-in guider is already connected under its own id; labeling that
/// slot `phd2_guider` is what renamed it.
void _noteGuiderConnected(ProviderContainer container) {
  final notifier = readDeviceConnectionNotifier(container, DeviceType.guider);
  final currentId = container.read(guiderStateProvider).deviceId?.trim();
  if (currentId == null || currentId.isEmpty) {
    notifier.setConnecting(kPhd2CanonicalId, kPhd2DisplayName);
  }
  notifier.setConnected();
}
