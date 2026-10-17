part of '../imaging_service.dart';

extension _ImagingServiceNamingInternals on ImagingService {
  /// Build the substitution map used by [expandNamingPattern]. Pulled out of
  /// [_generateImageFilePath] so the provider-bound pieces (camera/mount
  /// name, sensor temperature) are read in one place. Delegates the pure
  /// timestamp/exposure formatting to [buildTimestampSubstitutions] so unit
  /// tests can exercise the date convention without a `ProviderContainer`.
  Map<String, String> _buildPatternSubstitutions({
    required ExposureSettings exposureSettings,
    String? targetName,
    required int frameNumber,
    required DateTime timestamp,
  }) {
    // $TEMP, $CAMERA, $TELESCOPE fall back to the same defaults as the Rust
    // naming.rs when equipment reports no name or temperature, so both
    // languages produce the same path string for an unnamed rig. A provider
    // read that fails is a different thing: only a disposed container is
    // tolerated (the substitution degrades and says so in the log); any other
    // failure propagates rather than silently stamping 'Camera'/'Telescope'
    // onto the file the operator will keep.
    String camera = 'Camera';
    String tempStr = '0C';
    try {
      final cameraState = _ref.read(cameraStateProvider);
      if (cameraState.deviceName != null &&
          cameraState.deviceName!.isNotEmpty) {
        camera = cameraState.deviceName!;
      }
      final temp = cameraState.temperature;
      if (temp != null) {
        tempStr = '${temp.toStringAsFixed(0)}C';
      }
    } on StateError catch (e) {
      _logger.warning(
        'Camera state unreadable while naming a frame; '
        '\$CAMERA/\$TEMP fall back to defaults',
        source: 'ImagingService',
        fields: {'error': e.message},
      );
    }

    String telescope = 'Telescope';
    try {
      final mountState = _ref.read(mountStateProvider);
      if (mountState.deviceName != null && mountState.deviceName!.isNotEmpty) {
        telescope = mountState.deviceName!;
      }
    } on StateError catch (e) {
      _logger.warning(
        'Mount state unreadable while naming a frame; '
        '\$TELESCOPE falls back to the default',
        source: 'ImagingService',
        fields: {'error': e.message},
      );
    }

    return ImagingService.buildTimestampSubstitutions(
      exposureSettings: exposureSettings,
      targetName: targetName,
      frameNumber: frameNumber,
      timestamp: timestamp,
      camera: camera,
      telescope: telescope,
      tempStr: tempStr,
    );
  }
}
