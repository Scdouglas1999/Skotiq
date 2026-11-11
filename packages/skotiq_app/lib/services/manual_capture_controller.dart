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

/// Snapshot and Loop for Tonight and the Imaging screen.
///
/// The Loop always runs on the imaging host. On the host this controller
/// runs it and publishes its progress in [manualLoopStatusProvider], which
/// the `manualLoop` runtime channel carries to linked clients. On a client,
/// [loop] and [stop] are commands to the host and the loop fields of the
/// state follow the host's. Every window therefore shows the same loop,
/// with Stop, whichever window started it. A snapshot runs where it was
/// pressed.
final manualCaptureControllerProvider =
    NotifierProvider<ManualCaptureController, ManualCaptureState>(
  ManualCaptureController.new,
);

class ManualCaptureController extends Notifier<ManualCaptureState> {
  /// The service that owns the capture in flight, so Stop aborts that one
  /// even after a backend switch rebuilt [imagingServiceProvider].
  ImagingService? _activeService;

  /// Set while a loop this client asked the host for is starting, so the
  /// host's first "not looping" is not read as its end.
  Completer<void>? _remoteLoopEnded;
  bool _remoteLoopSeen = false;

  bool get _remote => ref.read(backendProvider).remoteHost != null;

  @override
  ManualCaptureState build() {
    // Host: the loop fields of this state are what the clients are told.
    listenSelf((_, next) {
      if (_remote) return;
      final status = ref.read(manualLoopStatusProvider.notifier);
      final published = status.state.copyWith(
        looping: next.isLooping,
        stopping: next.isLooping && next.isStopping,
        frames: next.loopFrames,
      );
      if (status.state != published) status.state = published;
    });
    // Client: the loop is the host's.
    ref.listen<ManualLoopStatus>(manualLoopStatusProvider, (previous, next) {
      if (!_remote) return;
      state = state.copyWith(
        isLooping: next.looping,
        isStopping: next.looping
            ? next.stopping
            : (state.isSnapshot ? state.isStopping : false),
        loopFrames: next.frames,
      );
      if (next.looping) _remoteLoopSeen = true;
      final ended = _remoteLoopEnded;
      if (ended != null && _remoteLoopSeen && !next.looping) {
        _remoteLoopEnded = null;
        if (!ended.isCompleted) ended.complete();
      }
    });
    // A client that opens after the host's loop started shows it, with Stop.
    if (_remote) {
      final host = ref.read(manualLoopStatusProvider);
      return ManualCaptureState(
        isLooping: host.looping,
        isStopping: host.looping && host.stopping,
        loopFrames: host.frames,
      );
    }
    return const ManualCaptureState();
  }

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
      state = state.copyWith(lastError: userFacingError(e));
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
  ///
  /// [settings], [saveFrames] and [targetName] default to this window's
  /// capture bar; a client's request to the host passes its own.
  Future<void> loop({
    void Function(String error)? onError,
    ExposureSettings? settings,
    bool? saveFrames,
    String? targetName,
  }) async {
    if (state.isBusy) return;
    if (_remote) return _loopOnHost(onError: onError);
    state = state.copyWith(
      isLooping: true,
      isStopping: false,
      loopFrames: 0,
      clearError: true,
    );
    ref.read(manualLoopStatusProvider.notifier).state =
        const ManualLoopStatus(looping: true);
    final sessionNotifier = ref.read(sessionStateProvider.notifier);
    sessionNotifier.setCapturing(true);

    final ExposureSettings loopSettings =
        settings ?? ref.read(exposureSettingsProvider);
    final imagingService = ref.read(imagingServiceProvider);
    _activeService = imagingService;
    final bool keepFrames = saveFrames ?? ref.read(loopSavesFramesProvider);

    try {
      await imagingService.startLoopCapture(
        settings: loopSettings,
        targetName: targetName ?? ref.read(sessionStateProvider).targetName,
        saveFrames: keepFrames,
        onImageCaptured: (image) {
          if (!identical(_activeService, imagingService)) return;
          ref.read(currentImageProvider.notifier).state = image;
          ref.read(lastImageStatsProvider.notifier).state = image.stats;
          state = state.copyWith(loopFrames: state.loopFrames + 1);
          // Frame count and integration time describe what the session
          // kept; a discarded live-view frame adds nothing.
          if (keepFrames) {
            sessionNotifier.recordExposureComplete(
              exposureTime: loopSettings.exposureTime,
              hfr: image.stats.hfr,
            );
          }
          _feedToLiveStacker(image);
        },
        onError: (error) {
          final cleaned = userFacingError(error);
          state = state.copyWith(lastError: cleaned);
          final status = ref.read(manualLoopStatusProvider.notifier);
          status.state = status.state.copyWith(
            lastError: cleaned,
            errorCount: status.state.errorCount + 1,
          );
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
  ///
  /// On a client, Stop during the host's loop asks the host to stop it,
  /// whichever window started it.
  void stop() {
    final hostNight = ref.read(backendProvider).remoteHost?.night;
    if (hostNight != null && state.isLooping) {
      unawaited(
        hostNight.stopHostManualLoop().catchError((Object e) {
          state = state.copyWith(lastError: userFacingError(e));
        }),
      );
      return;
    }
    final service = _activeService;
    if (service == null || !state.isBusy) return;
    state = state.copyWith(isStopping: true);
    service.cancelExposure();
  }

  /// A client's Loop: the host runs it. Completes when the host's loop ends,
  /// or at once when the host refused or never started it.
  Future<void> _loopOnHost({void Function(String error)? onError}) async {
    final hostNight = ref.read(backendProvider).remoteHost?.night;
    if (hostNight == null) return;
    final ended = _remoteLoopEnded = Completer<void>();
    _remoteLoopSeen = ref.read(manualLoopStatusProvider).looping;
    final errors = ref.listen<ManualLoopStatus>(manualLoopStatusProvider, (
      previous,
      next,
    ) {
      final error = next.lastError;
      if (error != null && next.errorCount != previous?.errorCount) {
        onError?.call(error);
      }
    });
    try {
      await hostNight.startHostManualLoop(
        manualLoopRequestJson(
          settings: ref.read(exposureSettingsProvider),
          saveFrames: ref.read(loopSavesFramesProvider),
          targetName: ref.read(sessionStateProvider).targetName,
        ),
      );
      // The host answers before its first status reaches this window; a
      // status that never says "looping" means the loop ended before it was
      // seen, which the timeout covers.
      await ended.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () async {
          if (_remoteLoopSeen) return ended.future;
        },
      );
    } catch (e) {
      final cleaned = userFacingError(e);
      state = state.copyWith(lastError: cleaned);
      onError?.call(cleaned);
    } finally {
      errors.close();
      if (identical(_remoteLoopEnded, ended)) _remoteLoopEnded = null;
    }
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
