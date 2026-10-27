import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart';

import '../../backend/skotiq_backend.dart';
import '../../models/plate_solver.dart';
import '../../models/science/science_models.dart';
import '../wcs/fits_image_size.dart';
import '../wcs/gnomonic_projection.dart';
import '../../providers/backend_provider.dart';
import '../../providers/database_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/logging_service.dart';
import '../plate_solve_service.dart';
import 'astrometric_residuals.dart';
import 'moving_object_linker.dart';
import 'nearest_neighbour_matching.dart';
import 'aperture_photometry.dart';
import 'filter_transparency.dart';
import 'frame_zero_point_fit.dart';
import 'photometric_bands.dart';
import 'photometric_catalog_service.dart';
import 'science_backend.dart';
import 'frame_camera_noise.dart';

part 'default_science_backend/helpers.dart';
part 'default_science_backend/value_types.dart';

/// Catalog match radius for astrometric residuals. Wide enough to keep the
/// corner stars of a linear solve, whose distortion is what the residual map
/// exists to show.
const double _residualMatchPx = 10.0;

class DefaultScienceBackend implements ScienceBackend {
  final Ref _ref;

  DefaultScienceBackend(this._ref);

  final Map<String, MovingObjectFrameDetections> _movingObjectCache = {};

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
      // ASTAP's .wcs names no image size; a solver result without a field
      // size takes it from the frame, or the catalog cone shrinks to its
      // minimum and misses the outer field.
      var fieldWidth = result.fieldWidth;
      var fieldHeight = result.fieldHeight;
      if (!(fieldWidth > 0 && fieldHeight > 0) && result.pixelScale > 0) {
        final size = await readFitsImageSize(imagePath);
        if (size != null) {
          fieldWidth = size.width * result.pixelScale / 3600.0;
          fieldHeight = size.height * result.pixelScale / 3600.0;
        }
      }
      return WcsSolution(
        raHours: result.ra / 15.0,
        decDegrees: result.dec,
        pixelScaleArcsecPerPixel: result.pixelScale,
        rotationDegrees: result.rotation,
        fieldWidthDegrees: fieldWidth,
        fieldHeightDegrees: fieldHeight,
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
  ) async => (await _detect(imagePath, options))?.stars ?? const [];

  Future<_DetectedField?> _detect(
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
      final stars = result.stars
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
      return _DetectedField(
        stars: stars,
        noiseAdu: result.noise,
        medianFwhm: result.medianFwhm,
      );
    } catch (error, stack) {
      _logger.warning(
        'Star measurement failed for $imagePath: $error\n$stack',
        source: 'ScienceBackend',
      );
      return null;
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
    final rawExposureSeconds = context.exposureSeconds;
    if (!rawExposureSeconds.isFinite || rawExposureSeconds <= 0) {
      _logger.warning(
        'Photometric calibration skipped for $imagePath: invalid exposureSeconds=${context.exposureSeconds}.',
        source: 'ScienceBackend',
      );
      return null;
    }
    final exposureSeconds = rawExposureSeconds.clamp(0.001, double.infinity);

    final field = await _detect(
      imagePath,
      const PhotometryOptions(minSnr: 5.0),
    );
    final stars = field?.stars ?? const <StarMeasurement>[];
    // WHY: writing a sentinel-RMS isCalibrated:false row would let downstream
    // aggregations (transparency confidence, observation reports) treat the
    // row as data. Returning null instead means no DB row is inserted —
    // "not calibrated" is encoded by absence, not by a fabricated metric.
    if (stars.length < 8) {
      return null;
    }

    // V≤15 reaches the depth APASS actually provides; the HYG fallback
    // simply has nothing fainter than ~9, so a deeper request costs nothing.
    const maxMatchPx = 9.0;
    final (matches, matchedCatalog) = await _catalogMatches(
      imagePath: imagePath,
      wcs: wcs,
      detectedStars: stars,
      maxCatalogMag: 15.0,
      maxMatchPx: maxMatchPx,
    );
    if (matches.length < 8) {
      return null;
    }

    final apertureFluxes = await _calibrationApertureFluxes(
      imagePath: imagePath,
      matches: matches,
      medianHfr: field!.medianFwhm / 2,
    );
    final fit = fitFrameZeroPoint(
      matches:
          apertureFluxes ??
          [
            for (final m in matches)
              (
                flux: m.detected.flux,
                catalogStar: m.catalogStar,
                separationPx: m.separationPx,
              ),
          ],
      exposureSeconds: exposureSeconds,
      mapping: filterBandFor(context.filterName),
      maxMatchPx: maxMatchPx,
      brighterHalfOnly: apertureFluxes == null,
    );
    final source = catalog == PhotometricCatalogSource.auto
        ? matchedCatalog
        : catalog;
    if (fit.rejectionReason != null) {
      _logger.info(
        'Photometric calibration refused for $imagePath: ${fit.rejectionReason}',
        source: 'ScienceBackend',
      );
      return FramePhotometricCalibration(
        capturedImageId: context.capturedImageId,
        sessionId: context.sessionId,
        timestamp: context.capturedAt,
        airmass: context.airmass,
        exposureSeconds: exposureSeconds,
        isCalibrated: false,
        matchedStarCount: fit.starCount,
        calibrationRms: fit.rms ?? 0.0,
        solverId: wcs.solverId,
        catalogSource: source,
        filter: context.filterName,
        photometricBand: fit.band.code,
        bandIsStandard: fit.bandIsStandard,
        rejectionReason: fit.rejectionReason,
      );
    }
    final zeroPoint = fit.zeroPoint!;
    final rms = fit.rms!;

    final limits = await _limitingMagnitudes(
      imagePath: imagePath,
      zeroPoint: zeroPoint,
      exposureSeconds: exposureSeconds,
      field: field,
    );

    return FramePhotometricCalibration(
      capturedImageId: context.capturedImageId,
      sessionId: context.sessionId,
      timestamp: context.capturedAt,
      airmass: context.airmass,
      exposureSeconds: exposureSeconds,
      isCalibrated: true,
      zeroPoint: zeroPoint,
      limitingMag3Sigma: limits?.lim3,
      limitingMag5Sigma: limits?.lim5,
      matchedStarCount: fit.starCount,
      calibrationRms: rms,
      solverId: wcs.solverId,
      // Resolve the `auto` request to the catalog _catalogMatches actually
      // served the fit from (APASS online/cache, or the bundled HYG
      // fallback) so the persisted row and the MAGZPSRC FITS keyword
      // record real provenance.
      catalogSource: source,
      filter: context.filterName,
      photometricBand: fit.band.code,
      bandIsStandard: fit.bandIsStandard,
      zeroPointError: fit.zeroPointError,
    );
  }

