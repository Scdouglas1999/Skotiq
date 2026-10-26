import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart';

import '../../backend/skotiq_backend.dart';
import '../../models/plate_solver.dart';
import '../../models/science/science_models.dart';
import '../wcs/gnomonic_projection.dart';
import '../../providers/backend_provider.dart';
import '../../providers/database_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/logging_service.dart';
import '../plate_solve_service.dart';
import '../../utils/utc_timestamp.dart';
import 'nearest_neighbour_matching.dart';
import 'photometric_catalog_service.dart';
import 'science_backend.dart';

part 'default_science_backend/helpers.dart';
part 'default_science_backend/value_types.dart';

class DefaultScienceBackend implements ScienceBackend {
  final Ref _ref;

  DefaultScienceBackend(this._ref);

  ImagingBackend get _backend => _ref.read(imagingBackendProvider);
  LoggingService get _logger => _ref.read(loggingServiceProvider);

  @override
  Future<SolverCapabilities> getSolverCapabilities() async {
    final solver = await _resolveSolver();
    if (!solver.available) return const SolverCapabilities();
    // ASTAP and astrometry.net expose the same capability set, so Auto —
    // which may dispatch to either — carries it too.
    return const SolverCapabilities(
      hasResidualVectors: true,
      hasDistortionTerms: true,
      supportsBatchSolve: true,
      supportsLocalIndexOnly: true,
    );
  }

  @override
  Future<WcsSolution?> solveForScience(
    String imagePath,
    SolveOptions options,
  ) async {
    try {
      final settings = _ref.read(appSettingsProvider).valueOrNull;
      final forceBlind = settings?.blindSolve ?? false;
      final result = await _backend.plateSolve(
        imagePath: imagePath,
        // Science models expose RA in hours; the imaging backend boundary is
        // explicitly degrees in both local FFI and remote transports.
        ra: forceBlind || options.raHintHours == null
            ? null
            : options.raHintHours! * 15.0,
        dec: forceBlind ? null : options.decHintDegrees,
        fovDegrees: options.searchRadiusDegrees,
        timeoutSeconds: settings?.plateSolveTimeout,
      );
      if (!result.success) return null;
      return WcsSolution(
        raHours: result.ra / 15.0,
        decDegrees: result.dec,
        pixelScaleArcsecPerPixel: result.pixelScale,
        rotationDegrees: result.rotation,
        fieldWidthDegrees: result.fieldWidth,
        fieldHeightDegrees: result.fieldHeight,
        solverId: (await _resolveSolver()).label,
        cd1_1: result.cd11,
        cd1_2: result.cd12,
        cd2_1: result.cd21,
        cd2_2: result.cd22,
        aOrder: result.sipAOrder,
        bOrder: result.sipBOrder,
        aCoeffs: result.sipACoeffs.toList(),
        bCoeffs: result.sipBCoeffs.toList(),
        apOrder: result.sipApOrder,
        bpOrder: result.sipBpOrder,
        apCoeffs: result.sipApCoeffs.toList(),
        bpCoeffs: result.sipBpCoeffs.toList(),
      );
    } catch (error, stack) {
      _logger.warning(
        'Science solve failed for $imagePath: $error\n$stack',
        source: 'ScienceBackend',
      );
      return null;
    }
  }

  @override
  Future<List<StarMeasurement>> measureStars(
    String imagePath,
    PhotometryOptions options,
  ) async {
    try {
      final config = StarDetectionConfigApi(
        detectionSigma: 4.0,
        minArea: 4,
        maxArea: 1024,
        maxEccentricity: 0.95,
        saturationLimit: await _saturationLimitAdu(),
        hfrRadius: math.max(options.apertureRadiusPixels, 4),
        minHfr: 0.6,
        minSnr: options.minSnr,
        maxSharpness: 100.0,
      );
      final result = await apiDetectStarsInFile(
        filePath: imagePath,
        config: config,
      );
      return result.stars
          .where(
            (s) =>
                s.snr >= options.minSnr &&
                s.flux > 0 &&
                s.fwhm > 0 &&
                s.hfr > 0,
          )
          .map(
            (s) => StarMeasurement(
              x: s.x,
              y: s.y,
              flux: s.flux,
              hfr: s.hfr,
              fwhm: s.fwhm,
              snr: s.snr,
              eccentricity: s.eccentricity,
              sharpness: s.sharpness,
              background: s.background,
              peak: s.peak,
            ),
          )
          .toList(growable: false);
    } catch (error, stack) {
      _logger.warning(
        'Star measurement failed for $imagePath: $error\n$stack',
        source: 'ScienceBackend',
      );
      return const [];
    }
  }

