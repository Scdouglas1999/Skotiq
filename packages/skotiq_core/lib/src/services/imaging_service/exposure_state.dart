part of '../imaging_service.dart';

extension _ImagingServiceExposureState on ImagingService {
  ExposureSettings _withLiveFilter(ExposureSettings settings) {
    final FilterWheelState wheel;
    try {
      wheel = _ref.read(filterWheelStateProvider);
    } catch (_) {
      // Provider unavailable (minimal test container) — keep the caller's value.
      return settings;
    }
    if (wheel.connectionState != DeviceConnectionState.connected) {
      return settings;
    }
    final name = wheel.currentFilterName;
    if (name == null || name.isEmpty) return settings;
    if (settings.filter == name) return settings;
    return settings.copyWith(filter: name);
  }

  /// Take back the "an exposure is running" claim this capture made.
  ///
  /// `cameraStateProvider.isExposing` and `exposureProgressProvider` are NOT
  /// per-backend. [_ownsSharedExposureState] releases them exactly once from
  /// the capture that armed them, including after a backend switch.
  void _releaseSharedExposureState() {
    if (!_ownsSharedExposureState) return;
    _ownsSharedExposureState = false;
    final cameraNotifier = _activeCameraNotifier;
    final progressNotifier = _activeProgressNotifier;
    _activeCameraNotifier = null;
    _activeProgressNotifier = null;
    // `mounted` is false when the whole container is going down (app shutdown,
    // test teardown) — there is no graph left to correct.
    if (cameraNotifier != null && cameraNotifier.mounted) {
      cameraNotifier.setExposing(false);
    }
    if (progressNotifier != null && progressNotifier.mounted) {
      progressNotifier.reset();
    }
  }

  Future<void> _abortActiveExposure() {
    final existing = _activeAbortFuture;
    if (existing != null) return existing;

    final backend = _activeCaptureBackend;
    final deviceId = _activeCaptureDeviceId;
    if (backend == null || deviceId == null) return Future<void>.value();

    final operation = Future<void>.sync(
      () => backend.cameraAbortExposure(deviceId),
    );
    _activeAbortFuture = operation;
    return operation;
  }
}
