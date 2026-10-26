import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart' as drift;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart';

import '../../database/database.dart' as db;
import '../../database/daos/science_dao.dart';
import '../../providers/app_version_provider.dart';
import '../../providers/database_provider.dart';
import '../imaging_records_repository.dart';
import '../../providers/science_provider.dart';
import '../../providers/science_status_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/logging_service.dart';
import '../../models/science/science_models.dart';
import '../../utils/utc_timestamp.dart';
import '../wcs/gnomonic_projection.dart';
import '../wcs/wcs_sip_codec.dart';
import 'airmass.dart';
import 'default_science_backend.dart';
import 'fits_header_writer.dart';
import 'photometric_catalog_service.dart';
import 'photometric_transform_service.dart';
import 'science_camera_auto_config.dart';
import 'science_backend.dart';
import 'frame_auto_grader.dart';
import 'science_status.dart';

part 'science_processing_service/private_helpers.dart';
part 'science_processing_service/provider.dart';
part 'science_processing_service/frame_lanes.dart';
part 'science_processing_service/writeback.dart';

/// What the science pipeline did with one frame.
class ScienceFrameOutcome {
  const ScienceFrameOutcome._(this.kind, [this.error]);

  const ScienceFrameOutcome.processed()
    : this._(ScienceFrameOutcomeKind.processed);

  /// Not a light frame; science products are computed for lights only.
  const ScienceFrameOutcome.skipped() : this._(ScienceFrameOutcomeKind.skipped);

  const ScienceFrameOutcome.failed(String error)
    : this._(ScienceFrameOutcomeKind.failed, error);

  final ScienceFrameOutcomeKind kind;
  final String? error;
}

enum ScienceFrameOutcomeKind { processed, skipped, failed }

class ScienceProcessingService {
  final Ref _ref;
  int _adaptiveLiveGridRows = 12;
  int _adaptiveLiveGridCols = 16;
  int _liveBudgetBreachCount = 0;
  int _queueDepth = 0;

  /// Tail of the frame-processing chain. Captures fire
  /// [processCapturedFrame] unawaited, so with short exposures several
  /// frames can be in flight at once — but the status tracker keeps a
  /// single in-flight slot and the adaptive-grid state is per-service.
  /// Chaining each frame onto the previous one keeps the documented
  /// "one frame at a time" contract true regardless of capture cadence.
  Future<void> _processingTail = Future<void>.value();

  ScienceProcessingService(this._ref);

  ScienceDao get _scienceDao => _ref.read(scienceDaoProvider);
  ImagingRecordsRepository get _imagesRepo =>
      _ref.read(imagingRecordsRepositoryProvider);
  ScienceBackend get _scienceBackend => _ref.read(scienceBackendProvider);
  LoggingService get _logger => _ref.read(loggingServiceProvider);
  ScienceProcessingStatusTracker get _status =>
      _ref.read(scienceProcessingStatusTrackerProvider);

  Future<void> processCapturedFrame({
    required String imagePath,
    String? deviceId,
    int? capturedImageId,
    int? sessionId,
  }) => processFrame(
    imagePath: imagePath,
    deviceId: deviceId,
    capturedImageId: capturedImageId,
    sessionId: sessionId,
  );

  /// Queue one frame for science processing behind every frame already
  /// queued, and complete with what became of it. Never throws.
  ///
  /// [deviceId] lets the frame-quality lane read the camera's last image
  /// buffer instead of the file; pass it only when that buffer still holds
  /// this frame. With [solveIfUnsolved] false, a frame whose row has no
  /// stored solve is processed without one rather than solved here.
  Future<ScienceFrameOutcome> processFrame({
    required String imagePath,
    String? deviceId,
    int? capturedImageId,
    int? sessionId,
    bool solveIfUnsolved = true,
  }) {
    _queueDepth++;
    _status.enqueue();
    _logger.debug(
      'science.queue_depth=$_queueDepth',
      source: 'ScienceProcessingService',
    );

    final run = _processingTail.then(
      (_) => _processFrame(
        imagePath: imagePath,
        deviceId: deviceId,
        capturedImageId: capturedImageId,
        sessionId: sessionId,
        solveIfUnsolved: solveIfUnsolved,
      ),
    );
    // _processFrame never throws (it catches and logs internally), but keep
    // the chain alive defensively so one broken link can't stall the queue.
    _processingTail = run.then<void>((_) {}).catchError((_) {});
    return run.catchError(
      (Object error) => ScienceFrameOutcome.failed(error.toString()),
    );
  }