  @override
  Future<FramePhotometricCalibration?> calibrateFramePhotometry(
    String imagePath,
    WcsSolution wcs,
    PhotometricCatalogSource catalog,
    ScienceFrameContext? frameContext,
  ) async {
    final context = frameContext;
    if (context == null) {
      _logger.warning(
        'Photometric calibration skipped for $imagePath: missing frame context (timestamp/exposure metadata unavailable).',
        source: 'ScienceBackend',
      );
      return null;
    }
    final timestamp = context.capturedAt;
    final rawExposureSeconds = context.exposureSeconds;
    if (!rawExposureSeconds.isFinite || rawExposureSeconds <= 0) {
      _logger.warning(
        'Photometric calibration skipped for $imagePath: invalid exposureSeconds=${context.exposureSeconds}.',
        source: 'ScienceBackend',
      );
      return null;
    }
    final exposureSeconds = rawExposureSeconds.clamp(0.001, double.infinity);

    final stars = await measureStars(
      imagePath,
      const PhotometryOptions(minSnr: 5.0),
    );
    // WHY: writing a sentinel-RMS isCalibrated:false row would let downstream
    // aggregations (transparency confidence, observation reports) treat the
    // row as data. Returning null instead means no DB row is inserted —
    // "not calibrated" is encoded by absence, not by a fabricated metric.
    if (stars.length < 8) {
      return null;
    }

    // V≤15 reaches the depth APASS actually provides; the HYG fallback
    // simply has nothing fainter than ~9, so a deeper request costs nothing.
    final (matches, matchedCatalog) = await _catalogMatches(
      imagePath: imagePath,
      wcs: wcs,
      detectedStars: stars,
      maxCatalogMag: 15.0,
      maxMatchPx: 9.0,
    );
    if (matches.length < 8) {
      return null;
    }

    final zpSamples = matches
        .map((m) {
          final normalizedFlux = (m.detected.flux / exposureSeconds).clamp(
            1e-9,
            double.infinity,
          );
          return m.catalogMag + 2.5 * math.log(normalizedFlux) / math.ln10;
        })
        .where((v) => v.isFinite)
        .toList(growable: false);
    final clipped = _sigmaClip(zpSamples, sigma: 2.8, iterations: 4);
    if (clipped.length < 6) {
      return null;
    }

    final zeroPoint = _median(clipped);
    final rms = math.sqrt(
      clipped.map((v) => v - zeroPoint).fold<double>(0, (s, d) => s + d * d) /
          clipped.length,
    );
    // WHY: a non-finite zero-point or RMS means the fit is structurally
    // broken (e.g. all magnitudes collapsed to the same value, or one slipped
    // through the isFinite filter). Surface this as an error
    // rather than persisting a poisoned calibration row.
    if (!zeroPoint.isFinite || !rms.isFinite) {
      throw ScienceCalibrationError(
        code: ScienceCalibrationErrorCode.fitFailed,
        message:
            'Photometric fit produced non-finite zero-point=$zeroPoint rms=$rms '
            'for $imagePath (matched=${matches.length} clipped=${clipped.length}).',
      );
    }

    final bg = _median(
      stars
          .map((s) => s.background)
          .where((v) => v.isFinite && v >= 0)
          .toList(growable: false),
    );
    final fwhmEstimate = _median(
      stars
          .map((s) => s.fwhm)
          .where((v) => v.isFinite && v > 0.0)
          .toList(growable: false),
    );
    final apertureRadius = fwhmEstimate > 0
        ? (1.35 * fwhmEstimate).clamp(3.5, 10.0).toDouble()
        : 6.0;
    final aperturePixels = math.pi * apertureRadius * apertureRadius;
    final readNoise = await _readNoiseEstimate();
    double? lim5;
    double? lim3;
    if (readNoise != null) {
      // Photon statistics live in electrons, while the background and the
      // fitted zero point are in ADU. Convert via the configured gain:
      //   variance_e  = npix · (bg_adu·g + rn_e²)
      //   sigma_adu   = sqrt(variance_e) / g
      // With no gain configured we assume 1 e⁻/ADU, which understates the
      // sky-noise term for high-gain CMOS settings (g < 1) — say so rather
      // than silently producing an optimistic limit.
      final gain = await _gainElectronsPerAdu();
      if (gain == null) {
        _logger.warning(
          'science.camera.gain_e_per_adu is not configured; limiting '
          'magnitude assumes 1 e-/ADU.',
          source: 'ScienceBackend',
        );
      }
      final g = gain ?? 1.0;
      final noiseAdu =
          (math.sqrt(aperturePixels * (bg * g + readNoise * readNoise)) / g)
              .clamp(1e-6, double.infinity);
      lim5 =
          zeroPoint -
          2.5 * math.log((5.0 * noiseAdu) / exposureSeconds) / math.ln10;
      lim3 =
          zeroPoint -
          2.5 * math.log((3.0 * noiseAdu) / exposureSeconds) / math.ln10;
    } else {
      _logger.warning(
        'Limiting magnitude omitted for $imagePath: camera read noise is not configured.',
        source: 'ScienceBackend',
      );
    }

    return FramePhotometricCalibration(
      capturedImageId: context.capturedImageId,
      sessionId: context.sessionId,
      timestamp: timestamp,
      airmass: context.airmass,
      exposureSeconds: exposureSeconds,
      isCalibrated: true,
      zeroPoint: zeroPoint,
      limitingMag3Sigma: lim3,
      limitingMag5Sigma: lim5,
      matchedStarCount: clipped.length,
      // WHY: do NOT cap RMS at a sentinel ceiling — that would hide poor fits
      // from observation-report aggregates and the science insights panel.
      // High RMS is real data; downstream code already thresholds at 0.2.
      calibrationRms: rms,
      solverId: wcs.solverId,
      // Resolve the `auto` request to the catalog _catalogMatches actually
      // served the fit from (APASS online/cache, or the bundled HYG
      // fallback) so the persisted row and the MAGZPSRC FITS keyword
      // record real provenance.
      catalogSource: catalog == PhotometricCatalogSource.auto
          ? matchedCatalog
          : catalog,
    );
  }

