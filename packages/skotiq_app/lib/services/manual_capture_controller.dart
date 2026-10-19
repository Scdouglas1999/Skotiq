import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../screens/imaging/widgets/imaging_capture_bar.dart'
    show loopSavesFramesProvider;

/// What the manual Snapshot and Loop controls are doing.
@immutable
class ManualCaptureState {
  const ManualCaptureState({
    this.isSnapshot = false,
    this.isLooping = false,
    this.isStopping = false,
    this.snapshotPreviewReady = false,
    this.loopFrames = 0,
    this.lastError,
  });

  /// A single frame is being exposed, downloaded or saved.
  final bool isSnapshot;

  /// A loop is running.
  final bool isLooping;

  /// Stop was requested and the current exposure is being aborted.
  final bool isStopping;

  /// The snapshot's pixels are on screen while saving still runs.
  final bool snapshotPreviewReady;

  /// Frames the current (or last) loop delivered.
  final int loopFrames;

  /// The last capture failure, cleaned for the operator.
  final String? lastError;

  bool get isBusy => isSnapshot || isLooping || isStopping;

  ManualCaptureState copyWith({
    bool? isSnapshot,
    bool? isLooping,
    bool? isStopping,
    bool? snapshotPreviewReady,
    int? loopFrames,
    String? lastError,
    bool clearError = false,
  }) =>
      ManualCaptureState(
        isSnapshot: isSnapshot ?? this.isSnapshot,
        isLooping: isLooping ?? this.isLooping,
        isStopping: isStopping ?? this.isStopping,
        snapshotPreviewReady: snapshotPreviewReady ?? this.snapshotPreviewReady,
        loopFrames: loopFrames ?? this.loopFrames,
        lastError: clearError ? null : (lastError ?? this.lastError),
      );

  @override
  bool operator ==(Object other) =>
      other is ManualCaptureState &&
      other.isSnapshot == isSnapshot &&
      other.isLooping == isLooping &&
      other.isStopping == isStopping &&
      other.snapshotPreviewReady == snapshotPreviewReady &&
      other.loopFrames == loopFrames &&
      other.lastError == lastError;

  @override
  int get hashCode => Object.hash(isSnapshot, isLooping, isStopping,
      snapshotPreviewReady, loopFrames, lastError);
}

/// Snapshot and Loop outside the Imaging screen.
///
/// The same capture flow as `imaging_screen_actions.dart` (`_takeSnapshot`,
/// `_toggleLoop`), held in a provider so Tonight can drive it without the
/// Imaging screen's widget state. The Imaging screen still runs its own copy.
final manualCaptureControllerProvider =
    NotifierProvider<ManualCaptureController, ManualCaptureState>(
  ManualCaptureController.new,
);

class ManualCaptureController extends Notifier<ManualCaptureState> {
  /// Strips a leading `SomeException(category): ` prefix so a failure reads
  /// as English. Matched on `toString()` because `SkotiqException` is not
  /// exported from the `skotiq_core` barrel.
  static final RegExp _exceptionPrefix =
      RegExp(r'^[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?:\s*');

  static String cleanError(Object error) {
    final raw = error.toString().trim();
    final stripped = raw.replaceFirst(_exceptionPrefix, '').trim();
    return stripped.isEmpty ? raw : stripped;
  }

  /// The service that owns the capture in flight, so Stop aborts that one
  /// even after a backend switch rebuilt [imagingServiceProvider].
  ImagingService? _activeService;

  @override
  ManualCaptureState build() => const ManualCaptureState();

