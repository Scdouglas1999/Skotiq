part of '../default_science_backend.dart';

extension _DefaultScienceBackendHelpers on DefaultScienceBackend {
  /// Match detected stars against the photometric catalog. Returns the
  /// matches plus the catalog that actually served them (APASS when the
  /// deep catalog was available, bundled HYG otherwise) so calibration
  /// rows and MAGZPSRC carry real provenance.
  Future<(List<_CatalogMatch>, PhotometricCatalogSource)> _catalogMatches({
    required String imagePath,
    required WcsSolution wcs,
    required List<StarMeasurement> detectedStars,
    required double maxCatalogMag,
    required double maxMatchPx,
  }) async {
    const fallback = (<_CatalogMatch>[], PhotometricCatalogSource.localHyg);
    try {
      final fits = await readFitsImageSize(imagePath);
      if (fits == null) return fallback;
      final radius =
          (math.sqrt(
                        wcs.fieldWidthDegrees * wcs.fieldWidthDegrees +
                            wcs.fieldHeightDegrees * wcs.fieldHeightDegrees,
                      ) *
                      0.65 +
                  0.3)
              .clamp(0.25, 8.0)
              .toDouble();
      final cone = await _ref
          .read(photometricCatalogServiceProvider)
          .coneSearch(
            raDegrees: wcs.raHours * 15.0,
            decDegrees: wcs.decDegrees,
            radiusDegrees: radius,
            maxMagnitude: maxCatalogMag,
          );
      if (cone.stars.isEmpty) return fallback;

      final projection = _projectionFor(
        wcs,
        imageWidth: fits.width,
        imageHeight: fits.height,
      );
      if (projection == null) {
        _logger.warning(
          'Catalog matching skipped for $imagePath: WCS/image geometry is '
          'not projectable (scale=${wcs.pixelScaleArcsecPerPixel}, '
          'dims=${fits.width}x${fits.height}).',
          source: 'ScienceBackend',
        );
        return fallback;
      }
      final matches = await _matchCatalogInBackground(
        projection,
        cone.stars,
        detectedStars,
        maxMatchPx,
      );
      if (matches == null) return fallback;
      return (matches, cone.source);
    } catch (error, stack) {
      _logger.warning(
        'Catalog matching failed for $imagePath: $error\n$stack',
        source: 'ScienceBackend',
      );
      return fallback;
    }
  }

  /// Canonical TAN projection for a science [WcsSolution] + frame geometry,
  /// or null when the inputs are not projectable (zero/negative pixel scale
  /// or dimensions). The shared implementation lives in
  /// `services/wcs/gnomonic_projection.dart`.
  GnomonicProjection? _projectionFor(
    WcsSolution wcs, {
    required int imageWidth,
    required int imageHeight,
  }) {
    final solved = SolvedWcs(
      raHours: wcs.raHours,
      decDegrees: wcs.decDegrees,
      rotationDeg: wcs.rotationDegrees,
      pixelScaleArcsec: wcs.pixelScaleArcsecPerPixel,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      cd1_1: wcs.cd1_1,
      cd1_2: wcs.cd1_2,
      cd2_1: wcs.cd2_1,
      cd2_2: wcs.cd2_2,
      aOrder: wcs.aOrder,
      bOrder: wcs.bOrder,
      aCoeffs: wcs.aCoeffs,
      bCoeffs: wcs.bCoeffs,
      apOrder: wcs.apOrder,
      bpOrder: wcs.bpOrder,
      apCoeffs: wcs.apCoeffs,
      bpCoeffs: wcs.bpCoeffs,
    );
    if (!solved.isValid) return null;
    return GnomonicProjection(solved);
  }

