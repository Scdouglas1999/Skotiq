part of '../stack_and_share_service.dart';

extension _StackFrameIo on StackAndShareService {
  /// [frame]'s pixels calibrated with its matching dark and the run's master
  /// flat / bias in [context], by the one light-calibration rule: a frame
  /// whose header says it is calibrated is used as it is.
  ///
  /// The light's exposure / gain / binning / temperature drive the per-frame
  /// dark match; a frame with no matching dark and no master flat / bias is fed
  /// uncalibrated rather than dropped, since the selector already decided it
  /// belongs in the stack.
  Future<_RawFrame> _loadCalibrated(
    StackedFrameSelection frame,
    _CalibrationContext context,
  ) async {
    final meta = await _imagesDao.getImageById(frame.imageId);
    _ensureSameHost();
    String? darkPath;
    if (meta != null) {
      final match = await _darkLibrary.findMatchingDark(
        exposureTime: meta.exposureDuration,
        gain: meta.gain,
        offset: meta.offset,
        binX: meta.binX,
        binY: meta.binY,
        temperature: meta.sensorTemp,
        tolerances: context.tolerances,
      );
      _ensureSameHost();
      darkPath = match?.calibrationPath;
    }

    final calibrated = await _calibration.calibrateData(
      lightPath: frame.filePath,
      darkPath: darkPath,
      flatPath: context.flatPath,
      biasPath: context.biasPath,
    );
    _ensureSameHost();

    return _RawFrame(
      width: calibrated.width,
      height: calibrated.height,
      data: calibrated.data,
      pedestal: calibrated.pedestal,
    );
  }

  /// The run's shared calibration inputs: the dark-match tolerances and the
  /// Settings master flat / bias, checked to exist once per run.
  _CalibrationContext _buildCalibrationContext() {
    final settings = _calibrationSettings();
    String? existing(String? path, String label) {
      if (path == null || path.isEmpty) return null;
      if (!File(path).existsSync()) {
        throw FileSystemException('Master $label file not found', path);
      }
      return path;
    }

    return _CalibrationContext(
      tolerances: _darkMatchTolerances(),
      flatPath: existing(settings.masterFlatPath, 'flat'),
      biasPath: existing(settings.masterBiasPath, 'bias'),
    );
  }

  /// Discover the reference frame's Bayer pattern, preferring the connected
  /// camera's [CameraCapabilities] (the live path) and falling back to the
  /// reference frame's FITS `BAYERPAT` geometry (the file path). Returns null
  /// when neither source declares a CFA pattern (i.e. a mono sensor / frame).
  Future<String?> _discoverBayerPattern(StackedFrameSelection reference) async {
    // Live path: the connected camera's capabilities. An OSC camera advertises
    // `isColor` plus its `bayerPattern`; a mono camera advertises neither.
    final cameraId = _connectedCameraId();
    if (cameraId != null && cameraId.isNotEmpty) {
      final caps = await _cameraCapabilities(cameraId);
      _ensureSameHost();
      final pattern = caps?.bayerPattern?.trim();
      if (caps != null &&
          caps.isColor &&
          pattern != null &&
          pattern.isNotEmpty) {
        return pattern;
      }
    }

    // File path: the reference frame's FITS BAYERPAT geometry (null for mono).
    final linear = await _engine.readLinearFrame(reference.filePath);
    _ensureSameHost();
    final framePattern = linear.bayerPattern?.trim();
    if (framePattern != null && framePattern.isNotEmpty) {
      return framePattern;
    }
    return null;
  }
}
