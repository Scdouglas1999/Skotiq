part of '../imaging_screen.dart';

extension _ImagingScreenActions on _ImagingScreenState {
  /// Strips a leading `SomeException(category): ` prefix so capture failures
  /// read as English for the operator.
  ///
  /// A raw `$error` interpolation puts the Dart class name in front of the
  /// operator ("Capture error: SkotiqException(connection): Camera not
  /// connected"). Matched on `toString()` rather than the exception type
  /// because `SkotiqException` is intentionally NOT exported from the
  /// `skotiq_core` barrel, so this layer cannot type-check it without
  /// widening that surface. The full object still reaches the log untouched.
  static final RegExp _exceptionPrefix =
      RegExp(r'^[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?:\s*');

  String _captureErrorText(Object error) {
    final raw = error.toString().trim();
    final stripped = raw.replaceFirst(_exceptionPrefix, '').trim();
    return stripped.isEmpty ? raw : stripped;
  }

  /// Initialize the annotation service so it starts listening for new images
  void _initializeAnnotationService() {
    // Reading the provider creates the AnnotationService instance
    // which sets up the listener for currentImageProvider
    ref.read(annotationServiceProvider);
    ref.read(loggingServiceProvider).info(
        '[Imaging] AnnotationService initialized',
        source: 'ImagingScreen');
  }

  // CAPTURE ACTIONS

  Future<void> _takeSnapshot() async {
    if (_isSingleCapture || _isLooping || _isStoppingCapture) return;

    _update(() {
      _isSingleCapture = true;
      _singleCapturePreviewReady = false;
      _isStoppingCapture = false;
    });

    final settings = ref.read(exposureSettingsProvider);
    final imagingService = ref.read(imagingServiceProvider);
    _manualCaptureService = imagingService;
    final sessionNotifier = ref.read(sessionStateProvider.notifier);

    sessionNotifier.setCapturing(true);

    // Pixels arrive before FITS persistence and optional calibration finish.
    // Keep the action disabled through that pipeline, but change its label to
    // "Saving…" so the visible preview is not mistaken for a finished frame.
    //
    // We baseline against the `capturedAt` of whatever was on screen
    // when the snapshot started so an idle, never-changing image (or a
    // stale frame from a previous session) doesn't immediately trip
    // the reset.
    final baselineCapturedAt = ref.read(currentImageProvider)?.capturedAt;
    var previewSeen = false;
    final previewSubscription = ref.listenManual<CapturedImageData?>(
      currentImageProvider,
      (previous, next) {
        if (previewSeen) return;
        if (next == null) return;
        if (next.capturedAt == baselineCapturedAt) return;
        previewSeen = true;
        if (!mounted) return;
        _update(() => _singleCapturePreviewReady = true);
      },
      // We don't care about the initial value, only future writes.
      fireImmediately: false,
    );

    try {
      final result = await imagingService.captureImage(
        settings: settings,
        targetName: ref.read(sessionStateProvider).targetName,
      );

      if (result != null) {
        ref.read(currentImageProvider.notifier).state = result;
        ref.read(lastImageStatsProvider.notifier).state = result.stats;
        sessionNotifier.recordExposureComplete(
          exposureTime: settings.exposureTime,
          hfr: result.stats.hfr,
        );
        _feedToLiveStacker(result);
      }
    } catch (e) {
      if (!mounted) return;
      context.showErrorSnackBar('Capture failed: ${_captureErrorText(e)}');
    } finally {
      previewSubscription.close();
      if (mounted) {
        _update(() {
          _isSingleCapture = false;
          _singleCapturePreviewReady = false;
          _isStoppingCapture = false;
        });
      }
      if (identical(_manualCaptureService, imagingService)) {
        _manualCaptureService = null;
      }
      if (sessionNotifier.mounted) sessionNotifier.setCapturing(false);
    }
  }

