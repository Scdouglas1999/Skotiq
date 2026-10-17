part of '../remote_sync_handler.dart';

Future<void> _applyGuidingEvent(
  Object reader,
  SkotiqEvent event, {
  NetworkBackend? networkBackend,
}) async {
  switch (event.eventType) {
    case 'Connected':
      final notifier = readDeviceConnectionNotifier(reader, DeviceType.guider);
      if (!_isDeviceAlreadyConnected(
        reader,
        DeviceType.guider,
        'phd2_guider',
      )) {
        notifier.setConnecting('phd2_guider', 'PHD2');
      }
      notifier.setConnected();
      break;
    case 'Disconnected':
      readDeviceConnectionNotifier(reader, DeviceType.guider).setDisconnected();
      break;
    case 'GuidingStarted':
    case 'GuidingStopped':
    case 'AppState':
      if (networkBackend != null) {
        await _hydratePhd2GuiderState(reader, networkBackend);
      }
      break;
  }
}

Future<void> _hydratePhd2GuiderState(
  Object reader,
  NetworkBackend backend,
) async {
  final notifier = readDeviceConnectionNotifier(reader, DeviceType.guider);
  final priorState = _read(reader, guiderStateProvider);

  try {
    final status = await pollPhd2Connected(
      backend,
      timeout: const Duration(seconds: 5),
      interval: const Duration(milliseconds: 250),
    );
    if (!_isCurrentRemoteBackend(reader, backend)) return;
    if (!status.connected) {
      if (isPhd2GuiderDeviceId(priorState.deviceId)) {
        notifier.setDisconnected();
      }
      return;
    }
    if (!_isDeviceAlreadyConnected(reader, DeviceType.guider, 'phd2_guider')) {
      notifier.setConnecting('phd2_guider', 'PHD2');
    }
    notifier.setConnected();
  } catch (_) {
    // Do not clear a PHD2 guider restored from getConnectedDevices when the
    // status endpoint is briefly unavailable during host launch.
  }
}
