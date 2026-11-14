part of '../remote_sync_handler.dart';

/// The host's own window following a guider that connected or disconnected
/// through the server.
void _applyGuidingEvent(ProviderContainer container, SkotiqEvent event) {
  switch (event.eventType) {
    case 'Connected':
      final notifier = readDeviceConnectionNotifier(
        container,
        DeviceType.guider,
      );
      if (!_isDeviceAlreadyConnected(
        container,
        DeviceType.guider,
        'phd2_guider',
      )) {
        notifier.setConnecting(kPhd2CanonicalId, kPhd2DisplayName);
      }
      notifier.setConnected();
    case 'Disconnected':
      readDeviceConnectionNotifier(
        container,
        DeviceType.guider,
      ).setDisconnected();
  }
}