  @override
  Future<TransparencySample?> estimateTransparency(
    List<FramePhotometricCalibration> recentCalibrations,
    TransparencyOptions options,
  ) async {
    final calibrations =
        recentCalibrations
            .where(
              (c) =>
                  c.isCalibrated &&
                  c.zeroPoint != null &&
                  c.zeroPoint!.isFinite,
            )
            .toList(growable: false)
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (calibrations.length < options.minimumSampleCount) return null;

    final window = calibrations.length > options.rollingWindowSize
        ? calibrations.sublist(calibrations.length - options.rollingWindowSize)
        : calibrations;
    if (window.length < options.minimumSampleCount) return null;

    final withAirmass = window
        .where((c) => c.airmass != null && c.airmass!.isFinite)
        .toList(growable: false);
    // Leave-one-out needs one additional sample beyond the minimum,
    // because the latest sample is held out from the fit.
    final useAirmassFit = withAirmass.length >= options.minimumSampleCount + 1;

    double transparency = 100.0;
    double extinction = 0.0;
    double confidence = 0.0;
    var extinctionFromAirmassFit = false;

    if (useAirmassFit) {
      // Leave-one-out: fit the airmass model on all samples EXCEPT
      // the latest, then evaluate the residual of the held-out last
      // point.  This avoids the self-inclusion bias that would
      // suppress the residual and hide real transparency changes.
      final fitData = withAirmass.sublist(0, withAirmass.length - 1);
      final x = fitData.map((c) => c.airmass!).toList(growable: false);
      final y = fitData.map((c) => c.zeroPoint!).toList(growable: false);
      final allZps = withAirmass
          .map((c) => c.zeroPoint!)
          .toList(growable: false);
      final yScatter = _robustStdDev(allZps);
      final span = (x.reduce(math.max) - x.reduce(math.min)).abs();
      if (span < options.minAirmassSpan) {
        return null;
      }

      final fit = _weightedLinearFit(
        x: x,
        y: y,
        weightBy: fitData
            .map((c) => 1.0 / math.max(0.03, c.calibrationRms))
            .toList(growable: false),
      );
      if (fit == null) {
        return null;
      }

      final slope = fit.slope;
      final intercept = fit.intercept;
      extinction = math.max(0.0, -slope);
      extinctionFromAirmassFit = true;

      // Transparency = how much the ACTUAL latest ZP deviates from what
      // the airmass model PREDICTS.  A clear sky gives residual ≈ 0 →
      // transparency ≈ 100%, regardless of airmass.  Clouds / haze push
      // the actual ZP below the prediction → transparency < 100%.
      final currentAirmass = withAirmass.last.airmass!.clamp(1.0, 5.0);
      final predictedZp = intercept + slope * currentAirmass;
      final actualZp = withAirmass.last.zeroPoint!;
      final residualMag =
          predictedZp - actualZp; // positive ⇒ dimmer than expected
      transparency = (math.pow(10.0, -0.4 * residualMag) * 100.0)
          .clamp(0.0, 100.0)
          .toDouble();

      final sampleFactor = (withAirmass.length / options.rollingWindowSize)
          .clamp(0.25, 1.0);
      final fitPenalty = math.exp(-(fit.rms / 0.12).clamp(0.0, 4.0));
      final scatterPenalty = math.exp(-(yScatter / 0.2).clamp(0.0, 4.0));
      confidence = (sampleFactor * fitPenalty * scatterPenalty)
          .clamp(0.1, 1.0)
          .toDouble();
    } else {
      final zps = window.map((c) => c.zeroPoint!).toList(growable: false);
      final baseline = _percentile(zps, 0.9);
      final current = window.last.zeroPoint!;
      final deltaMag = baseline - current;
      transparency = (math.pow(10.0, -0.4 * deltaMag) * 100.0)
          .clamp(0.0, 100.0)
          .toDouble();
      // Warm-up fallback: this is a zero-point depression vs the session
      // baseline in magnitudes, NOT mag/airmass — flagged via
      // extinctionFromAirmassFit=false so unit-bearing consumers skip it.
      extinction = math.max(0.0, deltaMag);

      final scatter = _robustStdDev(zps);
      final sampleFactor = (window.length / options.rollingWindowSize)
          .clamp(0.2, 1.0)
          .toDouble();
      final stabilityPenalty = math.exp(-(scatter / 0.25).clamp(0.0, 4.0));
      confidence = (sampleFactor * stabilityPenalty)
          .clamp(0.15, 1.0)
          .toDouble();
    }

    final quality = transparency >= 95
        ? 'Excellent'
        : transparency >= 85
        ? 'Good'
        : transparency >= 70
        ? 'Fair'
        : 'Poor';

    return TransparencySample(
      capturedImageId: window.last.capturedImageId,
      sessionId: window.last.sessionId,
      timestamp: window.last.timestamp,
      transparencyPercent: transparency,
      extinctionCoefficient: extinction,
      qualityBucket: quality,
      confidence: confidence,
      extinctionFromAirmassFit: extinctionFromAirmassFit,
    );
  }

