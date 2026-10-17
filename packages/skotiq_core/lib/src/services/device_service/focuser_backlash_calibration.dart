part of '../device_service.dart';

/// Driving a focuser backlash measurement: two focus scans, one approaching
/// every point from below and one from above, differenced to give the dead
/// band.
///
/// It shares the camera and focuser with autofocus, so it takes the same
/// admission gate — native enforces that too, but refusing here gives the
/// operator the reason rather than a driver-level conflict.
extension _DeviceServiceFocuserBacklashCalibration on DeviceService {
  Future<FocuserBacklashResult> _calibrateFocuserBacklash({
    int? centerPosition,
  }) async {
    final ids = _admitFocuserBacklashCalibration();
    _isFocuserBacklashCalibrationRunning = true;
    final focuserNotifier = _ref.read(focuserStateProvider.notifier);
    focuserNotifier.setMoving(true);
    try {
      final outcomeJson = await _backend.focuserBacklashCalibrationStart(
        deviceId: ids.focuserId,
        cameraId: ids.cameraId,
        configJson: focuserBacklashCalibrationConfigJson(
          centerPosition: centerPosition,
          appVersion: _appVersionForCalibrationRecord(),
        ),
      );
      final result = FocuserBacklashResult.tryParse(outcomeJson);
      if (result == null) {
        // The run may well have moved the focuser; what it concluded is simply
        // unreadable. Saying so beats presenting a half-parsed figure.
        throw StateError(
          'The backlash calibration finished but its result could not be read',
        );
      }
      return result;
    } finally {
      _isFocuserBacklashCalibrationRunning = false;
      focuserNotifier.setMoving(false);
    }
  }

  Future<void> _cancelFocuserBacklashCalibration() =>
      _backend.focuserBacklashCalibrationCancel();

  /// What a run would cost from [centerPosition], or from where the focuser is
  /// standing when that is null.
  ///
  /// Refuses rather than guessing a centre: the plan states the exact travel
  /// the focuser will be commanded through, and a plan centred somewhere the
  /// focuser is not would state the wrong range.
  Future<FocuserBacklashCalibrationPlan> _planFocuserBacklashCalibration({
    int? centerPosition,
  }) async {
    final centre = centerPosition ?? _ref.read(focuserStateProvider).position;
    if (centre == null) {
      throw StateError(
        'The focuser does not report its position, so the calibration range '
        'cannot be worked out. Connect the focuser first.',
      );
    }
    final planJson = await _backend.focuserBacklashCalibrationPlan(
      configJson: focuserBacklashCalibrationConfigJson(
        centerPosition: centerPosition,
        appVersion: _appVersionForCalibrationRecord(),
      ),
      centerPosition: centre,
    );
    final plan = FocuserBacklashCalibrationPlan.tryParse(planJson);
    if (plan == null) {
      throw StateError('The backlash calibration plan could not be read');
    }
    return plan;
  }

  /// The camera and focuser to drive, or an exception naming what is missing.
  _FocuserBacklashCalibrationDevices _admitFocuserBacklashCalibration() {
    if (_isFocuserBacklashCalibrationRunning) {
      throw StateError(
        'A focuser backlash calibration is already running. Wait for it to '
        'finish or cancel it.',
      );
    }
    if (_isAutofocusRunning) {
      throw StateError(
        'Autofocus is running. Backlash calibration drives the same camera '
        'and focuser, so it cannot start until autofocus finishes.',
      );
    }
    if (_isFocuserMoveRunning || _ref.read(focuserStateProvider).isMoving) {
      throw StateError(
        'Cannot measure backlash while the focuser is already moving.',
      );
    }
    final focuser = _ref.read(focuserStateProvider);
    final camera = _ref.read(cameraStateProvider);
    if (focuser.connectionState != DeviceConnectionState.connected ||
        focuser.deviceId == null ||
        focuser.deviceId!.isEmpty) {
      throw StateError('No focuser connected');
    }
    if (camera.connectionState != DeviceConnectionState.connected ||
        camera.deviceId == null ||
        camera.deviceId!.isEmpty) {
      throw StateError(
        'No camera connected. Measuring backlash means measuring star sizes, '
        'so it needs the imaging camera.',
      );
    }
    return _FocuserBacklashCalibrationDevices(
      focuserId: focuser.deviceId!,
      cameraId: camera.deviceId!,
    );
  }
}

/// The two device ids a calibration run needs, resolved together so a run
/// cannot start with one of them missing.
class _FocuserBacklashCalibrationDevices {
  const _FocuserBacklashCalibrationDevices({
    required this.focuserId,
    required this.cameraId,
  });

  final String focuserId;
  final String cameraId;
}
