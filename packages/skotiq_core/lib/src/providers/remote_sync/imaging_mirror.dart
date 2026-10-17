part of '../remote_sync_handler.dart';

/// Slave-only: mirror the master's per-frame exposure countdown by driving the
/// same notifiers [ImagingService] drives on the host. The host capture loop
/// never runs on a remote companion, so these imaging-category events are the
/// slave's only source for the camera card's "Exposing" status and the
/// remaining-time countdown. Payload keys match the host emitter
/// (`progress`/`remainingSecs`), with snake_case fallbacks for the
/// `ExposureStarted` frame fields.
void _applyExposureMirror(
  Object reader,
  String eventType,
  Map<String, dynamic> data,
) {
  final cameraNotifier = _read(reader, cameraStateProvider.notifier);
  final progressNotifier = _read(reader, exposureProgressProvider.notifier);
  switch (eventType) {
    case 'ExposureStarted':
    case 'ExposureStartedWithFrame':
      final duration =
          (data['durationSecs'] as num?)?.toDouble() ??
          (data['duration_secs'] as num?)?.toDouble() ??
          0.0;
      final frameNumber =
          (data['frameNumber'] as num?)?.toInt() ??
          (data['frame_number'] as num?)?.toInt() ??
          0;
      final totalFrames =
          (data['totalFrames'] as num?)?.toInt() ??
          (data['total_frames'] as num?)?.toInt();
      cameraNotifier.setExposing(true, progress: 0.0);
      if (duration > 0) {
        progressNotifier.startExposure(duration, frameNumber, totalFrames);
      }
      break;
    case 'ExposureProgress':
      final progress = (data['progress'] as num?)?.toDouble() ?? 0.0;
      final remaining =
          (data['remainingSecs'] as num?)?.toDouble() ??
          (data['remaining_secs'] as num?)?.toDouble() ??
          0.0;
      // The slave does not know the configured exposure time locally, so derive
      // elapsed defensively from progress + remaining.
      final total = (progress > 0.0 && progress < 1.0)
          ? remaining / (1.0 - progress)
          : null;
      final elapsed = total != null
          ? (total - remaining).clamp(0.0, total).toDouble()
          : 0.0;
      cameraNotifier.setExposing(true, progress: progress);
      progressNotifier.updateProgress(elapsed, remaining, progress * 100);
      break;
    case 'ExposureComplete':
    case 'ExposureCancelled':
      cameraNotifier.setExposing(false);
      break;
  }
}

/// Guards against re-entrant / chatty frame fetches. Host frame events
/// (`ImageReady`, `ImageSaved`, `ImageCaptured`) often arrive back-to-back for
/// the same capture; we only ever want one in-flight `cameraGetLastImage` at a
/// time. A coalescing flag is sufficient here — a fresh frame event always
/// triggers another fetch once the prior one resolves, so we never miss the
/// latest frame, but we never stack redundant network round-trips either.
class _RemoteFrameFetchState {
  bool inFlight = false;
  NetworkBackend? pendingBackend;
}

final Expando<_RemoteFrameFetchState> _remoteFrameFetchStates =
    Expando<_RemoteFrameFetchState>('remoteFrameFetchState');

/// Remote-only: fetch the host's latest frame and publish it into
/// `currentImageProvider` so the dashboard cockpit "current frame" tile (and
/// its histogram/stats) updates during a host-run sequence.
///
/// Reuses the exact remoted path the Camera tab uses
/// ([NetworkBackend.cameraGetLastImage] → JPEG wire), builds the same
/// [CapturedImageData] shape via [capturedImageDataFromResult], and hands it to
/// the shared [CapturePreviewPublisher] so the remote source tag and background
/// raw-pixel load behave identically to a local capture.
Future<void> _publishRemoteCurrentFrame(
  Object reader,
  NetworkBackend backend,
) async {
  if (!_isCurrentRemoteBackend(reader, backend)) return;
  final fetchState = _remoteFrameFetchStates[reader] ??=
      _RemoteFrameFetchState();
  // Coalesce: if a fetch is already running, mark that another frame arrived
  // and let the current fetch re-run once on completion.
  if (fetchState.inFlight) {
    fetchState.pendingBackend = backend;
    return;
  }
  fetchState.inFlight = true;

  try {
    // The imaging events do not carry a device id; resolve the connected
    // camera from local equipment state (mirrored from the host).
    final cameraState = _read(reader, cameraStateProvider);
    final deviceId = cameraState.deviceId;
    if (deviceId == null ||
        cameraState.connectionState != DeviceConnectionState.connected) {
      return;
    }

    final result = await backend.cameraGetLastImage(deviceId);
    if (!_isCurrentRemoteBackend(reader, backend)) return;
    if (result == null) {
      // No frame cached host-side yet — leave the tile as-is.
      return;
    }

    DateTime capturedAt;
    try {
      capturedAt = parseUtcTimestamp(result.timestamp);
    } catch (_) {
      capturedAt = DateTime.now();
    }

    // Mirror the operator's current exposure controls, but let the host's
    // reported exposure time win so the frame badge matches the real frame.
    final baseSettings = _read(reader, exposureSettingsProvider);
    final filterState = _read(reader, filterWheelStateProvider);
    final settings = ExposureSettings(
      exposureTime: result.exposureTime,
      gain: baseSettings.gain,
      offset: baseSettings.offset,
      binningX: baseSettings.binningX,
      binningY: baseSettings.binningY,
      filter: filterState.currentFilterName ?? baseSettings.filter,
      frameType: baseSettings.frameType,
      fastReadout: baseSettings.fastReadout,
      readoutModeIndex: baseSettings.readoutModeIndex,
    );

    final imageData = capturedImageDataFromResult(
      capturedImage: result,
      settings: settings,
      capturedAt: capturedAt,
      previewSource: CapturePreviewSource.remote,
    );

    // Publish through the shared publisher: it tags the source from the live
    // backend, schedules the background raw-pixel load, and writes both
    // `currentImageProvider` and `lastImageStatsProvider`.
    if (!_isCurrentRemoteBackend(reader, backend)) return;
    _read(
      reader,
      capturePreviewPublisherProvider,
    ).publish(reader, imageData, deviceId);
  } catch (_) {
    // Degrade gracefully: a failed/aborted fetch must never crash the event
    // pump or spam logs. The tile simply keeps its previous frame; the next
    // frame event will try again.
  } finally {
    fetchState.inFlight = false;
    final pendingBackend = fetchState.pendingBackend;
    fetchState.pendingBackend = null;
    if (pendingBackend != null &&
        _isCurrentRemoteBackend(reader, pendingBackend)) {
      unawaited(_publishRemoteCurrentFrame(reader, pendingBackend));
    }
  }
}
