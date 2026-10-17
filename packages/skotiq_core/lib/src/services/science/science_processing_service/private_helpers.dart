part of '../science_processing_service.dart';

extension _ScienceProcessingPrivateHelpers on ScienceProcessingService {
  Future<void> _processImmediateQualityLane({
    required String imagePath,
    required String? deviceId,
    required int? capturedImageId,
    required int? sessionId,
    required DateTime timestamp,
  }) async {
    final laneStopwatch = Stopwatch()..start();
    final prefs = await _ref
        .read(scienceVisualizationPrefsProvider.future)
        .catchError((_) => const ScienceVisualizationPrefs());

    if (_adaptiveLiveGridRows <= 0) {
      _adaptiveLiveGridRows = prefs.liveGridRows;
    }
    if (_adaptiveLiveGridCols <= 0) {
      _adaptiveLiveGridCols = prefs.liveGridCols;
    }

    const lowClipAdu = 16;
    const highClipAdu = 65520;
    (ScienceFrameQualityMetrics, List<ScienceTileMetric>) products;

    try {
      if (deviceId != null && deviceId.isNotEmpty) {
        products = await _scienceBackend.computeLastCaptureQualityMaps(
          deviceId: deviceId,
          gridRows: _adaptiveLiveGridRows,
          gridCols: _adaptiveLiveGridCols,
          lowClipAdu: lowClipAdu,
          highClipAdu: highClipAdu,
          timestamp: timestamp,
          capturedImageId: capturedImageId,
          sessionId: sessionId,
        );
      } else {
        throw StateError('No device ID available for live quality maps');
      }
    } catch (error, stack) {
      _logger.warning(
        'Live quality-map lane failed for $imagePath; falling back to FITS lane: $error\n$stack',
        source: 'ScienceProcessingService',
      );
      products = await _scienceBackend.computeFitsQualityMaps(
        filePath: imagePath,
        gridRows: prefs.analysisGridRows,
        gridCols: prefs.analysisGridCols,
        lowClipAdu: lowClipAdu,
        highClipAdu: highClipAdu,
        timestamp: timestamp,
        capturedImageId: capturedImageId,
        sessionId: sessionId,
      );
    }

    final frameMetrics = products.$1.copyWith(
      processingMs: laneStopwatch.elapsedMilliseconds,
    );
    final tileMetrics = products.$2;
    final frameCompanion = db.ScienceFrameQualityMetricsCompanion.insert(
      capturedImageId: drift.Value(capturedImageId),
      sessionId: drift.Value(sessionId),
      timestamp: drift.Value(frameMetrics.timestamp),
      median: drift.Value(frameMetrics.median),
      mean: drift.Value(frameMetrics.mean),
      stdDev: drift.Value(frameMetrics.stdDev),
      mad: drift.Value(frameMetrics.mad),
      background: drift.Value(frameMetrics.background),
      noise: drift.Value(frameMetrics.noise),
      snr: drift.Value(frameMetrics.snr),
      dynamicRangeP1P99: drift.Value(frameMetrics.dynamicRangeP1P99),
      lowClipPercent: drift.Value(frameMetrics.lowClipPercent),
      highClipPercent: drift.Value(frameMetrics.highClipPercent),
      uniformityCv: drift.Value(frameMetrics.uniformityCv),
      gradientX: drift.Value(frameMetrics.gradientX),
      gradientY: drift.Value(frameMetrics.gradientY),
      processingTier: drift.Value(frameMetrics.processingTier),
      processingMs: drift.Value(frameMetrics.processingMs),
    );

    final tileCompanions = tileMetrics
        .map(
          (tile) => db.ScienceTileMetricsCompanion.insert(
            capturedImageId: drift.Value(tile.capturedImageId),
            sessionId: drift.Value(tile.sessionId),
            timestamp: drift.Value(tile.timestamp),
            layerType: tile.layerType.dbValue,
            tileRow: tile.tileRow,
            tileCol: tile.tileCol,
            sampleCount: drift.Value(tile.sampleCount),
            value: drift.Value(tile.value),
            p05: drift.Value(tile.p05),
            p50: drift.Value(tile.p50),
            p95: drift.Value(tile.p95),
            auxValue: drift.Value(tile.auxValue),
          ),
        )
        .toList(growable: false);

    if (capturedImageId != null) {
      await _scienceDao.replaceFrameQualityMetricsForImage(
        capturedImageId,
        frameCompanion,
      );
      await _scienceDao.replaceTileMetricsForImage(
        capturedImageId,
        tileCompanions,
      );
    } else {
      await _scienceDao.insertFrameQualityMetrics(frameCompanion);
      await _scienceDao.insertTileMetrics(tileCompanions);
    }

    final liveMs = laneStopwatch.elapsedMilliseconds;
    _logger.debug(
      'science.live_ms=$liveMs',
      source: 'ScienceProcessingService',
    );
    if (liveMs > 150) {
      _liveBudgetBreachCount++;
      if (_liveBudgetBreachCount >= 3) {
        _adaptiveLiveGridRows = math.max(
          6,
          (_adaptiveLiveGridRows * 0.8).floor(),
        );
        _adaptiveLiveGridCols = math.max(
          8,
          (_adaptiveLiveGridCols * 0.8).floor(),
        );
        _liveBudgetBreachCount = 0;
      }
    } else {
      _liveBudgetBreachCount = math.max(0, _liveBudgetBreachCount - 1);
    }
  }