  Future<void> _toggleLoop() async {
    if (_isSingleCapture || _isStoppingCapture) return;

    if (_isLooping) {
      // Stop looping
      _update(() => _isStoppingCapture = true);
      ref.read(imagingServiceProvider).cancelExposure();
      return;
    }

    _update(() {
      _isLooping = true;
      _isStoppingCapture = false;
    });
    final sessionNotifier = ref.read(sessionStateProvider.notifier);
    sessionNotifier.setCapturing(true);

    final settings = ref.read(exposureSettingsProvider);
    final imagingService = ref.read(imagingServiceProvider);
    _manualCaptureService = imagingService;
    // Read once, at the start of the run: the banner locks the toggle while a
    // loop is live, and a run must not change destination halfway through.
    final saveFrames = ref.read(loopSavesFramesProvider);

    try {
      await imagingService.startLoopCapture(
          settings: settings,
          targetName: ref.read(sessionStateProvider).targetName,
          saveFrames: saveFrames,
          onImageCaptured: (image) {
            if (mounted) {
              ref.read(currentImageProvider.notifier).state = image;
              ref.read(lastImageStatsProvider.notifier).state = image.stats;
              // Frame count and integration time describe what the session
              // KEPT. A discarded live-view frame that still incremented them
              // made the session panel claim integration the operator does not
              // have on disk.
              // Frame count and integration time describe what the session
              // KEPT. A discarded live-view frame that still incremented them
              // made the session panel claim integration the operator does not
              // have on disk.
              if (saveFrames) {
                ref.read(sessionStateProvider.notifier).recordExposureComplete(
                      exposureTime: settings.exposureTime,
                      hfr: image.stats.hfr,
                    );
              }
              _feedToLiveStacker(image);
            }
          },
          onError: (error) {
            if (!mounted) return;
            context.showErrorSnackBar(
                'Capture stopped: ${_captureErrorText(error)}');
          });
    } finally {
      if (mounted) {
        _update(() {
          _isLooping = false;
          _isStoppingCapture = false;
        });
      }
      if (identical(_manualCaptureService, imagingService)) {
        _manualCaptureService = null;
      }
      if (sessionNotifier.mounted) sessionNotifier.setCapturing(false);
    }
  }

  void _abortCapture() {
    // Abort targets the shared imaging service, NOT this screen's own capture
    // flags. The toolbar decides to SHOW this button from the global
    // `exposureProgressProvider` (imaging_preview_toolbar's `showAbort`), so
    // gating the action on `_isSingleCapture || _isLooping` left it offered and
    // dead for every exposure this screen did not itself start — first light,
    // centering, a sequencer run — while the countdown ran on.
    ref.read(imagingServiceProvider).cancelExposure();
    // The "stopping" latch is cleared in the capture methods' `finally`, which
    // only runs for a capture this screen owns. Latching it for a foreign
    // exposure would hide the abort button for the rest of the session.
    if (_isSingleCapture || _isLooping) {
      _update(() => _isStoppingCapture = true);
    }
  }

  /// Feed a newly captured frame to the live stacker if stacking is active.
  ///
  /// Uses the saved file path when available (preferred, avoids sending raw
  /// pixel data over FFI twice). Silently skips when stacking is not running.
  void _feedToLiveStacker(CapturedImageData image) {
    final isActive = ref.read(liveStackingIsActiveProvider);
    if (!isActive) return;

    // Remote mode: the appliance auto-feeds every frame it saves into its own
    // stacker (server-side, on the ImageSaved event). Feeding again from here
    // would either double-count the frame or hand the host a tablet-local path
    // it cannot read — so leave feeding to the host.
    if (ref.read(isRemoteModeProvider)) return;

    final filePath = image.filePath;
    if (filePath != null && filePath.isNotEmpty) {
      // Fire-and-forget: the notifier logs warnings on rejection
      ref.read(liveStackingProvider.notifier).addFrameFromFile(filePath);
    }
  }

  // Zoom/pan controls — delegate to imagingViewerStateProvider so window
  // navigation and rebuilds don't reset the user's view.

  ImagingViewerStateNotifier get _viewer =>
      ref.read(imagingViewerStateProvider.notifier);

  /// Screen px per image px at zoom 1.0, measured by the preview itself. The
  /// zoom bounds and 1:1 are absolute intents, so they cannot be expressed in
  /// the fit-relative multiplier the state stores without it.
  double get _previewFitScale => ref.read(previewFitScaleProvider);

  void _zoomIn() => _viewer.zoomIn(fitScale: _previewFitScale);
  void _zoomOut() => _viewer.zoomOut(fitScale: _previewFitScale);
  void _fitToWindow() => _viewer.fitToWindow();
  void _zoom1to1() => _viewer.zoom1to1(fitScale: _previewFitScale);
  void _panPreview(Offset delta) => _viewer.pan(delta);
}