  /// Total fluxes of the matched catalog stars, measured in one circular
  /// aperture of three times the frame's median half-flux radius (about 1.5
  /// FWHM) and scaled by an aperture correction: the median ratio of the
  /// flux within twice that radius to the flux within it, over the brightest
  /// matched stars. A radius that follows the seeing keeps the same fraction
  /// of every star's light whatever the seeing, unlike the detector's
  /// footprint. Null when the file cannot be read this way.
  Future<List<ZeroPointMatch>?> _calibrationApertureFluxes({
    required String imagePath,
    required List<_CatalogMatch> matches,
    required double medianHfr,
  }) async {
    if (!medianHfr.isFinite || medianHfr <= 0) return null;
    final ranked = matches.toList()
      ..sort((a, b) => b.detected.flux.compareTo(a.detected.flux));
    final used = ranked.take(300).toList(growable: false);
    final radius = (3.0 * medianHfr).clamp(3.0, 20.0).toDouble();
    final inner = 2.5 * radius;
    final outer = inner + math.max(6.0, radius);
    final positions = [
      for (final m in used) (x: m.detected.x, y: m.detected.y),
    ];
    final small = await measureApertures(
      imagePath,
      positions,
      radius: radius,
      innerSky: inner,
      outerSky: outer,
    );
    if (small == null) return null;
    final brightest = positions.take(30).toList(growable: false);
    final large = await measureApertures(
      imagePath,
      brightest,
      radius: 2 * radius,
      innerSky: inner,
      outerSky: outer,
    );
    if (large == null) return null;
    final ratios = <double>[];
    for (var i = 0; i < brightest.length; i++) {
      final a = small[i], b = large[i];
      if (a == null || b == null || a.flux <= 0 || b.flux <= 0) continue;
      ratios.add(b.flux / a.flux);
    }
    if (ratios.length < 5) return null;
    ratios.sort();
    final correction = ratios[ratios.length ~/ 2];
    if (!correction.isFinite || correction < 1 || correction > 1.5) {
      return null;
    }
    return [
      for (var i = 0; i < used.length; i++)
        if (small[i] != null && small[i]!.flux > 0)
          (
            flux: small[i]!.flux * correction,
            catalogStar: used[i].catalogStar,
            separationPx: used[i].separationPx,
          ),
    ];
  }