  /// Computes and persists photometry rows for the frame. Returns the number
  /// of [PhotometryMeasurements] rows actually written, or `0` when the frame
  /// produced no measurements (too few stars, comparison set unusable, etc.).
  /// Callers use the count for status-pipeline reporting.
  Future<int> _computeAndStorePhotometry({
    required String imagePath,
    required int? capturedImageId,
    required int? sessionId,
    required WcsSolution? wcs,
    required SciencePhotometrySelection selection,
    required DateTime frameTimestamp,
    required double exposureSeconds,
    String? filterName,
    double? airmass,
  }) async {
    final stars = await _scienceBackend.measureStars(
      imagePath,
      const PhotometryOptions(minSnr: 4.0),
    );

    if (stars.length < 3) {
      return 0;
    }

    final sortedByFlux = stars.toList(growable: false)
      ..sort((a, b) => b.flux.compareTo(a.flux));
    final available = sortedByFlux.toList(growable: true);

    StarMeasurement? target;
    String targetObjectId = 'target_primary';
    final comparisonObjects = <({String objectId, StarMeasurement star})>[];

    if (selection.differentialEnabled &&
        selection.target != null &&
        wcs != null) {
      try {
        final fits = await apiReadFitsFile(filePath: imagePath);
        // Canonical TAN projection — same implementation the catalog
        // overlay and science backend use (services/wcs).
        final solved = SolvedWcs(
          raHours: wcs.raHours,
          decDegrees: wcs.decDegrees,
          rotationDeg: wcs.rotationDegrees,
          pixelScaleArcsec: wcs.pixelScaleArcsecPerPixel,
          imageWidth: fits.width,
          imageHeight: fits.height,
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
        final projection = solved.isValid ? GnomonicProjection(solved) : null;
        final targetPixel = projection
            ?.worldToPixel(
              raDegrees: selection.target!.raDegrees,
              decDegrees: selection.target!.decDegrees,
            )
            ?.pixel;
        if (targetPixel != null) {
          final matchedTarget = _findNearestStar(
            available,
            x: targetPixel.x,
            y: targetPixel.y,
            maxDistancePixels: 20.0,
          );
          if (matchedTarget != null) {
            target = matchedTarget;
            targetObjectId = selection.target!.objectId;
            available.remove(matchedTarget);
          }
        }

        for (final anchor in selection.comparisons) {
          final anchorPixel = projection
              ?.worldToPixel(
                raDegrees: anchor.raDegrees,
                decDegrees: anchor.decDegrees,
              )
              ?.pixel;
          if (anchorPixel == null) {
            continue;
          }
          final matched = _findNearestStar(
            available,
            x: anchorPixel.x,
            y: anchorPixel.y,
            maxDistancePixels: 20.0,
          );
          if (matched == null) {
            continue;
          }
          comparisonObjects.add((objectId: anchor.objectId, star: matched));
          available.remove(matched);
          if (comparisonObjects.length >= 8) {
            break;
          }
        }
      } catch (error, stack) {
        _logger.warning(
          'Failed to resolve configured photometry anchors for $imagePath: $error\n$stack',
          source: 'ScienceProcessingService',
        );
      }
    }

    if (target == null) {
      target = sortedByFlux.first;
      available.remove(target);
    }

    if (comparisonObjects.length < 2) {
      final fallback = available.take(4).toList(growable: false);
      for (var index = 0; index < fallback.length; index++) {
        comparisonObjects.add((
          objectId: 'comparison_${index + 1}',
          star: fallback[index],
        ));
      }
    }

    if (comparisonObjects.length < 2) {
      return 0;
    }

    final comparisonFluxes =
        comparisonObjects
            .map((entry) => entry.star.flux)
            .toList(growable: false)
          ..sort();
    final medianComparisonFlux = _median(comparisonFluxes);
    final madComparisonFlux = _mad(comparisonFluxes, medianComparisonFlux);
    final robustSigma = (1.4826 * madComparisonFlux).clamp(
      0.0,
      double.infinity,
    );

    final inliers = <({String objectId, StarMeasurement star})>[];
    final outlierObjectIds = <String>{};
    for (final entry in comparisonObjects) {
      if (robustSigma <= 0.0) {
        inliers.add(entry);
        continue;
      }
      final deviation = (entry.star.flux - medianComparisonFlux).abs();
      if (deviation <= 3.0 * robustSigma) {
        inliers.add(entry);
      } else {
        outlierObjectIds.add(entry.objectId);
      }
    }

    final targetFlux = target.flux.clamp(1e-6, double.infinity);

    // AAVSO-style check star: with 3+ inlier comparisons, promote the one
    // whose brightness is closest to the target (the standard guidance for
    // check-star choice) out of the ensemble. It is then measured exactly
    // like the target — differential magnitude against the remaining
    // ensemble — so a drifting zero point or a variable "comparison" shows
    // up as scatter in the check star's light curve. With only 2
    // comparisons the ensemble would collapse to a single star, so no
    // check is designated.
    String? checkObjectId;
    var ensemble = inliers.length >= 2 ? inliers : comparisonObjects;
    if (inliers.length >= 3) {
      final checkEntry = inliers.reduce(
        (a, b) =>
            (a.star.flux - targetFlux).abs() <= (b.star.flux - targetFlux).abs()
            ? a
            : b,
      );
      checkObjectId = checkEntry.objectId;
      ensemble = inliers
          .where((entry) => entry.objectId != checkObjectId)
          .toList(growable: false);
    }

    final weightedFluxTuple = _weightedComparisonFlux(ensemble);
    final comparisonFlux = weightedFluxTuple.$1;
    final comparisonFluxUncertainty = weightedFluxTuple.$2;
    if (comparisonFlux <= 0 || !comparisonFlux.isFinite) {
      return 0;
    }
    final targetSnr = target.snr.isFinite
        ? target.snr.clamp(1.0, 1e6).toDouble()
        : 1.0;
    final targetFluxSigma = targetFlux / targetSnr;

    // Try to apply photometric transform for absolute magnitude
    PhotometricTransformCoefficients? transform;
    if (filterName != null && filterName.isNotEmpty) {
      try {
        final transformService = _ref.read(photometricTransformServiceProvider);
        transform = await transformService.getTransformForFilter(filterName);
      } catch (error) {
        _logger.debug(
          'No photometric transform available for filter $filterName: $error',
          source: 'ScienceProcessingService',
        );
      }
    }

    // Transforms are fitted against exposure-normalized fluxes (see the
    // calibration wizard), so the instrumental magnitude here must use the
    // same normalization or the standard magnitude shifts by
    // 2.5·log10(exposure ratio) between calibration and science frames.
    final safeExposure = exposureSeconds.isFinite && exposureSeconds > 0
        ? exposureSeconds
        : 1.0;

    final entries = ScienceProcessingService.buildPhotometryMeasurementRows(
      capturedImageId: capturedImageId,
      sessionId: sessionId,
      frameTimestamp: frameTimestamp,
      targetObjectId: targetObjectId,
      target: target,
      targetFlux: targetFlux,
      targetFluxSigma: targetFluxSigma,
      comparisons: comparisonObjects,
      checkObjectId: checkObjectId,
      outlierObjectIds: outlierObjectIds,
      comparisonFlux: comparisonFlux,
      comparisonFluxUncertainty: comparisonFluxUncertainty,
      transform: transform,
      airmass: airmass,
      exposureSeconds: safeExposure,
    );

    if (capturedImageId != null) {
      await _scienceDao.replacePhotometryMeasurementsForImage(
        capturedImageId,
        entries,
      );
    } else {
      await _scienceDao.insertPhotometryMeasurements(entries);
    }
    return entries.length;
  }

  StarMeasurement? _findNearestStar(
    List<StarMeasurement> stars, {
    required double x,
    required double y,
    required double maxDistancePixels,
  }) {
    StarMeasurement? best;
    var bestDistance = maxDistancePixels;
    for (final star in stars) {
      final dx = star.x - x;
      final dy = star.y - y;
      final distance = math.sqrt(dx * dx + dy * dy);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = star;
      }
    }
    return best;
  }

