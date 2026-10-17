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
      final fits = await apiReadFitsFile(filePath: imagePath);
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
      final projected = <_ProjectedCatalogStar>[];
      for (final star in cone.stars) {
        final px = projection.worldToPixel(
          raDegrees: star.raDegrees,
          decDegrees: star.decDegrees,
        );
        if (px == null) continue;
        projected.add(
          _ProjectedCatalogStar(
            id: '${star.raDegrees.toStringAsFixed(6)}_${star.decDegrees.toStringAsFixed(6)}',
            x: px.pixel.x,
            y: px.pixel.y,
            mag: star.magV,
          ),
        );
      }
      if (projected.isEmpty) return fallback;

      // Brightest first, so the strongest detections claim their catalog star.
      final sorted = detectedStars.toList(growable: false)
        ..sort((a, b) => b.snr.compareTo(a.snr));

      // Bucketed rather than comparing every detection against every catalog
      // star — see `matchNearestUnclaimed` for why that mattered on a rich
      // field.
      final paired = matchNearestUnclaimed(
        sources: sorted
            .map((detected) => (x: detected.x, y: detected.y))
            .toList(growable: false),
        candidates: projected
            .map((star) => (x: star.x, y: star.y))
            .toList(growable: false),
        candidateKeys: projected.map((star) => star.id).toList(growable: false),
        maxDistance: maxMatchPx,
      );

      final matches = <_CatalogMatch>[];
      for (var i = 0; i < sorted.length; i++) {
        final index = paired[i];
        if (index == null) continue;
        final star = projected[index];
        matches.add(
          _CatalogMatch(
            detected: sorted[i],
            catalogX: star.x,
            catalogY: star.y,
            catalogMag: star.mag,
          ),
        );
      }
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

  /// Midpoint of the two frames' DATE-OBS values in UTC, or null when
  /// either is missing/unparseable.
  DateTime? _midpointEpochUtc(String? firstObs, String? lastObs) {
    final t0Utc = tryParseUtcTimestamp(firstObs);
    final t1Utc = tryParseUtcTimestamp(lastObs);
    if (t0Utc == null || t1Utc == null) return null;
    return t0Utc.add(
      Duration(milliseconds: t1Utc.difference(t0Utc).inMilliseconds ~/ 2),
    );
  }

  double _deltaMinutes(String? firstObs, String? lastObs, int frameCount) {
    final t0 = tryParseUtcTimestamp(firstObs);
    final t1 = tryParseUtcTimestamp(lastObs);
    if (t0 != null && t1 != null) {
      return math.max(
        1.0 / 60.0,
        t1.difference(t0).inMilliseconds.abs() / 60000.0,
      );
    }
    return math.max(1.0, (frameCount - 1).toDouble());
  }

  bool _mutualNearest(
    StarMeasurement first,
    StarMeasurement last,
    List<StarMeasurement> firstStars,
  ) {
    StarMeasurement? nearest;
    var best = double.infinity;
    for (final candidate in firstStars) {
      final dx = candidate.x - last.x;
      final dy = candidate.y - last.y;
      final d = math.sqrt(dx * dx + dy * dy);
      if (d < best) {
        best = d;
        nearest = candidate;
      }
    }
    return nearest == first;
  }

  List<double> _sigmaClip(
    List<double> values, {
    required double sigma,
    required int iterations,
  }) {
    var working = values.where((v) => v.isFinite).toList(growable: true);
    if (working.length < 3) return working;
    for (var i = 0; i < iterations; i++) {
      final med = _median(working);
      final mad = _mad(working, med);
      if (mad <= 0) break;
      final limit = sigma * 1.4826 * mad;
      final filtered = working
          .where((v) => (v - med).abs() <= limit)
          .toList(growable: true);
      if (filtered.length == working.length || filtered.length < 3) {
        working = filtered;
        break;
      }
      working = filtered;
    }
    return working;
  }

  double _robustMedian(List<double> values) {
    if (values.isEmpty) return 0.0;
    var working = values.where((v) => v.isFinite).toList(growable: true);
    if (working.isEmpty) return 0.0;
    for (var i = 0; i < 3; i++) {
      final med = _median(working);
      final mad = _mad(working, med);
      if (mad <= 0) return med;
      final limit = 3 * 1.4826 * mad;
      final filtered = working
          .where((v) => (v - med).abs() <= limit)
          .toList(growable: true);
      if (filtered.length == working.length || filtered.length < 8) {
        return _median(filtered);
      }
      working = filtered;
    }
    return _median(working);
  }

  double _trimmedMedian(List<double> values, double trimFraction) {
    final sorted = values.where((v) => v.isFinite).toList(growable: false)
      ..sort();
    if (sorted.isEmpty) return 0.0;
    final trim = (sorted.length * trimFraction).floor().clamp(
      0,
      sorted.length ~/ 3,
    );
    final start = trim;
    final end = sorted.length - trim;
    return _median(sorted.sublist(start, end <= start ? sorted.length : end));
  }

  double _median(List<double> values) {
    final sorted = values.where((v) => v.isFinite).toList(growable: false)
      ..sort();
    if (sorted.isEmpty) return 0.0;
    final m = sorted.length ~/ 2;
    return sorted.length.isOdd ? sorted[m] : (sorted[m - 1] + sorted[m]) / 2.0;
  }

  double _mad(List<double> values, double median) {
    if (values.isEmpty) return 0.0;
    return _median(
      values.map((v) => (v - median).abs()).toList(growable: false),
    );
  }

  double _robustStdDev(List<double> values) =>
      1.4826 * _mad(values, _median(values));

  _LinearFitResult? _weightedLinearFit({
    required List<double> x,
    required List<double> y,
    required List<double> weightBy,
  }) {
    if (x.length != y.length || x.length != weightBy.length || x.length < 2) {
      return null;
    }

    var sumW = 0.0;
    var sumX = 0.0;
    var sumY = 0.0;
    var sumXX = 0.0;
    var sumXY = 0.0;

    for (var i = 0; i < x.length; i++) {
      final xi = x[i];
      final yi = y[i];
      final wi = weightBy[i].clamp(1e-6, 1e6).toDouble();
      if (!xi.isFinite || !yi.isFinite || !wi.isFinite) {
        continue;
      }
      sumW += wi;
      sumX += wi * xi;
      sumY += wi * yi;
      sumXX += wi * xi * xi;
      sumXY += wi * xi * yi;
    }

    if (sumW <= 0.0) {
      return null;
    }

    final denominator = sumW * sumXX - sumX * sumX;
    if (denominator.abs() < 1e-12) {
      return null;
    }

    final slope = (sumW * sumXY - sumX * sumY) / denominator;
    final intercept = (sumY - slope * sumX) / sumW;

    var weightedResidual = 0.0;
    var residualWeight = 0.0;
    for (var i = 0; i < x.length; i++) {
      if (!x[i].isFinite || !y[i].isFinite) {
        continue;
      }
      final wi = weightBy[i].clamp(1e-6, 1e6).toDouble();
      final residual = y[i] - (intercept + slope * x[i]);
      weightedResidual += wi * residual * residual;
      residualWeight += wi;
    }
    final rms = residualWeight > 0
        ? math.sqrt(weightedResidual / residualWeight)
        : double.infinity;

    return _LinearFitResult(slope: slope, intercept: intercept, rms: rms);
  }

  double _percentile(List<double> values, double p) {
    final sorted = values.where((v) => v.isFinite).toList(growable: false)
      ..sort();
    if (sorted.isEmpty) return 0.0;
    final q = p.clamp(0.0, 1.0);
    final pos = (sorted.length - 1) * q;
    final lo = pos.floor();
    final hi = pos.ceil();
    if (lo == hi) return sorted[lo];
    final t = pos - lo;
    return sorted[lo] * (1 - t) + sorted[hi] * t;
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

  _QualityResult _computeQualityMetricsFromBuffer({
    required int width,
    required int height,
    required int gridRows,
    required int gridCols,
    required int lowClipAdu,
    required int highClipAdu,
    required DateTime timestamp,
    required int? capturedImageId,
    required int? sessionId,
    required String processingTier,
    required double Function(int index) sampleAt,
  }) {
    final rows = gridRows.clamp(2, 128);
    final cols = gridCols.clamp(2, 128);
    final tileMetrics = <ScienceTileMetric>[];
    final tileMedians = <double>[];
    final tileNoises = <double>[];
    final tileP05 = <double>[];
    final tileP95 = <double>[];
    final tileGradX = <double>[];
    final tileGradY = <double>[];

    var globalCount = 0;
    var globalSum = 0.0;
    var globalSumSq = 0.0;
    var globalLowClip = 0;
    var globalHighClip = 0;

    final imageMidX = width ~/ 2;
    final imageMidY = height ~/ 2;

    for (var row = 0; row < rows; row++) {
      final yStart = (row * height / rows).floor();
      final yEnd = ((row + 1) * height / rows).floor().clamp(
        yStart + 1,
        height,
      );
      for (var col = 0; col < cols; col++) {
        final xStart = (col * width / cols).floor();
        final xEnd = ((col + 1) * width / cols).floor().clamp(
          xStart + 1,
          width,
        );

        final samples = <double>[];
        var sum = 0.0;
        var sumSq = 0.0;
        var lowClip = 0;
        var highClip = 0;
        var leftSum = 0.0;
        var rightSum = 0.0;
        var topSum = 0.0;
        var bottomSum = 0.0;
        var leftCount = 0;
        var rightCount = 0;
        var topCount = 0;
        var bottomCount = 0;

        for (var y = yStart; y < yEnd; y++) {
          final isTop = y < imageMidY;
          for (var x = xStart; x < xEnd; x++) {
            final value = sampleAt(y * width + x);
            if (!value.isFinite) {
              continue;
            }
            samples.add(value);
            sum += value;
            sumSq += value * value;
            globalSum += value;
            globalSumSq += value * value;
            globalCount++;

            if (value <= lowClipAdu) {
              lowClip++;
              globalLowClip++;
            }
            if (value >= highClipAdu) {
              highClip++;
              globalHighClip++;
            }

            final isLeft = x < imageMidX;
            if (isLeft) {
              leftSum += value;
              leftCount++;
            } else {
              rightSum += value;
              rightCount++;
            }
            if (isTop) {
              topSum += value;
              topCount++;
            } else {
              bottomSum += value;
              bottomCount++;
            }
          }
        }

        if (samples.isEmpty) {
          continue;
        }

        samples.sort();
        final count = samples.length;
        final mean = sum / count;
        final variance = math.max(0.0, (sumSq / count) - (mean * mean));
        final stdDev = math.sqrt(variance);
        final p05 = _percentileSorted(samples, 0.05);
        final p50 = _percentileSorted(samples, 0.50);
        final p95 = _percentileSorted(samples, 0.95);
        final cv = mean.abs() < 1e-6 ? 0.0 : stdDev / mean.abs();
        final lowClipPercent = 100.0 * lowClip / count;
        final highClipPercent = 100.0 * highClip / count;
        final snr = stdDev <= 0.0 ? 0.0 : mean / stdDev;
        final gradX =
            ((rightCount == 0 ? mean : rightSum / rightCount) -
                    (leftCount == 0 ? mean : leftSum / leftCount))
                .toDouble();
        final gradY =
            ((bottomCount == 0 ? mean : bottomSum / bottomCount) -
                    (topCount == 0 ? mean : topSum / topCount))
                .toDouble();
        final gradMag = math.sqrt(gradX * gradX + gradY * gradY);

        tileMedians.add(p50);
        tileNoises.add(stdDev);
        tileP05.add(p05);
        tileP95.add(p95);
        tileGradX.add(gradX);
        tileGradY.add(gradY);

        tileMetrics.add(
          ScienceTileMetric(
            capturedImageId: capturedImageId,
            sessionId: sessionId,
            timestamp: timestamp,
            layerType: ScienceLayerType.uniformity,
            tileRow: row,
            tileCol: col,
            sampleCount: count,
            value: cv,
            p05: p05,
            p50: p50,
            p95: p95,
            auxValue: gradMag,
          ),
        );
        tileMetrics.add(
          ScienceTileMetric(
            capturedImageId: capturedImageId,
            sessionId: sessionId,
            timestamp: timestamp,
            layerType: ScienceLayerType.clipLow,
            tileRow: row,
            tileCol: col,
            sampleCount: count,
            value: lowClipPercent,
            p05: lowClipPercent,
            p50: lowClipPercent,
            p95: lowClipPercent,
            auxValue: lowClip.toDouble(),
          ),
        );
        tileMetrics.add(
          ScienceTileMetric(
            capturedImageId: capturedImageId,
            sessionId: sessionId,
            timestamp: timestamp,
            layerType: ScienceLayerType.clipHigh,
            tileRow: row,
            tileCol: col,
            sampleCount: count,
            value: highClipPercent,
            p05: highClipPercent,
            p50: highClipPercent,
            p95: highClipPercent,
            auxValue: highClip.toDouble(),
          ),
        );
        tileMetrics.add(
          ScienceTileMetric(
            capturedImageId: capturedImageId,
            sessionId: sessionId,
            timestamp: timestamp,
            layerType: ScienceLayerType.background,
            tileRow: row,
            tileCol: col,
            sampleCount: count,
            value: p50,
            p05: p05,
            p50: p50,
            p95: p95,
            auxValue: stdDev,
          ),
        );
        tileMetrics.add(
          ScienceTileMetric(
            capturedImageId: capturedImageId,
            sessionId: sessionId,
            timestamp: timestamp,
            layerType: ScienceLayerType.snr,
            tileRow: row,
            tileCol: col,
            sampleCount: count,
            value: snr,
            p05: 0.0,
            p50: snr,
            p95: snr,
            auxValue: stdDev,
          ),
        );
      }
    }

    final safeCount = math.max(1, globalCount);
    final globalMean = globalSum / safeCount;
    final globalStdDev = math.sqrt(
      math.max(0.0, (globalSumSq / safeCount) - (globalMean * globalMean)),
    );
    final median = tileMedians.isEmpty ? 0.0 : _median(tileMedians);
    final mad = tileMedians.isEmpty ? 0.0 : _mad(tileMedians, median);
    final background = tileMedians.isEmpty ? globalMean : _median(tileMedians);
    final noise = tileNoises.isEmpty ? globalStdDev : _median(tileNoises);
    final snr = noise <= 0.0 ? 0.0 : (globalMean / noise);
    final p1 = tileP05.isEmpty ? 0.0 : _percentile(tileP05, 0.2);
    final p99 = tileP95.isEmpty ? 0.0 : _percentile(tileP95, 0.8);
    final dynamicRange = math.max(0.0, p99 - p1);
    final gradientX = tileGradX.isEmpty
        ? 0.0
        : tileGradX.fold<double>(0.0, (sum, value) => sum + value) /
              tileGradX.length;
    final gradientY = tileGradY.isEmpty
        ? 0.0
        : tileGradY.fold<double>(0.0, (sum, value) => sum + value) /
              tileGradY.length;

    final frame = ScienceFrameQualityMetrics(
      capturedImageId: capturedImageId,
      sessionId: sessionId,
      timestamp: timestamp,
      median: median,
      mean: globalMean,
      stdDev: globalStdDev,
      mad: mad,
      background: background,
      noise: noise,
      snr: snr,
      dynamicRangeP1P99: dynamicRange,
      lowClipPercent: 100.0 * globalLowClip / safeCount,
      highClipPercent: 100.0 * globalHighClip / safeCount,
      uniformityCv: background.abs() < 1e-6
          ? 0.0
          : globalStdDev / background.abs(),
      gradientX: gradientX,
      gradientY: gradientY,
      processingTier: processingTier,
      processingMs: 0,
    );
    return _QualityResult(frame: frame, tiles: tileMetrics);
  }

  double _percentileSorted(List<double> sortedValues, double p) {
    if (sortedValues.isEmpty) {
      return 0.0;
    }
    final q = p.clamp(0.0, 1.0);
    final pos = (sortedValues.length - 1) * q;
    final lo = pos.floor();
    final hi = pos.ceil();
    if (lo == hi) {
      return sortedValues[lo];
    }
    final t = pos - lo;
    return sortedValues[lo] * (1 - t) + sortedValues[hi] * t;
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

  /// Require valid FITS exposure metadata for physically meaningful
  /// line-ratio normalization.
  double _requireExposureTime({
    required String label,
    required double? exposureTime,
    required String filePath,
  }) {
    if (exposureTime != null && exposureTime.isFinite && exposureTime > 0) {
      return exposureTime.clamp(0.001, double.infinity);
    }
    throw StateError(
      'Missing exposure metadata for $label frame: $filePath. '
      'Line-ratio normalization requires a valid FITS exposure time.',
    );
  }

  /// Returns the camera read-noise setting in electrons.
  /// Null means the value is unavailable/invalid and dependent metrics
  /// should be omitted instead of guessed.
  Future<double?> _readNoiseEstimate() async {
    try {
      final dao = _ref.read(settingsDaoProvider);
      final stored = await dao.getSetting('science.camera.read_noise_e');
      if (stored != null && stored.isNotEmpty) {
        final parsed = double.tryParse(stored);
        if (parsed != null && parsed.isFinite && parsed > 0) {
          return parsed.clamp(0.5, 30.0);
        }
        _logger.warning(
          'Invalid science.camera.read_noise_e setting "$stored"; limiting magnitude will be omitted.',
          source: 'ScienceBackend',
        );
      } else {
        _logger.warning(
          'science.camera.read_noise_e is not configured; limiting magnitude will be omitted.',
          source: 'ScienceBackend',
        );
      }
    } catch (error, stack) {
      _logger.warning(
        'Failed to read science.camera.read_noise_e; limiting magnitude will be omitted: $error\n$stack',
        source: 'ScienceBackend',
      );
    }
    return null;
  }

  /// Returns the camera gain setting in electrons per ADU, or null when
  /// not configured / invalid. Callers fall back to 1 e⁻/ADU and say so.
  Future<double?> _gainElectronsPerAdu() async {
    try {
      final dao = _ref.read(settingsDaoProvider);
      final stored = await dao.getSetting('science.camera.gain_e_per_adu');
      if (stored != null && stored.isNotEmpty) {
        final parsed = double.tryParse(stored);
        if (parsed != null && parsed.isFinite && parsed > 0) {
          return parsed.clamp(0.01, 50.0);
        }
        _logger.warning(
          'Invalid science.camera.gain_e_per_adu setting "$stored"; assuming 1 e-/ADU.',
          source: 'ScienceBackend',
        );
      }
    } catch (error, stack) {
      _logger.warning(
        'Failed to read science.camera.gain_e_per_adu; assuming 1 e-/ADU: $error\n$stack',
        source: 'ScienceBackend',
      );
    }
    return null;
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