  /// One frame with the manual exposure settings.
  ///
  /// [persist] true saves it like an Imaging-screen snapshot (light-frame
  /// folder, `captured_images`, session totals); false takes it as a utility
  /// frame that is shown and solvable but never counted. Throws the capture
  /// error after recording it in [ManualCaptureState.lastError].
  Future<CapturedImageData?> snapshot({bool persist = true}) async {
    if (state.isBusy) return null;
    state = state.copyWith(
      isSnapshot: true,
      snapshotPreviewReady: false,
      isStopping: false,
      clearError: true,
    );

    final settings = ref.read(exposureSettingsProvider);
    final imagingService = ref.read(imagingServiceProvider);
    _activeService = imagingService;
    final sessionNotifier = ref.read(sessionStateProvider.notifier);
    sessionNotifier.setCapturing(true);

    // Pixels arrive before FITS persistence and calibration finish. Baseline
    // on the frame already on screen so a stale one does not count.
    final baselineCapturedAt = ref.read(currentImageProvider)?.capturedAt;
    final previewSubscription = ref.listen<CapturedImageData?>(
      currentImageProvider,
      (previous, next) {
        if (state.snapshotPreviewReady || next == null) return;
        if (next.capturedAt == baselineCapturedAt) return;
        state = state.copyWith(snapshotPreviewReady: true);
      },
    );

    try {
      final targetName = ref.read(sessionStateProvider).targetName;
      final result = persist
          ? await imagingService.captureImage(
              settings: settings,
              targetName: targetName,
            )
          : await imagingService.captureUtilityFrame(
              settings: settings,
              targetName: targetName,
            );
      if (result != null && identical(_activeService, imagingService)) {
        ref.read(currentImageProvider.notifier).state = result;
        ref.read(lastImageStatsProvider.notifier).state = result.stats;
        if (persist) {
          sessionNotifier.recordExposureComplete(
            exposureTime: settings.exposureTime,
            hfr: result.stats.hfr,
          );
          _feedToLiveStacker(result);
        }
      }
      return result;
    } catch (e) {
      state = state.copyWith(lastError: cleanError(e));
      rethrow;
    } finally {
      previewSubscription.close();
      if (identical(_activeService, imagingService)) _activeService = null;
      state = state.copyWith(
        isSnapshot: false,
        snapshotPreviewReady: false,
        isStopping: false,
      );
      if (sessionNotifier.mounted) sessionNotifier.setCapturing(false);
    }
  }

  /// Loops until [stop]. Completes when the loop has ended.
  ///
  /// Frames are saved only when the Imaging screen's "Save loop frames"
  /// toggle is on, read once at the start so a loop never changes
  /// destination halfway through. [onError] receives each capture failure.
  Future<void> loop({void Function(String error)? onError}) async {
    if (state.isBusy) return;
    state = state.copyWith(
      isLooping: true,
      isStopping: false,
      loopFrames: 0,
      clearError: true,
    );
    final sessionNotifier = ref.read(sessionStateProvider.notifier);
    sessionNotifier.setCapturing(true);

    final settings = ref.read(exposureSettingsProvider);
    final imagingService = ref.read(imagingServiceProvider);
    _activeService = imagingService;
    final saveFrames = ref.read(loopSavesFramesProvider);

    try {
      await imagingService.startLoopCapture(
        settings: settings,
        targetName: ref.read(sessionStateProvider).targetName,
        saveFrames: saveFrames,
        onImageCaptured: (image) {
          if (!identical(_activeService, imagingService)) return;
          ref.read(currentImageProvider.notifier).state = image;
          ref.read(lastImageStatsProvider.notifier).state = image.stats;
          state = state.copyWith(loopFrames: state.loopFrames + 1);
          // Frame count and integration time describe what the session
          // kept; a discarded live-view frame adds nothing.
          if (saveFrames) {
            sessionNotifier.recordExposureComplete(
              exposureTime: settings.exposureTime,
              hfr: image.stats.hfr,
            );
          }
          _feedToLiveStacker(image);
        },
        onError: (error) {
          final cleaned = cleanError(error);
          state = state.copyWith(lastError: cleaned);
          onError?.call(cleaned);
        },
      );
    } finally {
      if (identical(_activeService, imagingService)) _activeService = null;
      state = state.copyWith(isLooping: false, isStopping: false);
      if (sessionNotifier.mounted) sessionNotifier.setCapturing(false);
    }
  }

  /// Aborts the snapshot or loop this controller started. Does nothing for
  /// an exposure it does not own (a sequence frame, centering, first light).
  void stop() {
    final service = _activeService;
    if (service == null || !state.isBusy) return;
    state = state.copyWith(isStopping: true);
    service.cancelExposure();
  }

  /// Feeds a frame to the live stacker when stacking runs. A remote host
  /// feeds its own stacker from the frames it saves, so a viewer never does.
  void _feedToLiveStacker(CapturedImageData image) {
    if (!ref.read(liveStackingIsActiveProvider)) return;
    if (ref.read(isRemoteModeProvider)) return;
    final filePath = image.filePath;
    if (filePath != null && filePath.isNotEmpty) {
      ref.read(liveStackingProvider.notifier).addFrameFromFile(filePath);
    }
  }
}