  /// Apparent magnitude for a moving-object candidate from its measured
  /// flux and the frame's photometric zero point:
  ///   mag = ZP − 2.5·log10(flux / exposure)
  /// (the ZP is fitted on exposure-normalized fluxes against catalog V
  /// magnitudes). Null whenever any input is missing/unusable — MPC lines
  /// are then astrometry-only, which the format explicitly allows.
  static double? _candidateApparentMagnitude({
    required double? fluxEstimate,
    required FramePhotometricCalibration? calibration,
    required double exposureSeconds,
  }) {
    final zeroPoint = calibration?.zeroPoint;
    if (zeroPoint == null || !zeroPoint.isFinite) return null;
    if (fluxEstimate == null || !fluxEstimate.isFinite || fluxEstimate <= 0) {
      return null;
    }
    if (!exposureSeconds.isFinite || exposureSeconds <= 0) return null;
    final magnitude =
        zeroPoint - 2.5 * math.log(fluxEstimate / exposureSeconds) / math.ln10;
    return magnitude.isFinite ? magnitude : null;
  }

  /// 1-sigma magnitude error implied by a measured signal-to-noise ratio.
  ///
  /// `PhotometryMeasurements.uncertainty` is a magnitude everywhere it is
  /// consumed — AAVSO export writes it straight into MAGERR, and the period
  /// analysis weights the light curve by it — so every role must populate it in
  /// magnitudes. For a single star with no differential to propagate, that is
  /// the Poisson limit 2.5/ln(10) / SNR ≈ 1.0857/SNR.
  ///
  /// Exposed as a pure function so the unit contract can be asserted without
  /// standing up Riverpod, the database and the native bridge.
  static double magnitudeSigmaFromSnr(double snr) {
    // Clamped the same way the differential-magnitude path clamps SNR: a
    // non-finite or sub-unity SNR would otherwise emit an infinite or absurd
    // error bar rather than a merely pessimistic one.
    final safeSnr = snr.isFinite ? snr.clamp(1.0, 1e6).toDouble() : 1.0;
    return 1.0857 / safeSnr;
  }

  /// One frame's differential photometry against a fixed comparison set.
  ///
  /// The check star is chosen once per session: [sessionCheckId] when the
  /// session already has one, else (with three or more comparisons) the
  /// comparison closest in flux to the target in this frame. Every other
  /// comparison in [comparisonIds] forms the ensemble, whose reference flux
  /// is their summed flux; a frame in which any of them was not found is
  /// skipped rather than measured against a different ensemble.
  ///
  /// Flux errors combine the detector's background-limited SNR with the
  /// star's own photon noise, `σ² = (F/SNR)² + F/g`, when the camera's
  /// e⁻/ADU [gainElectronsPerAdu] is known.
  static DifferentialFrame buildDifferentialFrame({
    required StarMeasurement target,
    required List<({String objectId, StarMeasurement star})> comparisons,
    required List<String> comparisonIds,
    required String? sessionCheckId,
    required double? gainElectronsPerAdu,
  }) {
    final found = {for (final c in comparisons) c.objectId: c.star};
    String? checkId;
    if (sessionCheckId != null && comparisonIds.contains(sessionCheckId)) {
      checkId = sessionCheckId;
    } else if (comparisonIds.length >= 3 && comparisons.isNotEmpty) {
      checkId = comparisons
          .reduce(
            (a, b) =>
                (a.star.flux - target.flux).abs() <=
                    (b.star.flux - target.flux).abs()
                ? a
                : b,
          )
          .objectId;
    }
    final ensembleIds = comparisonIds
        .where((id) => id != checkId)
        .toList(growable: false);
    if (ensembleIds.length < 2) {
      return const DifferentialFrame.skip(
        'fewer than two comparison stars besides the check star',
      );
    }
    final missing = ensembleIds.where((id) => !found.containsKey(id)).toList();
    if (missing.isNotEmpty) {
      return DifferentialFrame.skip(
        'comparison ${missing.join(', ')} not found, so the ensemble would '
        'differ from the other frames',
      );
    }
    var sum = 0.0;
    var variance = 0.0;
    for (final id in ensembleIds) {
      final star = found[id]!;
      sum += star.flux;
      final sigma = fluxSigma(star, gainElectronsPerAdu);
      variance += sigma * sigma;
    }
    return DifferentialFrame(
      checkObjectId: found.containsKey(checkId) ? checkId : null,
      ensembleObjectIds: ensembleIds,
      ensembleFlux: sum,
      ensembleFluxSigma: math.sqrt(variance),
      targetFluxSigma: fluxSigma(target, gainElectronsPerAdu),
    );
  }