  (double, double) _weightedComparisonFlux(
    List<({String objectId, StarMeasurement star})> comparisons,
  ) {
    if (comparisons.isEmpty) {
      return (0.0, 0.0);
    }

    var weightedSum = 0.0;
    var weightSum = 0.0;
    for (final entry in comparisons) {
      final star = entry.star;
      final flux = star.flux.clamp(1e-6, double.infinity);
      final safeSnr = star.snr.isFinite
          ? star.snr.clamp(1.0, 1e6).toDouble()
          : 1.0;
      final sigma = flux / safeSnr;
      final variance = math.max(1e-12, sigma * sigma);
      final weight = 1.0 / variance;
      weightedSum += flux * weight;
      weightSum += weight;
    }

    if (weightSum <= 0.0) {
      return (0.0, 0.0);
    }

    final flux = weightedSum / weightSum;
    final sigma = math.sqrt(1.0 / weightSum);
    return (flux, sigma);
  }

  double _median(List<double> values) {
    if (values.isEmpty) {
      return 0.0;
    }
    final sorted = values.toList(growable: false)..sort();
    final middle = sorted.length ~/ 2;
    if (sorted.length.isOdd) {
      return sorted[middle];
    }
    return (sorted[middle - 1] + sorted[middle]) / 2.0;
  }

