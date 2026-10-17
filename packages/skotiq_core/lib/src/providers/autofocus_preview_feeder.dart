import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/equipment/equipment_models.dart' show DeviceConnectionState;
import '../models/imaging/imaging_models.dart';
import '../services/capture_preview_loader.dart';
import '../utils/utc_timestamp.dart';
import 'autofocus_progress_provider.dart';
import 'backend_provider.dart';
import 'equipment/camera_state_provider.dart';
import 'equipment/filter_wheel_state_provider.dart';
import 'imaging_provider.dart';

/// Decides when an autofocus run has a new frame to show, and fetches it at
/// most one at a time.
///
/// Each new point means the camera has just read out the frame it was
/// measured on. A point that arrives while the previous fetch is still running
/// queues one more fetch rather than stacking them: only the latest frame
/// matters.
class AutofocusPreviewFeeder {
  AutofocusPreviewFeeder(this._fetchLatestFrame);

  final Future<void> Function() _fetchLatestFrame;
  bool _inFlight = false;
  bool _pending = false;

  void onOverlayChanged(
    AutofocusOverlayState? prev,
    AutofocusOverlayState next,
  ) {
    if (!next.isRunning || next.currentPoint == 0) return;
    if (prev != null &&
        prev.isRunning &&
        prev.currentPoint == next.currentPoint) {
      return;
    }
    unawaited(_fetch());
  }

  Future<void> _fetch() async {
    if (_inFlight) {
      _pending = true;
      return;
    }
    _inFlight = true;
    try {
      await _fetchLatestFrame();
    } catch (_) {
      // The preview keeps its previous frame; the next point tries again. A
      // failed fetch must never disturb the autofocus run itself.
    } finally {
      _inFlight = false;
      if (_pending) {
        _pending = false;
        unawaited(_fetch());
      }
    }
  }
}

/// Shows each autofocus frame in the Imaging preview as the run measures it.
///
/// Autofocus exposes natively, and its progress events carry the measurement
/// (position, HFR, star crops) but not the image, so nothing used to put an
/// autofocus frame on the canvas: the preview froze on whatever was there
/// before the run. This fetches the camera's last image at every new point and
/// publishes it like any capture. Watch it from a screen that shows the
/// preview.
final autofocusPreviewFeederProvider = Provider<void>((ref) {
  Future<void> fetchLatestFrame() async {
    final camera = ref.read(cameraStateProvider);
    final deviceId = camera.deviceId;
    if (deviceId == null ||
        camera.connectionState != DeviceConnectionState.connected) {
      return;
    }
    final result = await ref.read(backendProvider).cameraGetLastImage(deviceId);
    if (result == null) return;

    final capturedAt = tryParseUtcTimestamp(result.timestamp) ?? DateTime.now();
    final base = ref.read(exposureSettingsProvider);
    final filter = ref.read(filterWheelStateProvider).currentFilterName;
    final settings = ExposureSettings(
      exposureTime: result.exposureTime,
      gain: base.gain,
      offset: base.offset,
      binningX: base.binningX,
      binningY: base.binningY,
      filter: filter ?? base.filter,
      frameType: base.frameType,
      fastReadout: base.fastReadout,
      readoutModeIndex: base.readoutModeIndex,
    );
    ref
        .read(capturePreviewPublisherProvider)
        .publish(
          ref,
          capturedImageDataFromResult(
            capturedImage: result,
            settings: settings,
            capturedAt: capturedAt,
          ),
          deviceId,
        );
  }

  final feeder = AutofocusPreviewFeeder(fetchLatestFrame);
  ref.listen<AutofocusOverlayState>(
    autofocusOverlayProvider,
    feeder.onOverlayChanged,
  );
});
