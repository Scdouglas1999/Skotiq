part of '../default_science_backend.dart';

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
  return _median(values.map((v) => (v - median).abs()).toList(growable: false));
}

double _robustStdDev(List<double> values) =>
    1.4826 * _mad(values, _median(values));

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
    final yEnd = ((row + 1) * height / rows).floor().clamp(yStart + 1, height);
    for (var col = 0; col < cols; col++) {
      final xStart = (col * width / cols).floor();
      final xEnd = ((col + 1) * width / cols).floor().clamp(xStart + 1, width);

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

Future<_QualityResult> _qualityInBackground({
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
  required List<num> pixels,
}) => Isolate.run(
  () => _computeQualityMetricsFromBuffer(
    width: width,
    height: height,
    gridRows: gridRows,
    gridCols: gridCols,
    lowClipAdu: lowClipAdu,
    highClipAdu: highClipAdu,
    timestamp: timestamp,
    capturedImageId: capturedImageId,
    sessionId: sessionId,
    processingTier: processingTier,
    sampleAt: (index) => pixels[index].toDouble(),
  ),
);

// Keep worker closures outside the backend so they cannot capture Riverpod
// state, native handles, or other objects belonging to the UI isolate.
Future<LineRatioProduct> _lineRatiosInBackground(
  NarrowbandSet set,
  LineRatioOptions options,
  FitsLinearReadResult ha,
  FitsLinearReadResult oiii,
  FitsLinearReadResult sii,
) => Isolate.run(() {
  // WHY: writing fake-zero ratios into line_ratio_products would corrupt
  // BPT diagrams and any downstream classification. Throw a structured
  // error so the UI/handler renders an explicit error tile and the row is
  // never inserted.
  final dimsOk =
      ha.width == oiii.width &&
      ha.width == sii.width &&
      ha.height == oiii.height &&
      ha.height == sii.height;
  if (options.requireMatchingDimensions && !dimsOk) {
    throw LineRatioError(
      code: LineRatioErrorCode.dimensionMismatch,
      message:
          'Narrowband frame dimensions differ: '
          'Ha=${ha.width}x${ha.height} OIII=${oiii.width}x${oiii.height} '
          'SII=${sii.width}x${sii.height}.',
    );
  }
  final len = math.min(
    ha.linearData.length,
    math.min(oiii.linearData.length, sii.linearData.length),
  );
  if (len <= 0) {
    throw LineRatioError(
      code: LineRatioErrorCode.emptyPixelData,
      message:
          'Narrowband frame has no usable pixel data: '
          'Ha=${ha.linearData.length} OIII=${oiii.linearData.length} '
          'SII=${sii.linearData.length}.',
    );
  }

  final stride = math.max(1, len ~/ 220000);
  final haRawSamples = <double>[];
  final oiiiRawSamples = <double>[];
  final siiRawSamples = <double>[];
  for (var i = 0; i < len; i += stride) {
    haRawSamples.add(ha.linearData[i]);
    oiiiRawSamples.add(oiii.linearData[i]);
    siiRawSamples.add(sii.linearData[i]);
  }

  final haBackground = _percentile(haRawSamples, 0.2);
  final oiiiBackground = _percentile(oiiiRawSamples, 0.2);
  final siiBackground = _percentile(siiRawSamples, 0.2);
  final haNoise = _robustStdDev(
    haRawSamples.map((value) => value - haBackground).toList(growable: false),
  ).clamp(1e-6, double.infinity);
  final oiiiNoise = _robustStdDev(
    oiiiRawSamples
        .map((value) => value - oiiiBackground)
        .toList(growable: false),
  ).clamp(1e-6, double.infinity);
  final siiNoise = _robustStdDev(
    siiRawSamples.map((value) => value - siiBackground).toList(growable: false),
  ).clamp(1e-6, double.infinity);

  final haSamples = <double>[];
  final oiiiSamples = <double>[];
  final siiSamples = <double>[];
  final siiHa = <double>[];
  final oiiiHa = <double>[];
  final siiOiii = <double>[];
  final haExp = _requireExposureTime(
    label: 'H-alpha',
    exposureTime: ha.exposureTime,
    filePath: set.hAlphaPath,
  );
  final oiiiExp = _requireExposureTime(
    label: 'OIII',
    exposureTime: oiii.exposureTime,
    filePath: set.oiiiPath,
  );
  final siiExp = _requireExposureTime(
    label: 'SII',
    exposureTime: sii.exposureTime,
    filePath: set.siiPath,
  );
  final haThreshold = options.snrFloor * haNoise / haExp;
  final oiiiThreshold = options.snrFloor * oiiiNoise / oiiiExp;
  final siiThreshold = options.snrFloor * siiNoise / siiExp;

  for (var i = 0; i < len; i += stride) {
    var h =
        ((ha.linearData[i] - haBackground).clamp(0.0, double.infinity)) / haExp;
    var o =
        ((oiii.linearData[i] - oiiiBackground).clamp(0.0, double.infinity)) /
        oiiiExp;
    var s =
        ((sii.linearData[i] - siiBackground).clamp(0.0, double.infinity)) /
        siiExp;
    if (options.continuumCorrection) {
      final c = math.min(h, math.min(o, s)) * 0.2;
      h = (h - c).clamp(0.0, double.infinity);
      o = (o - c).clamp(0.0, double.infinity);
      s = (s - c).clamp(0.0, double.infinity);
    }
    haSamples.add(h);
    oiiiSamples.add(o);
    siiSamples.add(s);
    if (h > haThreshold && s > siiThreshold) {
      siiHa.add(s / h);
    }
    if (h > haThreshold && o > oiiiThreshold) {
      oiiiHa.add(o / h);
    }
    if (o > oiiiThreshold && s > siiThreshold) {
      siiOiii.add(s / o);
    }
  }

  final previewStrideX = math.max(1, ha.width ~/ 512);
  final previewStrideY = math.max(1, ha.height ~/ 512);
  final previewWidth = (ha.width / previewStrideX).floor();
  final previewHeight = (ha.height / previewStrideY).floor();
  final preview = Uint8List(previewWidth * previewHeight * 4);
  final hn = _percentile(haSamples, 0.99).clamp(1e-6, double.infinity);
  final on = _percentile(oiiiSamples, 0.99).clamp(1e-6, double.infinity);
  final sn = _percentile(siiSamples, 0.99).clamp(1e-6, double.infinity);

  var previewOffset = 0;
  for (var y = 0; y < previewHeight; y++) {
    final srcY = y * previewStrideY;
    for (var x = 0; x < previewWidth; x++) {
      final srcX = x * previewStrideX;
      final index = srcY * ha.width + srcX;
      if (index >= len) {
        preview[previewOffset] = 0;
        preview[previewOffset + 1] = 0;
        preview[previewOffset + 2] = 0;
        preview[previewOffset + 3] = 255;
        previewOffset += 4;
        continue;
      }
      final h =
          ((ha.linearData[index] - haBackground).clamp(0.0, double.infinity)) /
          haExp;
      final o =
          ((oiii.linearData[index] - oiiiBackground).clamp(
            0.0,
            double.infinity,
          )) /
          oiiiExp;
      final s =
          ((sii.linearData[index] - siiBackground).clamp(
            0.0,
            double.infinity,
          )) /
          siiExp;
      preview[previewOffset] = ((h / hn).clamp(0.0, 1.0) * 255).round();
      preview[previewOffset + 1] = ((o / on).clamp(0.0, 1.0) * 255).round();
      preview[previewOffset + 2] = ((s / sn).clamp(0.0, 1.0) * 255).round();
      preview[previewOffset + 3] = 255;
      previewOffset += 4;
    }
  }

  return LineRatioProduct(
    createdAt: DateTime.now(),
    previewImage: preview,
    metrics: [
      LineRatioMetric(label: 'SII/Ha', value: _robustMedian(siiHa)),
      LineRatioMetric(label: 'OIII/Ha', value: _robustMedian(oiiiHa)),
      LineRatioMetric(label: 'SII/OIII', value: _robustMedian(siiOiii)),
    ],
  );
});

Future<List<_CatalogMatch>?> _matchCatalogInBackground(
  GnomonicProjection projection,
  List<PhotometricCatalogStar> catalogStars,
  List<StarMeasurement> detectedStars,
  double maxMatchPx,
) => Isolate.run(() {
  final projected = <_ProjectedCatalogStar>[];
  for (final star in catalogStars) {
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
        star: star,
      ),
    );
  }
  if (projected.isEmpty) return null;

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
        catalogStar: star.star,
      ),
    );
  }
  return matches;
});