  double _mad(List<double> values, double median) {
    if (values.isEmpty) {
      return 0.0;
    }
    final deviations = values
        .map((value) => (value - median).abs())
        .toList(growable: false);
    return _median(deviations);
  }

  Future<WcsSolution?> _resolveWcsSolution({
    required String imagePath,
    required int? capturedImageId,
    db.CapturedImage? capturedImage,
  }) async {
    final image = capturedImageId == null
        ? null
        : (capturedImage ?? await _imagesRepo.getImageById(capturedImageId));
    if (image != null &&
        image.isPlateSolved &&
        image.solvedRa != null &&
        image.solvedDec != null) {
      final pixelScale = image.solvedPixelScale ?? 1.5;
      var fieldWidth = 1.0;
      var fieldHeight = 1.0;
      try {
        final fits = await apiReadFitsFile(filePath: imagePath);
        fieldWidth = (fits.width * pixelScale / 3600.0)
            .clamp(0.05, 40.0)
            .toDouble();
        fieldHeight = (fits.height * pixelScale / 3600.0)
            .clamp(0.05, 40.0)
            .toDouble();
      } catch (error, stack) {
        _logger.warning(
          'Unable to derive field size from FITS for stored WCS ($imagePath): $error\n$stack',
          source: 'ScienceProcessingService',
        );
      }
      final distortion = capturedImageId == null
          ? null
          : await _imagesRepo.getStoredWcsDistortion(capturedImageId);
      final sip = decodeSolvedSip(distortion?.sip);
      return WcsSolution(
        raHours: image.solvedRa!,
        decDegrees: image.solvedDec!,
        pixelScaleArcsecPerPixel: pixelScale,
        rotationDegrees: image.solvedRotation ?? 0.0,
        fieldWidthDegrees: fieldWidth,
        fieldHeightDegrees: fieldHeight,
        solverId: 'stored',
        cd1_1: distortion?.cd1_1,
        cd1_2: distortion?.cd1_2,
        cd2_1: distortion?.cd2_1,
        cd2_2: distortion?.cd2_2,
        aOrder: sip?.aOrder ?? 0,
        bOrder: sip?.bOrder ?? 0,
        aCoeffs: sip?.aCoeffs ?? const [],
        bCoeffs: sip?.bCoeffs ?? const [],
        apOrder: sip?.apOrder ?? 0,
        bpOrder: sip?.bpOrder ?? 0,
        apCoeffs: sip?.apCoeffs ?? const [],
        bpCoeffs: sip?.bpCoeffs ?? const [],
      );
    }

    final solved = await _scienceBackend.solveForScience(
      imagePath,
      const SolveOptions(),
    );

    if (solved != null && capturedImageId != null) {
      await _imagesRepo.updatePlateSolveResult(
        capturedImageId,
        solvedRa: solved.raHours,
        solvedDec: solved.decDegrees,
        solvedRotation: solved.rotationDegrees,
        solvedPixelScale: solved.pixelScaleArcsecPerPixel,
        solvedCd1_1: solved.cd1_1,
        solvedCd1_2: solved.cd1_2,
        solvedCd2_1: solved.cd2_1,
        solvedCd2_2: solved.cd2_2,
        solvedSip: encodeSolvedSip(
          aOrder: solved.aOrder,
          bOrder: solved.bOrder,
          aCoeffs: solved.aCoeffs,
          bCoeffs: solved.bCoeffs,
          apOrder: solved.apOrder,
          bpOrder: solved.bpOrder,
          apCoeffs: solved.apCoeffs,
          bpCoeffs: solved.bpCoeffs,
        ),
      );
    }

    return solved;
  }