  @override
  Future<PsfFieldMap> buildPsfFieldMap(
    String imagePath,
    WcsSolution? wcs,
    PsfMapOptions options,
  ) async {
    final stars = await measureStars(
      imagePath,
      const PhotometryOptions(minSnr: 4.0),
    );
    final saturationAdu = await _saturationLimitAdu();
    final usable = stars
        .where(
          (s) =>
              s.snr >= 4 &&
              s.eccentricity <= 0.98 &&
              s.fwhm.isFinite &&
              s.hfr.isFinite &&
              s.peak < saturationAdu,
        )
        .toList(growable: false);
    if (usable.isEmpty) {
      return PsfFieldMap(
        gridRows: options.gridRows,
        gridCols: options.gridCols,
        tiles: const [],
      );
    }

    final fits = await apiReadFitsFile(filePath: imagePath);
    final tileW = fits.width / options.gridCols;
    final tileH = fits.height / options.gridRows;
    final buckets = <(int, int), List<StarMeasurement>>{};
    for (final star in usable) {
      final col = (star.x / tileW).floor().clamp(0, options.gridCols - 1);
      final row = (star.y / tileH).floor().clamp(0, options.gridRows - 1);
      buckets.putIfAbsent((row, col), () => <StarMeasurement>[]).add(star);
    }

    final tiles = <PsfTileMetric>[];
    for (var row = 0; row < options.gridRows; row++) {
      for (var col = 0; col < options.gridCols; col++) {
        final bucket = buckets[(row, col)] ?? const <StarMeasurement>[];
        if (bucket.isEmpty) {
          tiles.add(
            PsfTileMetric(
              row: row,
              col: col,
              starCount: 0,
              medianFwhm: 0,
              medianHfr: 0,
              medianEccentricity: 0,
              roundness: 0,
            ),
          );
          continue;
        }
        final fwhm = _trimmedMedian(bucket.map((s) => s.fwhm).toList(), 0.15);
        final hfr = _trimmedMedian(bucket.map((s) => s.hfr).toList(), 0.15);
        final ecc = _trimmedMedian(
          bucket.map((s) => s.eccentricity).toList(),
          0.15,
        );
        tiles.add(
          PsfTileMetric(
            row: row,
            col: col,
            starCount: bucket.length,
            medianFwhm: fwhm,
            medianHfr: hfr,
            medianEccentricity: ecc,
            roundness: (1.0 - ecc).clamp(0.0, 1.0),
          ),
        );
      }
    }
    return PsfFieldMap(
      gridRows: options.gridRows,
      gridCols: options.gridCols,
      tiles: tiles,
    );
  }

