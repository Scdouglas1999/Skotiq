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

/// The hydration currently running per host, and whether another guiding
/// event arrived while it ran.
final Expando<Future<void>> _phd2HydrationInFlight = Expando();
final Expando<bool> _phd2HydrationRequested = Expando();

/// Shortest gap between two status reads for the same host.
const Duration _phd2HydrationMinGap = Duration(seconds: 2);

/// Mirror the host's PHD2 connection into this companion's guider state with
/// one status read. Guiding events arrive in bursts, so a read already running
/// absorbs every event that arrives meanwhile into one follow-up read, made at
/// least [_phd2HydrationMinGap] later.
Future<void> _hydratePhd2GuiderState(Object reader, NetworkBackend backend) {
  final running = _phd2HydrationInFlight[backend];
  if (running != null) {
    _phd2HydrationRequested[backend] = true;
    return running;
  }
  final future = () async {
    while (true) {
      _phd2HydrationRequested[backend] = false;
      await _readPhd2GuiderStateOnce(reader, backend);
      if (_phd2HydrationRequested[backend] != true) break;
      await Future<void>.delayed(_phd2HydrationMinGap);
      if (!_isCurrentRemoteBackend(reader, backend)) break;
    }
  }();
  _phd2HydrationInFlight[backend] = future;
  return future.whenComplete(() => _phd2HydrationInFlight[backend] = null);
}

Future<void> _readPhd2GuiderStateOnce(
  Object reader,
  NetworkBackend backend,
) async {
  final notifier = readDeviceConnectionNotifier(reader, DeviceType.guider);
  final priorState = _read(reader, guiderStateProvider);

  try {
    final status = await backend.phd2GetStatus();
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
    // A held guider says why. Only a reason is applied: the run status,
    // which the host always sends, is what clears it.
    final stopReason = status.stopReason;
    if (stopReason != null && stopReason.isNotEmpty) {
      _read(reader, guidingStopReasonProvider.notifier).state = stopReason;
    }
  } catch (_) {
    // Do not clear a PHD2 guider restored from getConnectedDevices when the
    // status endpoint is briefly unavailable during host launch.
  }
}