  Future<ScienceFrameContext> _buildFrameContext({
    required String imagePath,
    required int? capturedImageId,
    required int? sessionId,
    required db.CapturedImage? capturedImage,
    required WcsSolution? wcs,
  }) async {
    FitsReadResult? fits;
    try {
      fits = await apiReadFitsFile(filePath: imagePath);
    } catch (error, stack) {
      _logger.warning(
        'FITS metadata read failed for $imagePath. Continuing only with trusted DB metadata: $error\n$stack',
        source: 'ScienceProcessingService',
      );
    }

    final fitsCapturedAt = tryParseUtcTimestamp(fits?.dateObs);
    final capturedAt = capturedImage?.capturedAt ?? fitsCapturedAt;
    if (capturedAt == null) {
      throw StateError(
        'Capture timestamp unavailable for $imagePath. Need captured image metadata or FITS DATE-OBS.',
      );
    }

    final exposureRaw = capturedImage?.exposureDuration ?? fits?.exposureTime;
    if (exposureRaw == null || !exposureRaw.isFinite || exposureRaw <= 0.0) {
      throw StateError(
        'Exposure duration unavailable for $imagePath. Need captured image metadata or FITS exposure time.',
      );
    }
    final exposureSeconds = exposureRaw.clamp(0.001, 1e6).toDouble();
    final filterName = capturedImage?.filter ?? fits?.filter;
    final width = fits?.width ?? 0;
    final height = fits?.height ?? 0;

    double? airmass;
    if (capturedImage != null) {
      airmass = await _airmassForCapturedImage(
        image: capturedImage,
        timestamp: capturedAt,
      );
    } else if (wcs != null) {
      airmass = await _airmassFromWcs(wcs: wcs, timestamp: capturedAt);
    }

    return ScienceFrameContext(
      capturedImageId: capturedImageId,
      sessionId: sessionId,
      capturedAt: capturedAt,
      exposureSeconds: exposureSeconds,
      filterName: filterName,
      airmass: airmass,
      imageWidth: width,
      imageHeight: height,
    );
  }

