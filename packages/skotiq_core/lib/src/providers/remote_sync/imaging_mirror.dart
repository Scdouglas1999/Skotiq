part of '../remote_sync_handler.dart';

/// What an imaging event says about the exposure in flight.
sealed class _ExposureChange {
  const _ExposureChange();

  static _ExposureChange? of(SkotiqEvent event) {
    final typed = tryBridgeEventFromCoreEvent(event);
    if (typed == null) return null;
    final payload = typed.payload;
    if (payload is! bridge.EventPayload_Imaging) return null;
    return switch (payload.field0) {
      bridge.ImagingEvent_ExposureStarted(:final durationSecs) =>
        _ExposureBegan(durationSecs, frameNumber: 0),
      bridge.ImagingEvent_ExposureStartedWithFrame(
        :final durationSecs,
        :final frameNumber,
        :final totalFrames,
      ) =>
        _ExposureBegan(
          durationSecs,
          frameNumber: frameNumber,
          totalFrames: totalFrames,
        ),
      bridge.ImagingEvent_ExposureProgress(
        :final progress,
        :final remainingSecs,
      ) =>
        _ExposureTick(progress, remainingSecs),
      bridge.ImagingEvent_ExposureComplete() ||
      bridge.ImagingEvent_ExposureCompleted() ||
      bridge.ImagingEvent_ExposureCompletedWithFrame() ||
      bridge.ImagingEvent_ExposureCancelled() ||
      bridge.ImagingEvent_ExposureFailed() ||
      bridge.ImagingEvent_ExposureFailedOld() => const _ExposureOver(),
      _ => null,
    };
  }
}

final class _ExposureBegan extends _ExposureChange {
  const _ExposureBegan(
    this.durationSecs, {
    required this.frameNumber,
    this.totalFrames,
  });

  final double durationSecs;
  final int frameNumber;
  final int? totalFrames;
}

final class _ExposureTick extends _ExposureChange {
  const _ExposureTick(this.progress, this.remainingSecs);

  /// 0 to 1.
  final double progress;
  final double remainingSecs;
}

/// The frame is over, however it ended.
final class _ExposureOver extends _ExposureChange {
  const _ExposureOver();
}

/// Show an exposure this process is not running: the camera card's
/// "Exposing" and the countdown, driven as `ImagingService` drives them for a
/// capture it runs itself.
void _showExposure(ProviderContainer container, _ExposureChange change) {
  final camera = container.read(cameraStateProvider.notifier);
  final countdown = container.read(exposureProgressProvider.notifier);
  switch (change) {
    case _ExposureBegan():
      camera.setExposing(true, progress: 0.0);
      if (change.durationSecs > 0) {
        countdown.startExposure(
          change.durationSecs,
          change.frameNumber,
          change.totalFrames,
        );
      }
    case _ExposureTick(:final progress, :final remainingSecs):
      // The event carries no exposure time; work it out from the fraction
      // done and the time left.
      final total = (progress > 0.0 && progress < 1.0)
          ? remainingSecs / (1.0 - progress)
          : null;
      final elapsed = total != null
          ? (total - remainingSecs).clamp(0.0, total).toDouble()
          : 0.0;
      camera.setExposing(true, progress: progress);
      countdown.updateProgress(elapsed, remainingSecs, progress * 100);
    case _ExposureOver():
      // A countdown left standing reads as an exposure still in flight.
      camera.setExposing(false);
      countdown.reset();
  }
}

/// A client linked to a host from before the exposure channel
/// ([ExposureChannel]) follows the host camera's own events instead.
void _followExposureOfOlderHost(ProviderContainer container, SkotiqEvent event) {
  final mirrored = container
      .read(clientRuntimeMirrorStateProvider)
      .hostPublishes(ExposureChannel.channelKey);
  if (mirrored) return;
  final change = _ExposureChange.of(event);
  if (change != null) _showExposure(container, change);
}

/// Whether the host is showing an exposure it did not start.
final _hostFollowsForeignExposureProvider = StateProvider<bool>((ref) => false);

/// The host showing an exposure its capture service did not start, from the
/// camera's own events.
///
/// A capture the host's service runs (Snapshot, Loop, autofocus) marks the
/// camera exposing before the native exposure begins, so an exposure that
/// starts while the camera reads idle belongs to something else: a frame of
/// the run, a linked client's snapshot or an API capture. Only those are
/// followed, and only from their start, so the service's own capture keeps
/// sole control of its countdown.
void followHostCameraExposure(ProviderContainer container, SkotiqEvent event) {
  final change = _ExposureChange.of(event);
  if (change == null) return;
  final following = container.read(_hostFollowsForeignExposureProvider.notifier);
  switch (change) {
    case _ExposureBegan():
      if (!following.state && container.read(cameraStateProvider).isExposing) {
        return;
      }
      following.state = true;
    case _ExposureTick():
      if (!following.state) return;
    case _ExposureOver():
      if (!following.state) return;
      following.state = false;
  }
  _showExposure(container, change);
}

/// The widest JPEG a linked client asks the host for when it follows the
/// host's frame. Measured for a 26 MP frame with the app's encoder, compiled:
/// the host spent 2.6 s encoding the full frame into 9.4 MB and the client
/// 2.9 s decoding it; at 2560 px wide that is 0.55 s, 1.7 MB and 0.5 s. The
/// stage shows a frame at the window's width anyway; the saved FITS keeps
/// full resolution.
const kRemotePreviewMaxWidth = 2560;