  /// 1-sigma flux error of [star] in ADU: the detector's background-limited
  /// error plus the star's photon noise when e⁻/ADU is known.
  static double fluxSigma(StarMeasurement star, double? gainElectronsPerAdu) {
    final flux = star.flux.clamp(1e-6, double.infinity).toDouble();
    final snr = star.snr.isFinite ? star.snr.clamp(1.0, 1e6).toDouble() : 1.0;
    final background = flux / snr;
    final g = gainElectronsPerAdu;
    final photon = (g != null && g > 0) ? flux / g : 0.0;
    return math.sqrt(background * background + photon);
  }

  /// Build the `photometry_measurements` rows for one frame: the target,
  /// the optional check star, and every comparison star.
  ///
  /// `uncertainty` is a magnitude for EVERY role. [standardMagnitudeFor] is
  /// folded in via [transform]/[airmass]/[exposureSeconds] rather than a
  /// callback, so the exposure normalization stays in one place.
  static List<db.PhotometryMeasurementsCompanion>
  buildPhotometryMeasurementRows({
    required int? capturedImageId,
    required int? sessionId,
    required DateTime frameTimestamp,
    required String targetObjectId,
    required StarMeasurement target,
    required double targetFlux,
    required double targetFluxSigma,
    required List<({String objectId, StarMeasurement star})> comparisons,
    required String? checkObjectId,
    required Set<String> outlierObjectIds,
    required double comparisonFlux,
    required double comparisonFluxUncertainty,
    required PhotometricTransformCoefficients? transform,
    required double? airmass,
    required double exposureSeconds,
    String? filter,
    double? gainElectronsPerAdu,
    Map<String, double> colorIndexByObject = const {},
  }) {
    final safeComparisonFlux = comparisonFlux.clamp(1e-6, double.infinity);
    final differentialMag =
        -2.5 *
        math.log((targetFlux / comparisonFlux).clamp(1e-6, double.infinity)) /
        math.ln10;
    final fractionalVariance =
        math.pow(targetFluxSigma / targetFlux, 2) +
        math.pow(comparisonFluxUncertainty / safeComparisonFlux, 2);
    final uncertainty =
        1.0857 *
        math.sqrt(fractionalVariance.isFinite ? fractionalVariance : 0.0);

    // A standard magnitude needs the star's own color whenever the
    // transform has a color term: with B-V taken as 0 the term biased R by
    // -0.3 and B by +0.5 mag. Without a known color none is written.
    double? standardMagForFlux(double rawFlux, String objectId) {
      if (transform == null || airmass == null || airmass <= 0) return null;
      final colorIndex = transform.colorTerm == 0
          ? 0.0
          : colorIndexByObject[objectId];
      if (colorIndex == null) return null;
      final flux = (rawFlux / exposureSeconds).clamp(1e-6, double.infinity);
      final instMag =
          -2.5 * math.log(flux.clamp(1e-30, double.infinity)) / math.ln10;
      final standard = transform.applyTransform(
        instrumentalMag: instMag,
        airmass: airmass,
        colorIndex: colorIndex,
      );
      return standard.isFinite ? standard : null;
    }

    final entries = <db.PhotometryMeasurementsCompanion>[
      db.PhotometryMeasurementsCompanion.insert(
        capturedImageId: drift.Value(capturedImageId),
        sessionId: drift.Value(sessionId),
        objectId: targetObjectId,
        role: const drift.Value('target'),
        x: target.x,
        y: target.y,
        flux: targetFlux,
        differentialMagnitude: drift.Value(differentialMag),
        standardMagnitude: drift.Value(
          standardMagForFlux(targetFlux, targetObjectId),
        ),
        snr: drift.Value(target.snr),
        uncertainty: drift.Value(uncertainty),
        filter: drift.Value(filter),
        timestamp: drift.Value(frameTimestamp),
      ),
    ];

    for (final entry in comparisons) {
      final objectId = entry.objectId;
      final star = entry.star;
      final isCheck = checkObjectId != null && objectId == checkObjectId;

      // The check star gets its own differential magnitude against the
      // SAME ensemble used for the target, so its light curve directly
      // exposes systematics. Plain comparisons keep a null differential —
      // they ARE the reference.
      double? checkDiffMag;
      double? checkUncertainty;
      if (isCheck) {
        final checkFlux = star.flux.clamp(1e-6, double.infinity);
        checkDiffMag =
            -2.5 *
            math.log(
              (checkFlux / safeComparisonFlux).clamp(1e-6, double.infinity),
            ) /
            math.ln10;
        final checkVariance =
            math.pow(fluxSigma(star, gainElectronsPerAdu) / checkFlux, 2) +
            math.pow(comparisonFluxUncertainty / safeComparisonFlux, 2);
        checkUncertainty =
            1.0857 * math.sqrt(checkVariance.isFinite ? checkVariance : 0.0);
      }

      entries.add(
        db.PhotometryMeasurementsCompanion.insert(
          capturedImageId: drift.Value(capturedImageId),
          sessionId: drift.Value(sessionId),
          objectId: objectId,
          role: drift.Value(isCheck ? 'check' : 'comparison'),
          x: star.x,
          y: star.y,
          flux: star.flux,
          differentialMagnitude: drift.Value<double?>(checkDiffMag),
          standardMagnitude: drift.Value(
            standardMagForFlux(star.flux, objectId),
          ),
          snr: drift.Value(star.snr),
          // A plain comparison star has no differential magnitude to
          // propagate, so its uncertainty is its own Poisson-limited magnitude
          // sigma. Storing the raw ADU flux noise (flux/SNR) here would put
          // two quantities differing by ~10^6 in one column, which the AAVSO
          // export publishes as MAGERR and the period analysis weights the
          // light curve by.
          uncertainty: drift.Value<double?>(
            checkUncertainty ??
                (gainElectronsPerAdu == null
                    ? magnitudeSigmaFromSnr(star.snr)
                    : 1.0857 *
                          fluxSigma(star, gainElectronsPerAdu) /
                          star.flux.clamp(1e-6, double.infinity)),
          ),
          isOutlier: drift.Value(outlierObjectIds.contains(objectId)),
          filter: drift.Value(filter),
          timestamp: drift.Value(frameTimestamp),
        ),
      );
    }

    return entries;
  }

