part of '../imaging_service.dart';

extension _ImagingServiceFilePaths on ImagingService {
  /// Generate file path for captured image.
  ///
  /// The user's [NamingPattern.pattern] is interpreted as a `/`-separated
  /// path *including the filename*: every segment before the final `/` is a
  /// subdirectory, and the final segment is the filename stem (the extension
  /// is appended from [NamingPattern.format]). The default pattern
  /// `$TARGET/$FRAMETYPE/$TARGET_$FILTER_$EXPTIME_$FRAMENUM` therefore yields
  /// e.g. `M31/Light/M31_L_120.0_0001.fits` under the configured base
  /// directory. This matches the convention implemented by the Rust
  /// `FilenameGenerator` in `native/skotiq_native/imaging/src/naming.rs`.
  ///
  /// All `$VARIABLE` tokens are validated against [_patternVariables]; an
  /// unknown token raises an [Exception] rather than leaving `$BANANA` in the
  /// filename, where a typo in the operator's pattern would go unnoticed.
  ///
  /// Date/time substitutions (`$DATE`, `$TIME`, `$DATETIME`) use **UTC** so
  /// the path matches the FITS `DATE-OBS` keyword written by the Rust
  /// `FitsHeader::captureTimestamp` path (which also uses UTC). A 19:00 PST
  /// frame is grouped under the UTC date 03:00 the next morning — i.e. the
  /// folder name matches the timestamp embedded in the file.
  Future<String> _generateImageFilePath({
    required AppSettingsState appSettings,
    required ExposureSettings exposureSettings,
    String? targetName,
    required int frameNumber,
    required DateTime timestamp,
  }) async {
    final basePath = appSettings.imageOutputPath;
    if (basePath.isEmpty) {
      throw const ValidationException(
        message: 'Image output path not configured',
        userMessage: 'No image output path is configured',
      );
    }

    // Get naming pattern from imaging provider
    final namingPattern = _ref.read(namingPatternProvider);

    final substitutions = _buildPatternSubstitutions(
      exposureSettings: exposureSettings,
      targetName: targetName,
      frameNumber: frameNumber,
      timestamp: timestamp,
    );

    final fullPath = ImagingService.buildImageFilePath(
      pattern: namingPattern.pattern,
      basePath: basePath,
      extension: namingPattern.format.extension,
      substitutions: substitutions,
    );

    // Create directory if needed
    final directory = Directory(path.dirname(fullPath));
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    return _ensureUniqueFilePath(fullPath);
  }

  /// The `$SEQ`/`$FRAMENUM` value to stamp on the next KEEPER, given that
  /// [ImagingService._frameNumber] counts only this service instance's frames.
  ///
  /// `imagingServiceProvider` watches `backendProvider`, so the service — and
  /// with it the counter — is rebuilt on every app start and on every host
  /// switch or reconnect. The counter therefore returned to 0 several times a
  /// night while the shipped pattern `$TARGET_$FILTER_$DATE_$SEQ` still
  /// resolved to the same folder and the same UTC date: the next Snapshot
  /// asked for `0001` with `0001` already on disk. [_ensureUniqueFilePath] kept
  /// the data safe by appending `_001`, but the operator was left with two
  /// files whose sequence number both read 0001 and a suffix no pattern asked
  /// for — which sorts wrong in every stacker.
  ///
  /// Probing the folder rather than remembering a high-water mark is also what
  /// makes the number restart correctly: tomorrow's `$DATE` renders a path that
  /// does not exist yet, so tomorrow's first frame is 0001 again.
  ///
  /// Never throws. An unusable naming pattern must fail the capture at save
  /// time, where the operator gets the real message, and a folder that cannot
  /// be probed simply falls back to the in-memory counter.
  Future<int> _nextKeeperFrameNumber({
    required ExposureSettings exposureSettings,
    String? targetName,
  }) async {
    final fallback = _frameNumber + 1;
    try {
      final basePath = _ref
          .read(appSettingsProvider)
          .valueOrNull
          ?.imageOutputPath;
      if (basePath == null || basePath.isEmpty) return fallback;

      final namingPattern = _ref.read(namingPatternProvider);
      // `nowUtc()`, not `now().toUtc()`: the latter re-converts an already
      // zone-shifted rendering and lands offset+hostOffset away, so the
      // `$DATETIME` a probe renders would not match the one the real save
      // renders and the keeper-number probe would look at the wrong files.
      final timestamp = _ref.read(clockProvider).nowUtc();
      String renderFor(int frameNumber) => ImagingService.buildImageFilePath(
        pattern: namingPattern.pattern,
        basePath: basePath,
        extension: namingPattern.format.extension,
        substitutions: _buildPatternSubstitutions(
          exposureSettings: exposureSettings,
          targetName: targetName,
          frameNumber: frameNumber,
          timestamp: timestamp,
        ),
      );

      // A pattern that renders no frame number (e.g. `$TARGET_$DATETIME`)
      // gives the same path for every candidate: probing it would never
      // terminate, and there uniqueness is _ensureUniqueFilePath's job.
      if (renderFor(fallback) == renderFor(fallback + 1)) return fallback;

      var candidate = fallback;
      final ceiling = fallback + ImagingService._keeperProbeLimit;
      while (candidate < ceiling && await File(renderFor(candidate)).exists()) {
        candidate++;
      }
      return candidate;
    } catch (e) {
      _logger.warning(
        'Could not check which frame numbers are already on disk ($e) — '
        'numbering continues from $fallback',
        source: 'ImagingService',
      );
      return fallback;
    }
  }

  Future<String> _ensureUniqueFilePath(String desiredPath) async {
    var candidate = desiredPath;
    var suffix = 1;

    while (await File(candidate).exists()) {
      final directory = path.dirname(desiredPath);
      final baseName = path.basenameWithoutExtension(desiredPath);
      final extension = path.extension(desiredPath);
      candidate = path.join(
        directory,
        '${baseName}_${suffix.toString().padLeft(3, '0')}$extension',
      );
      suffix++;
    }

    return candidate;
  }

  /// Save FITS file via Rust backend
  ///
  /// Uses the optimized saveFitsFromLastCapture API which reads raw image data
  /// directly from Rust-side storage, avoiding expensive FFI data transfers.
}
