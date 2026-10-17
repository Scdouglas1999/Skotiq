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

  /// Resolve the concrete readout-mode index to send to the camera for
  /// [settings], using the camera's actual reported readout-mode count.
  ///
  /// Returns `null` when the camera exposes no readout modes (the driver
  /// doesn't report any, or the capability query failed). A null result means
  /// "don't issue a `cameraSetReadoutMode` call at all" — there's nothing to
  /// select against, and forcing index 0 could pick a different mode than the
  /// driver's own default. This mirrors the camera panel, which hides the
  /// read-mode dropdown entirely when `readoutModes` is empty.
  ///
  /// When the mode count is known, [ExposureSettings.resolveReadoutModeIndex]
  /// maps the user's explicit choice (or the legacy `fastReadout` flag) to a
  /// real index. A stale persisted index is rejected: silently clamping it can
  /// select an unrelated mode after a camera/driver/profile change.
  Future<int?> _resolveReadoutModeIndex(
    String deviceId,
    ExposureSettings settings,
  ) async {
    final int modeCount = await _readoutModeCount(deviceId);
    if (modeCount <= 0) {
      return null;
    }
    final resolved = settings.resolveReadoutModeIndex(modeCount);
    if (resolved < 0 || resolved >= modeCount) {
      throw ValidationException(
        message:
            'Readout mode index $resolved is unavailable on camera $deviceId '
            '(reported modes: $modeCount)',
        userMessage:
            'The saved readout mode is no longer available. Select a readout '
            'mode for this camera and try again.',
      );
    }
    return resolved;
  }

  /// The number of readout modes the camera [deviceId] reports, or 0 when
  /// unknown. Reads the cached/awaited [equipmentCameraCapabilitiesProvider]
  /// for the device.
  ///
  /// A null capability result yields 0 (treated as "unsupported/unknown" by the
  /// caller). Query failures propagate so authentication, transport, and driver
  /// faults cannot silently skip an explicitly requested capture setting.
  Future<int> _readoutModeCount(String deviceId) async {
    if (deviceId.isEmpty) {
      return 0;
    }
    final caps = await _ref.read(
      equipmentCameraCapabilitiesProvider(deviceId).future,
    );
    return caps?.readoutModes.length ?? 0;
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