  /// Fallback build tag stamped into the FITS header when the caller does
  /// not resolve a concrete version (pure-function tests). Keep this small
  /// (≤ 60 chars) so it fits a single 80-char value card with room for a
  /// comment. Production calls pass `skotiqBuildLabel(ref)` instead so
  /// the stamped tag always tracks version.yaml.
  static const String _skotiqBuildTag = 'Skotiq';

  /// Build the FITS keyword update set the science pipeline writes back
  /// for a finished frame, given the photometric calibration and
  /// transparency sample produced for that frame.
  ///
  /// Exposed as a pure function so the e2e contract — *what science fields
  /// end up in the FITS header* — can be tested in isolation from the
  /// service, Riverpod, the database, and the native bridge. The returned
  /// list is empty when nothing useful was produced (no calibration AND no
  /// transparency), so callers can short-circuit the writeback in that
  /// case. When *any* keyword is produced the list always ends with a
  /// `SKHA_VER` tag so downstream tools can attribute provenance.
  static List<FitsKeywordWrite> buildScienceWritebackKeywords({
    required FramePhotometricCalibration? calibration,
    required TransparencySample? transparency,
    String buildTag = _skotiqBuildTag,
  }) {
    final updates = <FitsKeywordWrite>[];
    // A refused fit (chance matches, large scatter) writes nothing.
    if (calibration != null && calibration.isCalibrated) {
      if (calibration.zeroPoint != null && calibration.zeroPoint!.isFinite) {
        updates.add(
          FitsKeywordWrite.floating(
            'MAGZP',
            calibration.zeroPoint!,
            comment: 'Photometric zero point [mag]',
          ),
        );
      }
      final zpError = calibration.zeroPointError;
      if (zpError != null && zpError.isFinite) {
        updates.add(
          FitsKeywordWrite.floating(
            'MAGZPERR',
            zpError,
            comment: 'MAGZP standard error [mag]',
          ),
        );
      }
      if (calibration.calibrationRms.isFinite) {
        updates.add(
          FitsKeywordWrite.floating(
            'MAGZPRMS',
            calibration.calibrationRms,
            comment: 'Star-to-star scatter about MAGZP [mag]',
          ),
        );
      }
      final band = calibration.photometricBand;
      if (band != null) {
        updates.add(
          FitsKeywordWrite.string(
            'MAGZPBND',
            band,
            comment: calibration.bandIsStandard
                ? 'Catalog band of MAGZP'
                : 'MAGZP is a V-equivalent, not a standard band',
          ),
        );
      }
      updates.add(
        FitsKeywordWrite.string(
          'MAGZPSRC',
          calibration.catalogSource.name.toUpperCase(),
          comment: 'Catalog used for MAGZP',
        ),
      );
      updates.add(
        FitsKeywordWrite.integer(
          'MAGZPNST',
          calibration.matchedStarCount,
          comment: 'Stars matched in MAGZP fit',
        ),
      );
      if (calibration.limitingMag5Sigma != null &&
          calibration.limitingMag5Sigma!.isFinite) {
        updates.add(
          FitsKeywordWrite.floating(
            'MAGLIM5',
            calibration.limitingMag5Sigma!,
            comment: 'Limiting mag at 5-sigma',
          ),
        );
      }
    }
    if (transparency != null && transparency.transparencyPercent.isFinite) {
      updates.add(
        FitsKeywordWrite.floating(
          'TRANSPAR',
          transparency.transparencyPercent,
          comment: 'Atmospheric transparency [percent]',
        ),
      );
      // EXTINCT carries physical units (mag/airmass), so it is only
      // stamped when the value came from a real ZP-vs-airmass regression.
      // The warm-up fallback stores a baseline ZP depression in plain
      // magnitudes — writing that under this keyword would hand external
      // pipelines a number with the wrong units.
      if (transparency.extinctionFromAirmassFit &&
          transparency.extinctionCoefficient.isFinite) {
        updates.add(
          FitsKeywordWrite.floating(
            'EXTINCT',
            transparency.extinctionCoefficient,
            comment: 'Extinction coeff [mag/airmass]',
          ),
        );
      }
    }
    if (updates.isEmpty) {
      return const <FitsKeywordWrite>[];
    }
    // Always stamp the producing tool so downstream observers can tell
    // which Skotiq build emitted these values.
    updates.add(
      FitsKeywordWrite.string(
        'SKHA_VER',
        buildTag,
        comment: 'Skotiq build that stamped MAGZP*/TRANSPAR',
      ),
    );
    return updates;
  }

