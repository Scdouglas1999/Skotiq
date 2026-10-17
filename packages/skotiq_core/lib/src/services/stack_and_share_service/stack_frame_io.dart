part of '../stack_and_share_service.dart';

extension _StackFrameIo on StackAndShareService {
  /// Load [frame]'s raw linear pixels and apply in-memory calibration
  /// (dark / flat / bias) using [context].
  ///
  /// The light's exposure / gain / binning / temperature drive the per-frame
  /// dark match (the master flat / bias in [context] are shared); a frame with
  /// no matching dark and no master flat / bias is fed uncalibrated rather than
  /// silently dropped — the selector already decided it belongs in the stack.
  Future<_RawFrame> _loadCalibrated(
    StackedFrameSelection frame,
    _CalibrationContext context,
  ) async {
    final raw = await _loadRawU16(frame.filePath);
    _ensureAuthority();

    final meta = await _imagesDao.getImageById(frame.imageId);
    _ensureAuthority();
    Uint16List? darkData;
    if (meta != null && meta.gain != null) {
      final match = await _darkLibrary.findMatchingDark(
        exposureTime: meta.exposureDuration,
        gain: meta.gain!,
        offset: meta.offset ?? 0,
        binX: meta.binX,
        binY: meta.binY,
        temperature: meta.sensorTemp,
        tolerances: context.tolerances,
      );
      _ensureAuthority();
      if (match != null) {
        darkData = await _loadMatchingPixels(match.filePath, raw.pixelCount);
        _ensureAuthority();
      }
    }

    final calibrated = _calibration.calibrateData(
      width: raw.width,
      height: raw.height,
      lightData: raw.data,
      darkData: darkData,
      flatData: _validateDimensions(context.flatData, raw.pixelCount, 'flat'),
      biasData: _validateDimensions(context.biasData, raw.pixelCount, 'bias'),
    );

    return _RawFrame(width: raw.width, height: raw.height, data: calibrated);
  }

  /// Build the shared calibration context (tolerances + master flat / bias
  /// pixels) once per run. The flat / bias are loaded into u16 here so they are
  /// not re-read from disk for every frame.
  Future<_CalibrationContext> _buildCalibrationContext() async {
    final tolerances = _ref.read(darkLibraryMatchTolerancesProvider);
    final settings = _ref.read(calibrationSettingsProvider);

    Uint16List? flatData;
    final flatPath = settings.masterFlatPath;
    if (flatPath != null && flatPath.isNotEmpty) {
      if (!File(flatPath).existsSync()) {
        throw FileSystemException('Master flat file not found', flatPath);
      }
      flatData = await _darkLibrary.loadDarkPixels(flatPath);
      _ensureAuthority();
    }

    Uint16List? biasData;
    final biasPath = settings.masterBiasPath;
    if (biasPath != null && biasPath.isNotEmpty) {
      if (!File(biasPath).existsSync()) {
        throw FileSystemException('Master bias file not found', biasPath);
      }
      biasData = await _darkLibrary.loadDarkPixels(biasPath);
      _ensureAuthority();
    }

    return _CalibrationContext(
      tolerances: tolerances,
      flatData: flatData,
      biasData: biasData,
    );
  }

  /// Load a calibration frame's pixels and assert it matches the light's pixel
  /// count, so a mismatched master (wrong binning / sensor) fails loudly rather
  /// than corrupting the calibration math.
  Future<Uint16List> _loadMatchingPixels(
    String path,
    int expectedPixels,
  ) async {
    final pixels = await _darkLibrary.loadDarkPixels(path);
    _ensureAuthority();
    if (pixels.length != expectedPixels) {
      throw StateError(
        'Calibration frame "$path" has ${pixels.length} pixels but the light '
        'frame has $expectedPixels — they must share dimensions / binning.',
      );
    }
    return pixels;
  }

  /// Guard a pre-loaded master against a per-light pixel-count mismatch.
  /// Returns the master unchanged when it matches, throws when it does not, and
  /// passes null through (the correction is simply skipped).
  Uint16List? _validateDimensions(
    Uint16List? master,
    int expectedPixels,
    String label,
  ) {
    if (master == null) return null;
    if (master.length != expectedPixels) {
      throw StateError(
        'Master $label has ${master.length} pixels but the light frame has '
        '$expectedPixels — they must share dimensions / binning.',
      );
    }
    return master;
  }

  /// Read a frame's unstretched linear pixels and quantise to u16.
  ///
  /// Uses the science-grade linear read path so the stacked integration works
  /// on genuine sensor values rather than display-stretched bytes. Linear
  /// values are clamped to `[0, 65535]` (the engine and calibration pipeline
  /// operate on u16); the FITS reader in Rust has already applied BZERO/BSCALE.
  Future<_RawFrame> _loadRawU16(String filePath) async {
    final linear = await _engine.readLinearFrame(filePath);
    _ensureAuthority();
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
      if (v <= 0) {
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
      _ensureAuthority();
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
    _ensureAuthority();
    final framePattern = linear.bayerPattern?.trim();
    if (framePattern != null && framePattern.isNotEmpty) {
      return framePattern;
    }
    return null;
  }
}