  @override
  Future<AstrometricResidualMap?> computeAstrometricResiduals(
    String imagePath,
    WcsSolution wcs,
    AstrometryOptions options,
  ) async {
    final stars = await measureStars(
      imagePath,
      const PhotometryOptions(minSnr: 4.0),
    );
    if (stars.isEmpty) return null;
    final (matches, _) = await _catalogMatches(
      imagePath: imagePath,
      wcs: wcs,
      detectedStars: stars,
      maxCatalogMag: 15.0,
      maxMatchPx: 10.0,
    );
    if (matches.length < 6) return null;

    final scale = wcs.pixelScaleArcsecPerPixel;
    final vectors = matches
        .take(options.sampleCount)
        .map((m) {
          final dx = (m.detected.x - m.catalogX) * scale;
          final dy = (m.detected.y - m.catalogY) * scale;
          return ResidualVectorSample(
            x: m.detected.x,
            y: m.detected.y,
            dxArcsec: dx,
            dyArcsec: dy,
            magnitudeArcsec: math.sqrt(dx * dx + dy * dy),
          );
        })
        .toList(growable: false);
    if (vectors.isEmpty) return null;

    final rms = math.sqrt(
      vectors.fold<double>(
            0.0,
            (s, v) => s + v.magnitudeArcsec * v.magnitudeArcsec,
          ) /
          vectors.length,
    );
    final meanX =
        vectors.fold<double>(0.0, (s, v) => s + v.dxArcsec) / vectors.length;
    final meanY =
        vectors.fold<double>(0.0, (s, v) => s + v.dyArcsec) / vectors.length;
    final suggestion = rms > 2.0
        ? 'check_polar_alignment'
        : meanX.abs() > 0.5 && meanY.abs() > 0.5
        ? 'possible_field_rotation'
        : meanX.abs() > 0.5
        ? 'possible_cone_error'
        : meanY.abs() > 0.5
        ? 'possible_flexure'
        : null;
    return AstrometricResidualMap(
      vectors: vectors,
      rmsArcsec: rms,
      suggestionCode: suggestion,
    );
  }

