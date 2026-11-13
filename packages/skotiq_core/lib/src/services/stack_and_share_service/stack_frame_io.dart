part of '../stack_and_share_service.dart';

extension _StackFrameIo on StackAndShareService {
  /// Load [frame]'s raw linear pixels and calibrate them with its matching
  /// dark and the run's master flat / bias in [context].
  ///
  /// The light's exposure / gain / binning / temperature drive the per-frame
  /// dark match; a frame with no matching dark and no master flat / bias is fed
  /// uncalibrated rather than dropped, since the selector already decided it
  /// belongs in the stack.
  Future<_RawFrame> _loadCalibrated(
    StackedFrameSelection frame,
    _CalibrationContext context,
  ) async {
    final raw = await _loadRawU16(frame.filePath);
    _ensureSameHost();

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
      width: raw.width,
      height: raw.height,
      lightData: raw.data,
      darkPath: darkPath,
      flatPath: context.flatPath,
      biasPath: context.biasPath,
    );
    _ensureSameHost();

    return _RawFrame(width: raw.width, height: raw.height, data: calibrated);
  }

  /// The run's shared calibration inputs: the dark-match tolerances and the
  /// Settings master flat / bias, checked to exist once per run.
  _CalibrationContext _buildCalibrationContext() {
    final settings = _ref.read(calibrationSettingsProvider);
    String? existing(String? path, String label) {
      if (path == null || path.isEmpty) return null;
      if (!File(path).existsSync()) {
        throw FileSystemException('Master $label file not found', path);
      }
      return path;
    }

    return _CalibrationContext(
      tolerances: _ref.read(darkLibraryMatchTolerancesProvider),
      flatPath: existing(settings.masterFlatPath, 'flat'),
      biasPath: existing(settings.masterBiasPath, 'bias'),
    );
  }

  /// Read a frame's unstretched linear pixels and quantise to u16.
  ///
  /// Uses the science-grade linear read path so the stacked integration works
  /// on genuine sensor values rather than display-stretched bytes. The native
  /// reader returns samples on the 16-bit ADU scale (BZERO/BSCALE and the
  /// file's declared range applied); they are clamped to `[0, 65535]` (the
  /// engine and calibration pipeline operate on u16), and a NaN sample, which
  /// a float master holds where it rejected every frame, becomes 0.
  Future<_RawFrame> _loadRawU16(String filePath) async {
    final linear = await _engine.readLinearFrame(filePath);
    _ensureSameHost();
    final pixelCount = linear.width * linear.height;
    if (linear.linearData.length != pixelCount) {
      throw StateError(
        'FITS "$filePath" reported ${linear.width}x${linear.height} '
        '($pixelCount px) but returned ${linear.linearData.length} samples.',
      );
    }
    final data = Uint16List(pixelCount);
    for (var i = 0; i < pixelCount; i++) {
      final v = linear.linearData[i];
      if (!(v > 0)) {
        data[i] = 0;
      } else if (v >= 65535) {
        data[i] = 65535;
      } else {
        data[i] = (v + 0.5).floor();
      }
    }
    return _RawFrame(width: linear.width, height: linear.height, data: data);
  }

  /// Discover the reference frame's Bayer pattern, preferring the connected
  /// camera's [CameraCapabilities] (the live path) and falling back to the
  /// reference frame's FITS `BAYERPAT` geometry (the file path). Returns null
  /// when neither source declares a CFA pattern (i.e. a mono sensor / frame).
  Future<String?> _discoverBayerPattern(StackedFrameSelection reference) async {
    // Live path: the connected camera's capabilities. An OSC camera advertises
    // `isColor` plus its `bayerPattern`; a mono camera advertises neither.
    final cameraId = _ref.read(connectedCameraIdProvider);
    if (cameraId != null && cameraId.isNotEmpty) {
      final caps = await _ref.read(cameraCapabilitiesProvider(cameraId).future);
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