  Future<void> generateLineRatios({
    required int sessionId,
    required NarrowbandSet set,
    int? hAlphaImageId,
    int? oiiiImageId,
    int? siiImageId,
  }) async {
    final product = await _scienceBackend.computeLineRatios(
      set,
      const LineRatioOptions(),
    );

    final ratioSiiHa = _metricValue(product.metrics, 'SII/Ha');
    final ratioOiiiHa = _metricValue(product.metrics, 'OIII/Ha');
    final ratioSiiOiii = _metricValue(product.metrics, 'SII/OIII');

    await _scienceDao.insertLineRatioProduct(
      db.LineRatioProductsCompanion.insert(
        sessionId: drift.Value(sessionId),
        hAlphaImageId: drift.Value(hAlphaImageId),
        oiiiImageId: drift.Value(oiiiImageId),
        siiImageId: drift.Value(siiImageId),
        ratioSiiHa: drift.Value(ratioSiiHa),
        ratioOiiiHa: drift.Value(ratioOiiiHa),
        ratioSiiOiii: drift.Value(ratioSiiOiii),
        createdAt: drift.Value(product.createdAt),
      ),
    );
  }
}

/// Result of [ScienceProcessingService.buildDifferentialFrame].
class DifferentialFrame {
  const DifferentialFrame({
    required this.checkObjectId,
    required this.ensembleObjectIds,
    required this.ensembleFlux,
    required this.ensembleFluxSigma,
    required this.targetFluxSigma,
  }) : skipReason = null;

  const DifferentialFrame.skip(String this.skipReason)
    : checkObjectId = null,
      ensembleObjectIds = const [],
      ensembleFlux = null,
      ensembleFluxSigma = null,
      targetFluxSigma = null;

  final String? checkObjectId;
  final List<String> ensembleObjectIds;
  final double? ensembleFlux;
  final double? ensembleFluxSigma;
  final double? targetFluxSigma;
  final String? skipReason;
}
