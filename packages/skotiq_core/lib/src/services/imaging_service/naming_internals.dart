part of '../imaging_service.dart';

extension _ImagingServiceNamingInternals on ImagingService {
  /// The naming values of a manual frame, with the camera's and mount's
  /// names and the sensor temperature read from the equipment state.
  Map<NamingToken, String> _manualNamingValues({
    required ExposureSettings exposureSettings,
    String? targetName,
    required int frameNumber,
    required DateTime timestamp,
  }) {
    // Only a disposed container is tolerated here (the values fall back to
    // the unnamed-rig defaults and the log says so); any other failure
    // propagates rather than stamping a default onto a file the operator
    // keeps.
    String? camera;
    double? sensorTempC;
    try {
      final cameraState = _ref.read(cameraStateProvider);
      camera = cameraState.deviceName;
      sensorTempC = cameraState.temperature;
    } on StateError catch (e) {
      _logger.warning(
        'Camera state unreadable while naming a frame; '
        '\$CAMERA/\$TEMP fall back to defaults',
        source: 'ImagingService',
        fields: {'error': e.message},
      );
    }

    String? telescope;
    try {
      telescope = _ref.read(mountStateProvider).deviceName;
    } on StateError catch (e) {
      _logger.warning(
        'Mount state unreadable while naming a frame; '
        '\$TELESCOPE falls back to the default',
        source: 'ImagingService',
        fields: {'error': e.message},
      );
    }

    return ImagingService.manualFrameValues(
      exposureSettings: exposureSettings,
      targetName: targetName,
      frameNumber: frameNumber,
      timestamp: timestamp,
      camera: camera,
      telescope: telescope,
      sensorTempC: sensorTempC,
    );
  }
}