  Future<DateTime> _resolveFrameTimestamp({
    required String imagePath,
    required db.CapturedImage? capturedImage,
  }) async {
    if (capturedImage?.capturedAt case final ts?) {
      return ts;
    }

    try {
      return await File(imagePath).lastModified();
    } catch (error, stack) {
      _logger.warning(
        'Failed to resolve frame timestamp from metadata for $imagePath: $error\n$stack',
        source: 'ScienceProcessingService',
      );
      throw StateError(
        'Frame timestamp is unavailable for $imagePath. Capture metadata is required.',
      );
    }
  }

  Future<double?> _airmassFromWcs({
    required WcsSolution wcs,
    required DateTime timestamp,
  }) async {
    return _airmassFromCoordinates(
      raHours: wcs.raHours,
      decDegrees: wcs.decDegrees,
      timestamp: timestamp,
      sourceLabel: 'WCS',
    );
  }

  Future<double?> _airmassFromCoordinates({
    required double raHours,
    required double decDegrees,
    required DateTime timestamp,
    required String sourceLabel,
  }) async {
    final settings = _ref.read(appSettingsProvider).valueOrNull;
    if (settings == null ||
        settings.latitude == 0.0 && settings.longitude == 0.0) {
      return null;
    }
    try {
      final altitude = apiCalculateAltitude(
        raHours: raHours,
        decDegrees: decDegrees,
        latitude: settings.latitude,
        longitude: settings.longitude,
        timeUnixMillis: timestamp.toUtc().millisecondsSinceEpoch,
      );
      return airmassForTrueAltitude(altitude);
    } catch (error, stack) {
      _logger.warning(
        'Airmass calculation failed ($sourceLabel RA=$raHours, Dec=$decDegrees, lat=${settings.latitude}, lon=${settings.longitude}, ts=${timestamp.toUtc().toIso8601String()}): $error\n$stack',
        source: 'ScienceProcessingService',
      );
      return null;
    }
  }

  Future<double?> _airmassForCapturedImage({
    required db.CapturedImage image,
    required DateTime timestamp,
  }) async {
    if (image.mountAltitude != null) {
      return airmassForTrueAltitude(image.mountAltitude!);
    }
    if (image.solvedRa != null && image.solvedDec != null) {
      return _airmassFromCoordinates(
        raHours: image.solvedRa!,
        decDegrees: image.solvedDec!,
        timestamp: timestamp,
        sourceLabel: 'Stored solved coordinates',
      );
    }
    return null;
  }

  PhotometricCatalogSource _catalogFromName(String source) {
    for (final catalog in PhotometricCatalogSource.values) {
      if (catalog.name == source) {
        return catalog;
      }
    }
    return PhotometricCatalogSource.auto;
  }

  double _metricValue(List<LineRatioMetric> metrics, String label) {
    for (final metric in metrics) {
      if (metric.label == label) {
        return metric.value;
      }
    }
    return 0.0;
  }
}
