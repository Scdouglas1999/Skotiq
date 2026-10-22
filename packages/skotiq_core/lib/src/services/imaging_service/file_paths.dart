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

    final backend = _ref.read(backendProvider);
    if (backend is NetworkBackend) {
      // The host writes the keeper and creates its folder, so the path is
      // built in the host's style and only the host can say what is taken.
      final hostPaths = hostPathContext(basePath);
      final fullPath = ImagingService.buildImageFilePath(
        pattern: namingPattern.pattern,
        basePath: basePath,
        extension: namingPattern.format.extension,
        substitutions: substitutions,
        pathContext: hostPaths,
      );
      final taken = await _hostTakenKeeperPaths(backend, hostPaths);
      final unique = await ImagingService.uniqueFilePath(
        fullPath,
        hostPaths,
        (candidate) async => taken.contains(_hostPathKey(hostPaths, candidate)),
      );
      _hostReservedKeeperPaths.add(_hostPathKey(hostPaths, unique));
      return unique;
    }

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

    return ImagingService.uniqueFilePath(
      fullPath,
      path.context,
      (candidate) => File(candidate).exists(),
    );
  }

  /// Comparison key for a host path: normalized in the host's style, and
  /// case-folded on a Windows host whose filesystem ignores case.
  String _hostPathKey(path.Context hostPaths, String hostPath) {
    final normalized = hostPaths.normalize(hostPath);
    return hostPaths.style == path.Style.windows
        ? normalized.toLowerCase()
        : normalized;
  }

  /// Keeper paths that already exist on a linked host: every image the host
  /// has recorded plus every path this service handed out. The host's save
  /// endpoint overwrites an existing file and offers no way to test for one,
  /// so its image records are the only listing a client can read.
  Future<Set<String>> _hostTakenKeeperPaths(
    NetworkBackend backend,
    path.Context hostPaths,
  ) async {
    final taken = <String>{..._hostReservedKeeperPaths};
    try {
      final rows = await backend.getAllImages();
      for (final row in rows) {
        final filePath = row['filePath'];
        if (filePath is String && filePath.isNotEmpty) {
          taken.add(_hostPathKey(hostPaths, filePath));
        }
      }
    } catch (e) {
      _logger.warning(
        'Could not list the frames the imaging host has recorded ($e) — '
        'only frames saved from this window are avoided',
        source: 'ImagingService',
      );
    }
    return taken;
  }

  /// The `$SEQ`/`$FRAMENUM` value to stamp on the next KEEPER, given that
  /// [ImagingService._frameNumber] counts only this service instance's frames.
  ///
  /// `imagingServiceProvider` watches `backendProvider`, so the service — and
  /// with it the counter — is rebuilt on every app start and on every host
  /// switch or reconnect. The counter therefore returned to 0 several times a
  /// night while the shipped pattern `$TARGET_$FILTER_$DATE_$SEQ` still
  /// resolved to the same folder and the same UTC date: the next Snapshot
  /// asked for `0001` with `0001` already on disk. [ImagingService.uniqueFilePath] kept
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

      final backend = _ref.read(backendProvider);
      final hostPaths = backend is NetworkBackend
          ? hostPathContext(basePath)
          : null;
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
        pathContext: hostPaths,
      );

      // A pattern that renders no frame number (e.g. `$TARGET_$DATETIME`)
      // gives the same path for every candidate: probing it would never
      // terminate, and there uniqueness is ImagingService.uniqueFilePath's job.
      if (renderFor(fallback) == renderFor(fallback + 1)) return fallback;

      final Future<bool> Function(String) exists;
      if (hostPaths != null) {
        final taken = await _hostTakenKeeperPaths(
          backend as NetworkBackend,
          hostPaths,
        );
        exists = (p) async => taken.contains(_hostPathKey(hostPaths, p));
      } else {
        exists = (p) => File(p).exists();
      }

      var candidate = fallback;
      final ceiling = fallback + ImagingService._keeperProbeLimit;
      while (candidate < ceiling && await exists(renderFor(candidate))) {
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

  /// Save FITS file via Rust backend
  ///
  /// Uses the optimized saveFitsFromLastCapture API which reads raw image data
  /// directly from Rust-side storage, avoiding expensive FFI data transfers.
}