  /// 3σ and 5σ point-source limits for a frame with [zeroPoint].
  ///
  /// The noise is the detector's measured per-pixel background noise summed
  /// over a 1.5-FWHM aperture, and the limit is the total flux of a star
  /// whose light inside that aperture is N times that noise. A seeing
  /// profile (Moffat, beta about 3.5) holds about 93% of its light within
  /// 1.5 FWHM. With no measured noise it falls back to a Poisson model from
  /// the configured gain and read noise.
  Future<({double lim3, double lim5})?> _limitingMagnitudes({
    required String imagePath,
    required double zeroPoint,
    required double exposureSeconds,
    required _DetectedField field,
  }) async {
    const apertureFwhm = 1.5;
    const encircledFraction = 0.93;
    final fwhm = field.medianFwhm.isFinite && field.medianFwhm > 0
        ? field.medianFwhm
        : 3.0;
    final radius = (apertureFwhm * fwhm).clamp(2.0, 20.0).toDouble();
    final aperturePixels = math.pi * radius * radius;
    double? noiseAdu;
    if (field.noiseAdu.isFinite && field.noiseAdu > 0) {
      noiseAdu = field.noiseAdu * math.sqrt(aperturePixels);
    } else {
      final cameraNoise = await frameCameraNoise(
        _ref.read(settingsDaoProvider),
        imagePath,
      );
      final readNoise = cameraNoise.readNoise;
      if (readNoise == null || cameraNoise.gain == null) {
        _logger.warning(
          'Limiting magnitude omitted for $imagePath: no measured background '
          'noise and camera read noise is not configured.',
          source: 'ScienceBackend',
        );
        return null;
      }
      final g = cameraNoise.gain!;
      final bg = _median(
        field.stars
            .map((s) => s.background)
            .where((v) => v.isFinite && v >= 0)
            .toList(growable: false),
      );
      noiseAdu =
          math.sqrt(aperturePixels * (bg * g + readNoise * readNoise)) / g;
    }
    double limit(double sigmas) =>
        zeroPoint -
        2.5 *
            math.log(sigmas * noiseAdu! / encircledFraction / exposureSeconds) /
            math.ln10;
    return (lim3: limit(3), lim5: limit(5));
  }

  @override
  Future<TransparencySample?> estimateTransparency(
    List<FramePhotometricCalibration> recentCalibrations,
    TransparencyOptions options,
  ) async => estimateFilterTransparency(recentCalibrations, options);

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
      maxMatchPx: _residualMatchPx,
    );
    final size = await readFitsImageSize(imagePath);
    if (size == null) return null;
    return buildAstrometricResidualMap(
      pairs: [
        for (final m in matches)
          (
            detectedX: m.detected.x,
            detectedY: m.detected.y,
            catalogX: m.catalogX,
            catalogY: m.catalogY,
          ),
      ],
      pixelScaleArcsec: wcs.pixelScaleArcsecPerPixel,
      imageWidth: size.width,
      imageHeight: size.height,
      maxMatchPx: _residualMatchPx,
      solveHasSip: wcs.aOrder > 0 && wcs.aCoeffs.isNotEmpty,
      sampleCount: options.sampleCount,
    );
  }

  @override
  Future<List<MovingObjectMatch>> detectMovingObjects(
    List<MovingObjectFrame> frames,
    MovingObjectOptions options,
  ) async {
    if (frames.length < options.minFrames) return const [];
    final perFrame = <MovingObjectFrameDetections>[];
    for (final frame in frames) {
      final detections = await _movingObjectDetections(frame);
      if (detections != null) perFrame.add(detections);
    }
    return linkMovingObjects(perFrame, options);
  }

  /// One frame's detections placed on the sky through the frame's own solve,
  /// cached by path so each frame is measured once while it stays in the
  /// sliding window.
  Future<MovingObjectFrameDetections?> _movingObjectDetections(
    MovingObjectFrame frame,
  ) async {
    final cached = _movingObjectCache[frame.imagePath];
    if (cached != null) return cached;
    final header = await readFitsFrameSummary(frame.imagePath);
    final when = frame.midExposureUtc ?? header?.midExposureUtc;
    if (header == null || when == null) return null;
    final projection = _projectionFor(
      frame.wcs,
      imageWidth: header.width,
      imageHeight: header.height,
    );
    if (projection == null) {
      _logger.warning(
        'Moving-object detection skipped ${frame.imagePath}: its WCS is not '
        'projectable.',
        source: 'ScienceBackend',
      );
      return null;
    }
    final stars = await measureStars(
      frame.imagePath,
      const PhotometryOptions(minSnr: 5.0),
    );
    final detections = <MovingObjectDetection>[];
    for (final s in stars) {
      final sky = projection.pixelToWorld(x: s.x, y: s.y);
      detections.add(
        MovingObjectDetection(
          raDegrees: sky.raDegrees,
          decDegrees: sky.decDegrees,
          x: s.x,
          y: s.y,
          flux: s.flux,
          snr: s.snr,
        ),
      );
    }
    final result = MovingObjectFrameDetections(
      midExposureUtc: when,
      detections: detections,
    );
    if (_movingObjectCache.length >= 16) {
      _movingObjectCache.remove(_movingObjectCache.keys.first);
    }
    _movingObjectCache[frame.imagePath] = result;
    return result;
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
