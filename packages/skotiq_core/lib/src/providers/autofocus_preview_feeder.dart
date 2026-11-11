import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/backend/event_types.dart';
import '../models/equipment/equipment_models.dart' show DeviceConnectionState;
import '../models/imaging/imaging_models.dart';
import '../models/polar_alignment_config.dart' show PolarAlignPhase;
import '../services/capture_preview_loader.dart';
import '../services/imaging_service.dart' show currentImageProvider;
import '../utils/utc_timestamp.dart';
import 'autofocus_progress_provider.dart';
import '../backend/remote_host.dart';
import 'backend_provider.dart';
import 'equipment/camera_state_provider.dart';
import 'equipment/filter_wheel_state_provider.dart';
import 'imaging_provider.dart';
import 'polar_alignment_provider.dart';

/// The frame a feeder fetch shows, and what it is.
class UtilityFrameRequest {
  const UtilityFrameRequest(this.purpose, {this.step, this.steps});

  final FramePurpose purpose;
  final int? step;
  final int? steps;
}

/// Decides when a native run has a new frame to show, and fetches it at most
/// one at a time.
///
/// Autofocus: each new point means the camera has just read out the frame it
/// was measured on. Centering and polar alignment: each completed exposure
/// while one of them runs is its frame. A frame that arrives while the
/// previous fetch is still running queues one more fetch rather than stacking
/// them: only the latest frame matters.
class AutofocusPreviewFeeder {
  AutofocusPreviewFeeder(this._fetchLatestFrame);

  final Future<void> Function(UtilityFrameRequest request) _fetchLatestFrame;
  bool _inFlight = false;
  UtilityFrameRequest? _pending;

  /// The sequencer's centering attempt in progress, from its structured
  /// progress; null outside a Center step.
  ({int attempt, int? maxAttempts})? _centering;

  /// True while a sequence's meridian flip runs: its re-centering frames are
  /// solve frames too, and the flip reports no Center progress of its own.
  bool _flipping = false;

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
    _request(
      UtilityFrameRequest(
        FramePurpose.autofocus,
        step: next.currentPoint,
        steps: next.totalPoints > 0 ? next.totalPoints : null,
      ),
    );
  }

  /// Follow the native events that say what the next exposure is for, and
  /// show the frame when an exposure that no Dart capture publishes ends.
  ///
  /// [autofocusRunning] frames are left to [onOverlayChanged], which knows
  /// the point; the run's own lights are published by the run's frame
  /// recorder once they are saved.
  void onEvent(
    SkotiqEvent event, {
    required bool autofocusRunning,
    required PolarAlignPhase polarPhase,
    required int polarPoint,
  }) {
    switch ((event.category, event.eventType)) {
      case (EventCategory.sequencer, 'TriggerFired')
          when event.data['action'] == 'MeridianFlip':
        _flipping = true;
      case (EventCategory.sequencer, 'InstructionProgress'):
        _flipping = event.data['instruction'] == 'MeridianFlip';
      case (EventCategory.sequencer, 'InstructionProgressStructured'):
        _flipping = event.data['instruction'] == 'MeridianFlip';
        if (event.data['detail_kind'] == 'Center') {
          final detail = _jsonObject(event.data['detail_json']);
          final attempt = (detail?['attempt'] as num?)?.toInt() ?? 0;
          final max = (detail?['max_attempts'] as num?)?.toInt();
          // Attempt 0 is the step starting or finishing, not a frame.
          _centering = attempt > 0
              ? (attempt: attempt, maxAttempts: max)
              : null;
        } else {
          _centering = null;
        }
      case (EventCategory.sequencer, 'NodeStarted' || 'NodeCompleted'):
        // A flip spans the step it interrupted, so only a Center step ends
        // here.
        _centering = null;
      case (
        EventCategory.sequencer,
        'FrameAccepted' || 'FrameRejected' || 'ExposureCompleted',
      ):
        // A light of the run: whatever came before it is over.
        _centering = null;
        _flipping = false;
      case (
        EventCategory.sequencer,
        'Stopped' || 'Completed' || 'SequenceFailed' || 'sequenceFailed',
      ):
        _centering = null;
        _flipping = false;
      case (EventCategory.imaging, 'ExposureComplete'):
        if (event.data['success'] != true || autofocusRunning) return;
        final centering = _centering;
        if (centering != null) {
          _request(
            UtilityFrameRequest(
              FramePurpose.centering,
              step: centering.attempt,
              steps: centering.maxAttempts,
            ),
          );
        } else if (_flipping) {
          _request(const UtilityFrameRequest(FramePurpose.centering));
        } else if (polarPhase == PolarAlignPhase.measuring ||
            polarPhase == PolarAlignPhase.adjusting) {
          _request(
            UtilityFrameRequest(
              FramePurpose.polarAlignment,
              step: polarPhase == PolarAlignPhase.measuring && polarPoint > 0
                  ? polarPoint
                  : null,
            ),
          );
        }
      default:
        break;
    }
  }

  void _request(UtilityFrameRequest request) {
    if (_inFlight) {
      _pending = request;
      return;
    }
    unawaited(_fetch(request));
  }

  Future<void> _fetch(UtilityFrameRequest request) async {
    _inFlight = true;
    try {
      await _fetchLatestFrame(request);
    } catch (_) {
      // The preview keeps its previous frame; the next frame tries again. A
      // failed fetch must never disturb the run itself.
    } finally {
      _inFlight = false;
      final pending = _pending;
      _pending = null;
      if (pending != null) unawaited(_fetch(pending));
    }
  }

  static Map<String, dynamic>? _jsonObject(Object? raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is! String) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}