  (ScienceFrameQualityMetrics, List<ScienceTileMetric>)
  _mapBridgeQualityResult({
    required QualityMapsResultApi result,
    required DateTime timestamp,
    required int? capturedImageId,
    required int? sessionId,
    required String fallbackProcessingTier,
  }) {
    final frame = result.frame;
    final mappedFrame = ScienceFrameQualityMetrics(
      capturedImageId: capturedImageId,
      sessionId: sessionId,
      timestamp: timestamp,
      median: frame.median,
      mean: frame.mean,
      stdDev: frame.stdDev,
      mad: frame.mad,
      background: frame.background,
      noise: frame.noise,
      snr: frame.snr,
      dynamicRangeP1P99: frame.dynamicRangeP1P99,
      lowClipPercent: frame.lowClipPercent,
      highClipPercent: frame.highClipPercent,
      uniformityCv: frame.uniformityCv,
      gradientX: frame.gradientX,
      gradientY: frame.gradientY,
      processingTier: frame.processingTier.isEmpty
          ? fallbackProcessingTier
          : frame.processingTier,
      processingMs: frame.processingMs,
    );

    final mappedTiles = result.tiles
        .map(
          (tile) => ScienceTileMetric(
            capturedImageId: capturedImageId,
            sessionId: sessionId,
            timestamp: timestamp,
            layerType: ScienceLayerType.fromDbValue(tile.layerType),
            tileRow: tile.tileRow,
            tileCol: tile.tileCol,
            sampleCount: tile.sampleCount,
            value: tile.value,
            p05: tile.p05,
            p50: tile.p50,
            p95: tile.p95,
            auxValue: tile.auxValue,
          ),
        )
        .toList(growable: false);

    return (mappedFrame, mappedTiles);
  }

  /// Name the engine a science solve actually dispatches to.
  ///
  /// The engine is picked by the plate-solver preference — the store the Plate
  /// Solving page writes and the Rust dispatcher reads — never the
  /// `plate_solver` app-setting, which no UI writes and which seeds to
  /// `'ASTAP'` whatever is installed.
  ///
  /// Auto tries ASTAP and falls back to astrometry.net per frame, and the
  /// solve result carries no engine id, so when both are installed the only
  /// truthful answer names both rather than picking the likelier one.
  Future<({String label, bool available})> _resolveSolver() async {
    final service = _ref.read(plateSolveServiceProvider);
    try {
      final pref = await service.getConfig();
      switch (pref.choice) {
        case PlateSolverChoice.astap:
          return (label: 'ASTAP', available: true);
        case PlateSolverChoice.astrometry:
          return (label: 'Astrometry.net', available: true);
        case PlateSolverChoice.auto:
          final detection = await service.detect();
          final astap = detection.astapReady;
          final astrometry = detection.astrometryPath != null;
          if (astap && astrometry) {
            return (label: 'ASTAP or Astrometry.net', available: true);
          }
          if (astap) return (label: 'ASTAP', available: true);
          if (astrometry) return (label: 'Astrometry.net', available: true);
          return (label: 'unknown', available: false);
      }
    } catch (error) {
      _logger.warning(
        'Could not read the plate-solver preference; recording the solver as '
        'unknown rather than guessing: $error',
        source: 'ScienceBackend',
      );
      return (label: 'unknown', available: false);
    }
  }

  /// Camera full-well / white level in ADU used to flag saturated stars.
  /// Defaults to 65535 (16-bit). 12/14-bit cameras whose drivers do not
  /// scale to 16 bits clip at 4095/16383, and stars saturated there are
  /// photometrically useless — set science.camera.saturation_adu so the
  /// detector can reject them.
  Future<int> _saturationLimitAdu() async {
    try {
      final dao = _ref.read(settingsDaoProvider);
      final stored = await dao.getSetting('science.camera.saturation_adu');
      if (stored != null && stored.isNotEmpty) {
        final parsed = int.tryParse(stored);
        if (parsed != null && parsed >= 255 && parsed <= 65535) {
          return parsed;
        }
        _logger.warning(
          'Invalid science.camera.saturation_adu setting "$stored"; using 65535.',
          source: 'ScienceBackend',
        );
      }
    } catch (error, stack) {
      _logger.warning(
        'Failed to read science.camera.saturation_adu; using 65535: $error\n$stack',
        source: 'ScienceBackend',
      );
    }
    return 65535;
  }
}
