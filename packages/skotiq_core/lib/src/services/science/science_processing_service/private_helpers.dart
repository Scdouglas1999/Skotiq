part of '../science_processing_service.dart';

extension _ScienceProcessingPrivateHelpers on ScienceProcessingService {
  /// A positive camera setting from `science.camera.*`, or null when unset or
  /// invalid.
  Future<double?> _cameraSetting(String key) async {
    try {
      final stored = await _ref.read(settingsDaoProvider).getSetting(key);
      final parsed = stored == null ? null : double.tryParse(stored);
      return parsed != null && parsed.isFinite && parsed > 0 ? parsed : null;
    } catch (_) {
      return null;
    }
  }

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

    if (deviceId == null || deviceId.isEmpty) {
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
    } else {
      try {
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
    }

    // The stored `snr` is the sky-to-read-noise ratio of the sub (see
    // skyToReadNoiseRatio); 0 when the camera's gain or read noise is unknown.
    final gain = await _cameraSetting('science.camera.gain_e_per_adu');
    final readNoise = await _cameraSetting('science.camera.read_noise_e');
    double noiseRatio(double noiseAdu) =>
        skyToReadNoiseRatio(
          noiseAdu: noiseAdu,
          gainEPerAdu: gain,
          readNoiseE: readNoise,
        ) ??
        0.0;
    final frameMetrics = products.$1.copyWith(
      processingMs: laneStopwatch.elapsedMilliseconds,
      snr: noiseRatio(products.$1.noise),
    );
    final tileMetrics = products.$2
        .map(
          (tile) => tile.layerType == ScienceLayerType.snr
              ? tile.withValue(noiseRatio(tile.auxValue))
              : tile,
        )
        .toList(growable: false);
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
    if (!selection.differentialEnabled ||
        selection.target == null ||
        wcs == null) {
      return 0;
    }
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
    var targetObjectId = selection.target!.objectId;
    final comparisonObjects = <({String objectId, StarMeasurement star})>[];

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
      }
    } catch (error, stack) {
      _logger.warning(
        'Failed to resolve configured photometry anchors for $imagePath: $error\n$stack',
        source: 'ScienceProcessingService',
      );
    }

    // Differential photometry needs a target the user chose: without one the
    // "target" would be whichever star is brightest in each frame, a
    // different star from frame to frame.
    if (target == null) {
      if (selection.differentialEnabled && selection.target != null) {
        _logger.info(
          'Differential photometry skipped for $imagePath: target '
          '${selection.target!.label} not found within 20 px of its position.',
          source: 'ScienceProcessingService',
        );
      }
      return 0;
    }

    // Re-measure the target and comparisons in one shared aperture, so the
    // differential magnitude compares like with like. Stars keep their
    // detector flux when the file cannot be read this way.
    final measured = await measureSharedApertureStars(
      imagePath: imagePath,
      frameStars: stars,
      target: target,
      comparisons: comparisonObjects,
    );
    target = measured.target;
    comparisonObjects
      ..clear()
      ..addAll(measured.comparisons);

    final sessionCheckId = sessionId == null
        ? null
        : await _scienceDao.getSessionCheckStarId(sessionId);
    final gain = await _photometryGainElectronsPerAdu();
    final frame = ScienceProcessingService.buildDifferentialFrame(
      target: target,
      comparisons: comparisonObjects,
      comparisonIds: selection.comparisons
          .map((a) => a.objectId)
          .toList(growable: false),
      sessionCheckId: sessionCheckId,
      gainElectronsPerAdu: gain,
    );
    if (frame.skipReason != null) {
      _logger.info(
        'Differential photometry skipped for $imagePath: ${frame.skipReason}',
        source: 'ScienceProcessingService',
      );
      return 0;
    }
    final targetFlux = target.flux.clamp(1e-6, double.infinity).toDouble();
    final checkObjectId = frame.checkObjectId;
    final outlierObjectIds = <String>{};
    final comparisonFlux = frame.ensembleFlux!;
    final comparisonFluxUncertainty = frame.ensembleFluxSigma!;
    final targetFluxSigma = frame.targetFluxSigma!;

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

    // A transform with a color term needs each star's own B-V; it comes from
    // the catalog star at the anchor's position.
    final colorIndexByObject = <String, double>{};
    if (transform != null && transform.colorTerm != 0) {
      final anchors = [selection.target!, ...selection.comparisons];
      for (final anchor in anchors) {
        final bv = await _catalogColorIndex(
          raDegrees: anchor.raDegrees,
          decDegrees: anchor.decDegrees,
        );
        if (bv != null) colorIndexByObject[anchor.objectId] = bv;
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
      filter: filterName,
      gainElectronsPerAdu: gain,
      colorIndexByObject: colorIndexByObject,
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

  /// B-V of the catalog star within 3 arcsec of a position, or null.
  Future<double?> _catalogColorIndex({
    required double raDegrees,
    required double decDegrees,
  }) async {
    try {
      final cone = await _ref
          .read(photometricCatalogServiceProvider)
          .coneSearch(
            raDegrees: raDegrees,
            decDegrees: decDegrees,
            radiusDegrees: 0.05,
            maxMagnitude: 20,
          );
      PhotometricCatalogStar? best;
      var bestSep = 3.0 / 3600.0;
      final cosDec = math.cos(decDegrees * math.pi / 180);
      for (final star in cone.stars) {
        final dRa = (star.raDegrees - raDegrees) * cosDec;
        final dDec = star.decDegrees - decDegrees;
        final sep = math.sqrt(dRa * dRa + dDec * dDec);
        if (sep < bestSep) {
          bestSep = sep;
          best = star;
        }
      }
      return best?.colorIndexBv;
    } catch (_) {
      return null;
    }
  }

  /// The configured camera e⁻/ADU, or null when unset.
  Future<double?> _photometryGainElectronsPerAdu() async {
    try {
      final stored = await _ref
          .read(settingsDaoProvider)
          .getSetting(ScienceCameraAutoConfig.gainKey);
      final parsed = double.tryParse(stored ?? '');
      if (parsed != null && parsed.isFinite && parsed > 0) return parsed;
    } catch (_) {
      // Unreadable setting: the error bars then carry background noise only.
    }
    return null;
  }

  /// The stored plate solve of [image] as a [WcsSolution], without reading
  /// the frame; null when the row was never solved. The field size is left
  /// nominal because only the projection (centre, CD, SIP) is used.
  Future<WcsSolution?> _storedWcsFor(db.CapturedImage image) async {
    if (!image.isPlateSolved ||
        image.solvedRa == null ||
        image.solvedDec == null) {
      return null;
    }
    final distortion = await _imagesRepo.getStoredWcsDistortion(image.id);
    final sip = decodeSolvedSip(distortion?.sip);
    return WcsSolution(
      raHours: image.solvedRa!,
      decDegrees: image.solvedDec!,
      pixelScaleArcsecPerPixel: image.solvedPixelScale ?? 1.5,
      rotationDegrees: image.solvedRotation ?? 0.0,
      fieldWidthDegrees: 1.0,
      fieldHeightDegrees: 1.0,
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

  Future<WcsSolution?> _resolveWcsSolution({
    required String imagePath,
    required int? capturedImageId,
    db.CapturedImage? capturedImage,
    bool solveIfUnsolved = true,
  }) async {
    final image = capturedImageId == null
        ? null
        : (capturedImage ?? await _imagesRepo.getImageById(capturedImageId));
    final stored =
        capturedImageId == null ||
            image == null ||
            !image.isPlateSolved ||
            image.solvedRa == null ||
            image.solvedDec == null
        ? null
        : await _imagesRepo.getStoredWcsDistortion(capturedImageId);
    final storedHasCd =
        stored?.cd1_1 != null &&
        stored?.cd1_2 != null &&
        stored?.cd2_1 != null &&
        stored?.cd2_2 != null;
    // A stored solve without its CD matrix (the frame watch records only
    // centre, scale and rotation) cannot tell a mirrored frame from a normal
    // one, so the frame is solved again for the full WCS when solving is
    // allowed. The stored solve is the fallback if that solve fails.
    WcsSolution? solved;
    if (image != null &&
        image.isPlateSolved &&
        !storedHasCd &&
        solveIfUnsolved) {
      solved = await _scienceBackend.solveForScience(
        imagePath,
        const SolveOptions(),
      );
    }
    if (solved == null &&
        image != null &&
        image.isPlateSolved &&
        image.solvedRa != null &&
        image.solvedDec != null) {
      if (storedHasCd) _imagesRepo.notifySolvedFrame(capturedImageId!);
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
      final distortion = stored;
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

    if (solved == null) {
      if (!solveIfUnsolved) return null;
      solved = await _scienceBackend.solveForScience(
        imagePath,
        const SolveOptions(),
      );
    }

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

/// Replace the detector fluxes of [target] and [comparisons] with fluxes
/// in one circular aperture of three times the frame's median half-flux
/// radius (about 1.5 FWHM), sky from an annulus beyond twice that. The SNR
/// becomes the background-limited one of that aperture; the star's own
/// photon noise is added later with the camera's e-/ADU.
Future<
  ({
    StarMeasurement target,
    List<({String objectId, StarMeasurement star})> comparisons,
  })
>
measureSharedApertureStars({
  required String imagePath,
  required List<StarMeasurement> frameStars,
  required StarMeasurement target,
  required List<({String objectId, StarMeasurement star})> comparisons,
}) async {
  final unchanged = (target: target, comparisons: comparisons.toList());
  final hfrs =
      frameStars.map((s) => s.hfr).where((h) => h.isFinite && h > 0).toList()
        ..sort();
  if (hfrs.isEmpty) return unchanged;
  final radius = (3.0 * hfrs[hfrs.length ~/ 2]).clamp(3.0, 25.0).toDouble();
  final all = [target, ...comparisons.map((c) => c.star)];
  final apertures = await measureApertures(
    imagePath,
    [for (final s in all) (x: s.x, y: s.y)],
    radius: radius,
    innerSky: 2 * radius,
    outerSky: 2 * radius + math.max(6.0, radius),
  );
  if (apertures == null || apertures.any((a) => a == null || a.flux <= 0)) {
    return unchanged;
  }
  StarMeasurement withFlux(StarMeasurement s, ApertureFlux a) =>
      StarMeasurement(
        x: s.x,
        y: s.y,
        flux: a.flux,
        hfr: s.hfr,
        fwhm: s.fwhm,
        snr: a.backgroundSigma > 0 ? a.flux / a.backgroundSigma : s.snr,
        eccentricity: s.eccentricity,
        sharpness: s.sharpness,
        background: a.sky,
        peak: s.peak,
      );
  return (
    target: withFlux(target, apertures.first!),
    comparisons: [
      for (var i = 0; i < comparisons.length; i++)
        (
          objectId: comparisons[i].objectId,
          star: withFlux(comparisons[i].star, apertures[i + 1]!),
        ),
    ],
  );
}