/// Shows every frame a native run takes on the host's main image, labeled for
/// what it is: each autofocus point, each centering attempt of a sequence and
/// each polar alignment frame.
///
/// These runs expose natively, and their progress events carry the
/// measurement but not the image, so nothing put their frames on the canvas:
/// Tonight and the Imaging preview froze on whatever was there before the
/// run. This fetches the camera's last image when such a frame ends and
/// publishes it like any capture, as a utility frame, so it is never counted
/// as a light frame or fed to the night's quality numbers.
///
/// Watched for the whole app on the process that owns the camera. A linked
/// client follows the host's frame through the current-frame channel instead,
/// so this does nothing there.
final autofocusPreviewFeederProvider = Provider<void>((ref) {
  if (!ref.watch(backendProvider).ownsDeviceBridge) return;

  Future<void> fetchLatestFrame(UtilityFrameRequest request) async {
    final camera = ref.read(cameraStateProvider);
    final deviceId = camera.deviceId;
    if (deviceId == null ||
        camera.connectionState != DeviceConnectionState.connected) {
      return;
    }
    final result = await ref.read(backendProvider).cameraGetLastImage(deviceId);
    if (result == null) return;

    final capturedAt = tryParseUtcTimestamp(result.timestamp) ?? DateTime.now();
    // The frame already on screen (a recorder published it first).
    if (ref.read(currentImageProvider)?.capturedAt == capturedAt) return;
    final base = ref.read(exposureSettingsProvider);
    final filter = ref.read(filterWheelStateProvider).currentFilterName;
    final settings = ExposureSettings(
      exposureTime: result.exposureTime,
      gain: base.gain,
      offset: base.offset,
      binningX: base.binningX,
      binningY: base.binningY,
      filter: filter ?? base.filter,
      frameType: FrameType.light,
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
            purpose: request.purpose,
            purposeStep: request.step,
            purposeSteps: request.steps,
          ),
          deviceId,
          // A frame shown for a moment needs no raw pixels: they are a second
          // sensor-sized copy per frame, and nothing re-stretches these.
          loadRaw: false,
        );
  }

  final feeder = AutofocusPreviewFeeder(fetchLatestFrame);
  ref.listen<AutofocusOverlayState>(
    autofocusOverlayProvider,
    feeder.onOverlayChanged,
  );
  final events = ref.read(diagnosticsBackendProvider).eventStream.listen((
    event,
  ) {
    final polar = ref.read(polarAlignmentStateProvider);
    feeder.onEvent(
      event,
      autofocusRunning: ref.read(autofocusOverlayProvider).isRunning,
      polarPhase: polar.phase,
      polarPoint: polar.currentPoint,
    );
  });
  ref.onDispose(events.cancel);
});
