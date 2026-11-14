part of '../imaging_screen.dart';

extension _ImagingScreenActions on _ImagingScreenState {
  /// Initialize the annotation service so it starts listening for new images
  void _initializeAnnotationService() {
    // Reading the provider creates the AnnotationService instance
    // which sets up the listener for currentImageProvider
    ref.read(annotationServiceProvider);
    ref.read(loggingServiceProvider).info(
        '[Imaging] AnnotationService initialized',
        source: 'ImagingScreen');
  }

  Future<void> _takeSnapshot() async {
    if (_isSingleCapture || _isLooping || _isStoppingCapture) return;
    final controller = ref.read(manualCaptureControllerProvider.notifier);
    _startedCapture = controller;
    try {
      await controller.snapshot();
    } catch (e) {
      if (!mounted) return;
      context.showErrorSnackBar('Capture failed: ${userFacingError(e)}');
    } finally {
      if (identical(_startedCapture, controller)) _startedCapture = null;
    }
  }

  /// Loop and Stop. The loop runs on the imaging host whichever window
  /// starts it, so Stop here stops a loop the other window started too.
  Future<void> _toggleLoop() async {
    final controller = ref.read(manualCaptureControllerProvider.notifier);
    final loop = ref.read(manualLoopStatusProvider);
    if (loop.looping) {
      if (!loop.stopping) controller.stop();
      return;
    }
    if (_isSingleCapture || _isStoppingCapture) return;
    _startedCapture = controller;
    try {
      await controller.loop(onError: (error) {
        if (!mounted) return;
        context.showErrorSnackBar('Capture stopped: ${userFacingError(error)}');
      });
    } finally {
      if (identical(_startedCapture, controller)) _startedCapture = null;
    }
  }

  void _abortCapture() {
    // The toolbar shows this button from the global
    // `exposureProgressProvider`, so it also aborts an exposure no manual
    // control started: first light, centering, a sequencer run.
    if (_isLooping || ref.read(manualCaptureControllerProvider).isSnapshot) {
      ref.read(manualCaptureControllerProvider.notifier).stop();
      return;
    }
    ref.read(imagingServiceProvider).cancelExposure();
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