  @override
  Future<List<MovingObjectMatch>> detectMovingObjects(
    List<String> imagePaths,
    WcsSolution wcs,
    MovingObjectOptions options,
  ) async {
    if (imagePaths.length < 2) return const [];
    final firstPath = imagePaths.first;
    final lastPath = imagePaths.last;
    final first = await measureStars(
      firstPath,
      const PhotometryOptions(minSnr: 5.0),
    );
    final last = await measureStars(
      lastPath,
      const PhotometryOptions(minSnr: 5.0),
    );
    if (first.isEmpty || last.isEmpty) return const [];

    final firstFits = await apiReadFitsFile(filePath: firstPath);
    final lastFits = await apiReadFitsFile(filePath: lastPath);
    final dtMin = _deltaMinutes(
      firstFits.dateObs,
      lastFits.dateObs,
      imagePaths.length,
    );
    // The candidate position below is the midpoint between the first and
    // last detections, so its astrometric epoch is the midpoint of the two
    // frame times — not "now" and not the triggering frame's timestamp.
    final epochUtc = _midpointEpochUtc(firstFits.dateObs, lastFits.dateObs);

    final projection = _projectionFor(
      wcs,
      imageWidth: firstFits.width,
      imageHeight: firstFits.height,
    );
    if (projection == null) {
      _logger.warning(
        'Moving-object detection skipped: WCS/image geometry is not '
        'projectable (scale=${wcs.pixelScaleArcsecPerPixel}, '
        'dims=${firstFits.width}x${firstFits.height}).',
        source: 'ScienceBackend',
      );
      return const [];
    }

    // When 3+ frames are available, measure the middle frame for linear
    // motion validation — a candidate must also appear near the
    // interpolated position in this frame.
    final midIndex = imagePaths.length ~/ 2;
    final bool hasMiddleFrame =
        imagePaths.length >= 3 &&
        midIndex > 0 &&
        midIndex < imagePaths.length - 1;
    List<StarMeasurement>? midStars;
    double midFraction = 0.5; // interpolation factor (0 = first, 1 = last)
    if (hasMiddleFrame) {
      midStars = await measureStars(
        imagePaths[midIndex],
        const PhotometryOptions(minSnr: 5.0),
      );
      midFraction = midIndex / (imagePaths.length - 1);
    }

    // Maximum deviation from linear interpolation allowed in the middle
    // frame, in pixels.  Generous enough for slight dithering / guiding
    // drift but tight enough to reject random coincidences.
    const midMatchTolerance = 4.0;

    final usedLast = <int>{};
    final matches = <MovingObjectMatch>[];
    final firstSorted = first.toList(growable: false)
      ..sort((a, b) => b.snr.compareTo(a.snr));
    for (final star in firstSorted.take(280)) {
      var bestIndex = -1;
      var bestDist = double.infinity;
      for (var i = 0; i < last.length; i++) {
        if (usedLast.contains(i)) continue;
        final dx = last[i].x - star.x;
        final dy = last[i].y - star.y;
        final dist = math.sqrt(dx * dx + dy * dy);
        if (dist < bestDist) {
          bestDist = dist;
          bestIndex = i;
        }
      }
      if (bestIndex < 0 ||
          bestDist < options.minMotionPixels ||
          bestDist > options.maxMotionPixels) {
        continue;
      }
      final matched = last[bestIndex];
      if (!_mutualNearest(star, matched, firstSorted)) continue;

      // 3-frame linear motion validation: predict where the object
      // should be in the middle frame and check for a nearby detection.
      var passedMiddleValidation = false;
      if (midStars != null && midStars.isNotEmpty) {
        final expectedX = star.x + (matched.x - star.x) * midFraction;
        final expectedY = star.y + (matched.y - star.y) * midFraction;
        var foundMid = false;
        for (final midStar in midStars) {
          final mdx = midStar.x - expectedX;
          final mdy = midStar.y - expectedY;
          if (math.sqrt(mdx * mdx + mdy * mdy) <= midMatchTolerance) {
            foundMid = true;
            break;
          }
        }
        if (!foundMid) continue;
        passedMiddleValidation = true;
      }

      usedLast.add(bestIndex);

      final dxPx = matched.x - star.x;
      final dyPx = matched.y - star.y;
      // Through the frame's own WCS, so the angle carries its parity; a
      // scalar rotation cannot tell a mirrored frame from a normal one.
      final startSky = projection.pixelToWorld(x: star.x, y: star.y);
      final endSky = projection.pixelToWorld(x: matched.x, y: matched.y);
      final pa = (dxPx == 0 && dyPx == 0)
          ? 0.0
          : skyPositionAngleDegrees(
              fromRaDegrees: startSky.raDegrees,
              fromDecDegrees: startSky.decDegrees,
              toRaDegrees: endSky.raDegrees,
              toDecDegrees: endSky.decDegrees,
            );
      final motion = (bestDist * wcs.pixelScaleArcsecPerPixel) / dtMin;
      final midSky = projection.pixelToWorld(
        x: (star.x + matched.x) / 2.0,
        y: (star.y + matched.y) / 2.0,
      );
      final mid = (ra: midSky.raDegrees, dec: midSky.decDegrees);

      final snrScore = (((star.snr + matched.snr) * 0.5) / 20.0)
          .clamp(0.2, 1.0)
          .toDouble();
      final motionScore =
          ((bestDist - options.minMotionPixels) /
                  (options.maxMotionPixels - options.minMotionPixels))
              .clamp(0.0, 1.0)
              .toDouble();
      // Boost confidence only when 3-frame validation actually passed.
      final validationBonus = passedMiddleValidation ? 0.10 : 0.0;
      final confidence =
          (0.65 * snrScore + 0.35 * motionScore + validationBonus)
              .clamp(0.15, 0.98)
              .toDouble();
      matches.add(
        MovingObjectMatch(
          candidateId:
              'mo_${mid.ra.toStringAsFixed(5)}_${mid.dec.toStringAsFixed(5)}_${matches.length + 1}',
          raDegrees: mid.ra,
          decDegrees: mid.dec,
          motionArcsecPerMinute: motion,
          positionAngleDegrees: pa,
          confidence: confidence,
          isKnownObject: false,
          epochUtc: epochUtc,
          fluxEstimate: (star.flux + matched.flux) / 2.0,
        ),
      );
    }
    matches.sort((a, b) => b.confidence.compareTo(a.confidence));
    return matches.take(40).toList(growable: false);
  }