/// Guards against re-entrant / chatty frame fetches. Host frame events
/// (`ImageReady`, `ImageSaved`, `ImageCaptured`) often arrive back-to-back for
/// the same capture; we only ever want one in-flight `cameraGetLastImage` at a
/// time. A coalescing flag is sufficient here — a fresh frame event always
/// triggers another fetch once the prior one resolves, so we never miss the
/// latest frame, but we never stack redundant network round-trips either.
class _RemoteFrameFetchState {
  bool inFlight = false;
  SkotiqBackend? pendingBackend;
  HostFrameHint? hint;
}

/// What the host said about the frame on its screen.
class HostFrameHint {
  const HostFrameHint({
    required this.width,
    required this.height,
    this.filePath,
    this.targetName,
    this.settings,
    this.capturedAt,
    this.purpose = FramePurpose.capture,
    this.purposeStep,
    this.purposeSteps,
  });

  final int width;
  final int height;
  final String? filePath;
  final String? targetName;
  final ExposureSettings? settings;

  /// When the host says the frame was captured. The camera's own timestamp
  /// is the end of the readout, the host's the start of the exposure; a
  /// client that kept the camera's could not tell the host's later
  /// announcement of the same frame (with its saved path) from a new frame,
  /// and downloaded it a second time.
  final DateTime? capturedAt;

  /// What the host's frame is for (an autofocus point, a centering attempt).
  final FramePurpose purpose;
  final int? purposeStep;
  final int? purposeSteps;
}

final _remoteFrameFetchStateProvider = Provider<_RemoteFrameFetchState>(
  (ref) => _RemoteFrameFetchState(),
);

/// Remote-only: fetch the host's latest frame and publish it into
/// `currentImageProvider` so the dashboard cockpit "current frame" tile (and
/// its histogram/stats) updates during a host-run sequence.
///
/// Reuses the exact remoted path the Camera tab uses
/// (the host's last camera image as a JPEG), builds the same
/// [CapturedImageData] shape via [capturedImageDataFromResult], and hands it to
/// the shared [CapturePreviewPublisher] so the remote source tag and background
/// raw-pixel load behave identically to a local capture.
Future<void> _publishRemoteCurrentFrame(
  ProviderContainer container,
  SkotiqBackend backend,
) async {
  if (container.backendScopeOver(backend).isStale) return;
  final fetchState = container.read(_remoteFrameFetchStateProvider);
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
    final cameraState = container.read(cameraStateProvider);
    final deviceId = cameraState.deviceId;
    if (deviceId == null ||
        cameraState.connectionState != DeviceConnectionState.connected) {
      return;
    }

    final mirror = backend.remoteHost?.runtimeMirror;
    if (mirror == null) return;
    final result = await mirror.cameraGetLastImage(
      deviceId,
      maxWidth: kRemotePreviewMaxWidth,
    );
    if (container.backendScopeOver(backend).isStale) return;
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
    final baseSettings = container.read(exposureSettingsProvider);
    final filterState = container.read(filterWheelStateProvider);
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

    final hint = fetchState.hint;
    final hinted =
        hint != null &&
        hint.width == result.width &&
        hint.height == result.height;
    if (hinted && hint.capturedAt != null) capturedAt = hint.capturedAt!;
    final imageData = capturedImageDataFromResult(
      capturedImage: result,
      settings: hinted && hint.settings != null ? hint.settings! : settings,
      capturedAt: capturedAt,
      targetName: hinted ? hint.targetName : null,
      filePath: hinted ? hint.filePath : null,
      previewSource: CapturePreviewSource.remote,
      purpose: hinted ? hint.purpose : FramePurpose.capture,
      purposeStep: hinted ? hint.purposeStep : null,
      purposeSteps: hinted ? hint.purposeSteps : null,
    );

    // A frame already on screen is not published again: that would clear its
    // raw pixels and download them a second time to redraw the same image.
    final shown = container.read(currentImageProvider);
    if (shown != null &&
        shown.previewSource == CapturePreviewSource.remote &&
        shown.capturedAt == imageData.capturedAt &&
        shown.width == imageData.width &&
        shown.height == imageData.height &&
        (imageData.filePath == null || shown.filePath == imageData.filePath)) {
      return;
    }

    // Publish through the shared publisher: it tags the source from the live
    // backend, schedules the background raw-pixel load, and writes both
    // `currentImageProvider` and `lastImageStatsProvider`.
    if (container.backendScopeOver(backend).isStale) return;
    // A frame the host announced is the host's to solve; marked before the
    // publish, whose listeners decide whether to solve it here.
    if (hinted) {
      container.read(hostFrameSolvesProvider).mirroredFrame =
          imageData.capturedAt;
    }
    container.read(capturePreviewPublisherProvider,
    ).publish(container, imageData, deviceId, loadRaw: !hinted);
  } catch (_) {
    // Degrade gracefully: a failed/aborted fetch must never crash the event
    // pump or spam logs. The tile simply keeps its previous frame; the next
    // frame event will try again.
  } finally {
    fetchState.inFlight = false;
    final pendingBackend = fetchState.pendingBackend;
    fetchState.pendingBackend = null;
    if (pendingBackend != null &&
        container.backendScopeOver(pendingBackend).isCurrent) {
      unawaited(_publishRemoteCurrentFrame(container, pendingBackend));
    }
  }
}
