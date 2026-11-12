part of '../remote_sync_handler.dart';

/// The host's own window following a guider that connected or disconnected
/// through the server.
void _applyGuidingEvent(Object reader, SkotiqEvent event) {
  switch (event.eventType) {
    case 'Connected':
      final notifier = readDeviceConnectionNotifier(reader, DeviceType.guider);
      if (!_isDeviceAlreadyConnected(
        reader,
        DeviceType.guider,
        'phd2_guider',
      )) {
        notifier.setConnecting(kPhd2CanonicalId, kPhd2DisplayName);
      }
      notifier.setConnected();
    case 'Disconnected':
      readDeviceConnectionNotifier(reader, DeviceType.guider).setDisconnected();
  }
}