  @override
  Future<(ScienceFrameQualityMetrics, List<ScienceTileMetric>)>
  computeLastCaptureQualityMaps({
    required String deviceId,
    required int gridRows,
    required int gridCols,
    required int lowClipAdu,
    required int highClipAdu,
    required DateTime timestamp,
    int? capturedImageId,
    int? sessionId,
  }) async {
    try {
      final result = await apiComputeLastCaptureQualityMaps(
        deviceId: deviceId,
        gridRows: gridRows,
        gridCols: gridCols,
        lowClipAdu: lowClipAdu,
        highClipAdu: highClipAdu,
      );
      return _mapBridgeQualityResult(
        result: result,
        timestamp: timestamp,
        capturedImageId: capturedImageId,
        sessionId: sessionId,
        fallbackProcessingTier: 'live',
      );
    } catch (error, stack) {
      _logger.warning(
        'Native last-capture quality map compute failed for $deviceId; '
        'falling back to Dart path: $error\n$stack',
        source: 'ScienceBackend',
      );
    }

    final stopwatch = Stopwatch()..start();
    final lastImage = await apiGetLastImage(deviceId: deviceId);
    final raw = await apiGetLastRawImageData(deviceId: deviceId);

    if (lastImage.width <= 0 || lastImage.height <= 0) {
      throw StateError('Last capture dimensions are unavailable');
    }
    final expected = lastImage.width * lastImage.height;
    if (raw.length < expected) {
      throw StateError('Last raw buffer too small: ${raw.length} < $expected');
    }

    final result = _computeQualityMetricsFromBuffer(
      width: lastImage.width,
      height: lastImage.height,
      gridRows: gridRows,
      gridCols: gridCols,
      lowClipAdu: lowClipAdu,
      highClipAdu: highClipAdu,
      timestamp: timestamp,
      capturedImageId: capturedImageId,
      sessionId: sessionId,
      processingTier: 'live',
      sampleAt: (index) => raw[index].toDouble(),
    );
    final processingMs = stopwatch.elapsedMilliseconds;

    return (result.frame.copyWith(processingMs: processingMs), result.tiles);
  }

  @override
  Future<(ScienceFrameQualityMetrics, List<ScienceTileMetric>)>
  computeFitsQualityMaps({
    required String filePath,
    required int gridRows,
    required int gridCols,
    required int lowClipAdu,
    required int highClipAdu,
    required DateTime timestamp,
    int? capturedImageId,
    int? sessionId,
  }) async {
    try {
      final result = await apiComputeFitsQualityMaps(
        filePath: filePath,
        gridRows: gridRows,
        gridCols: gridCols,
        lowClipAdu: lowClipAdu,
        highClipAdu: highClipAdu,
      );
      return _mapBridgeQualityResult(
        result: result,
        timestamp: timestamp,
        capturedImageId: capturedImageId,
        sessionId: sessionId,
        fallbackProcessingTier: 'deferred',
      );
    } catch (error, stack) {
      _logger.warning(
        'Native FITS quality map compute failed for $filePath; '
        'falling back to Dart path: $error\n$stack',
        source: 'ScienceBackend',
      );
    }

    final stopwatch = Stopwatch()..start();
    final linear = await apiReadFitsLinearData(filePath: filePath);
    if (linear.width <= 0 || linear.height <= 0) {
      throw StateError('FITS dimensions are unavailable');
    }
    final expected = linear.width * linear.height;
    if (linear.linearData.length < expected) {
      throw StateError(
        'FITS linear buffer too small: ${linear.linearData.length} < $expected',
      );
    }

    final result = _computeQualityMetricsFromBuffer(
      width: linear.width,
      height: linear.height,
      gridRows: gridRows,
      gridCols: gridCols,
      lowClipAdu: lowClipAdu,
      highClipAdu: highClipAdu,
      timestamp: timestamp,
      capturedImageId: capturedImageId,
      sessionId: sessionId,
      processingTier: 'deferred',
      sampleAt: (index) => linear.linearData[index],
    );
    final processingMs = stopwatch.elapsedMilliseconds;

    return (result.frame.copyWith(processingMs: processingMs), result.tiles);
  }

  @override
  Future<LineRatioProduct> computeLineRatios(
    NarrowbandSet set,
    LineRatioOptions options,
  ) async {
    final ha = await apiReadFitsLinearData(filePath: set.hAlphaPath);
    final oiii = await apiReadFitsLinearData(filePath: set.oiiiPath);
    final sii = await apiReadFitsLinearData(filePath: set.siiPath);
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
      siiRawSamples
          .map((value) => value - siiBackground)
          .toList(growable: false),
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
          ((ha.linearData[i] - haBackground).clamp(0.0, double.infinity)) /
          haExp;
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
            ((ha.linearData[index] - haBackground).clamp(
              0.0,
              double.infinity,
            )) /
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
  }
}
