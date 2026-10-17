part of '../post_session_integration_service.dart';

extension _PostSessionIntegrationStages on PostSessionIntegrationService {
  /// Build the per-sub `analyzeNight` inputs from the accepted per-frame records,
  /// invoke the seam, and persist the resulting [IntegrationCurve] (as
  /// `improvement_curve_json`) plus the full-night SNR / integration-time anchor
  /// (`target_snr` / `target_integration_s`) via [updateSmartFields].
  ///
  /// Fail-soft: any failure (no accepted/measured subs, seam error) logs and
  /// returns without disturbing the committed master row.
  Future<void> _analyzeAndStoreCurve({
    required int masterId,
    required IntegrateSessionResult result,
    required IntegrationSettings settings,
  }) async {
    try {
      final qualities = <Map<String, dynamic>>[];
      final weights = <double>[];
      final exposures = <double>[];
      // The exact ordered population the optimizer ranks — the sub on-disk paths
      // in the same (filtered, capture) order the qualities/weights arrays use.
      // Persisted alongside the curve so a later curve-linked cull can map the
      // recommendation's `keptIndices` back to specific subs and bail out when
      // the live accepted set no longer matches this population (rather than
      // silently rejecting the wrong subs by raw index).
      final population = <String>[];
      for (final record in result.perFrameStats) {
        // Only accepted, measured subs carry honest quality descriptors; the
        // optimizer ranks the population, so unmeasured/dropped subs are skipped.
        if (!record.accepted || record.snr == null) continue;
        qualities.add(<String, dynamic>{
          'snr': record.snr,
          // `noise` is load-bearing: the optimizer (`apiAnalyzeNight`) skips any
          // sub with `noise <= 0` from its variance sums, so omitting it
          // collapses the whole improvement curve (and `targetSnr`) to zero.
          // Surfaced per-sub by the native integrate FFI; thread it through.
          if (record.noise != null) 'noise': record.noise,
          if (record.background != null) 'background': record.background,
          if (record.starCount != null) 'starCount': record.starCount,
          if (record.fwhm != null) 'fwhm': record.fwhm,
          if (record.eccentricity != null) 'eccentricity': record.eccentricity,
        });
        weights.add(record.weight);
        // Per-sub exposure is not on the per-frame record; fall back to the
        // night's mean exposure so the cumulative-time axis stays meaningful.
        exposures.add(_meanExposurePerSub(result));
        population.add(record.path);
      }
      if (qualities.isEmpty) return;

      final curve = await _seam.analyzeNight(
        qualities: qualities,
        weights: weights,
        exposuresS: exposures,
      );

      // Store the curve JSON with the population identity as a sibling key so
      // the typed [IntegrationCurve] stays pure (it round-trips its own keys and
      // ignores the extra one) while the cull path can recover the ordering.
      final stored = curve.toJson()..['population'] = population;

      final anchor = curve.points.isNotEmpty ? curve.points.last : null;
      await _mastersDao.updateSmartFields(
        masterId,
        improvementCurveJson: jsonEncode(stored),
        targetSnr: anchor?.snr,
        targetIntegrationS: anchor?.cumulativeIntegrationS,
      );
    } catch (e, st) {
      _logSoftFailure('analyzeNight/improvementCurve', e, st);
    }
  }

  /// Plate-solve the finished master FITS via the injected [_plateSolver] and
  /// persist the resulting eight CD-matrix WCS scalars via
  /// [IntegratedMastersDao.updateWcs].
  ///
  /// Fail-soft and idempotent-friendly: returns null when no solver is
  /// injected, when the solve fails / no solver is installed (the closure
  /// returns null), or when the master has no FITS on disk. On success the row's
  /// WCS columns fill in, lighting up the catalog annotation overlay AND colour
  /// calibration (both reconstruct a `WcsOverlay` from these columns), and the
  /// solved [MasterWcsSolution] is returned so the colour-calibration finishing
  /// pass can reuse it without a database round-trip.
  Future<MasterWcsSolution?> _solveAndStoreWcs({
    required int masterId,
    required IntegrateSessionResult result,
    double? hintRaHours,
    double? hintDecDegrees,
  }) async {
    final solver = _plateSolver;
    if (solver == null) return null;
    final masterFits = result.masterFitsPath;
    if (masterFits.trim().isEmpty) return null;
    try {
      final wcs = await solver(
        imagePath: masterFits,
        imageWidth: result.width,
        imageHeight: result.height,
        hintRaHours: hintRaHours,
        hintDecDegrees: hintDecDegrees,
      );
      if (wcs == null) return null; // No solver / failed solve — un-annotated.
      await _mastersDao.updateWcs(
        masterId,
        crval1: wcs.crval1,
        crval2: wcs.crval2,
        crpix1: wcs.crpix1,
        crpix2: wcs.crpix2,
        cd1_1: wcs.cd1_1,
        cd1_2: wcs.cd1_2,
        cd2_1: wcs.cd2_1,
        cd2_2: wcs.cd2_2,
      );
      return wcs;
    } catch (e, st) {
      _logSoftFailure('solveAndStoreWcs', e, st);
      return null;
    }
  }

  /// Reconstruct a [WcsOverlay] (cdelt/crota form) from a solved CD-matrix
  /// [MasterWcsSolution], inverting the native sign convention
  /// (`WcsInfo::from_plate_solve`, `imaging/src/fits.rs`):
  /// `cdelt1 = -‖(cd1_1, cd2_1)‖` (RA negative), `cdelt2 = ‖(cd1_2, cd2_2)‖`,
  /// `crota2 = atan2(cd2_1, cd2_2)` — the same derivation the UI's
  /// `_resolveMasterWcs` uses to read the persisted v44 columns. The colour
  /// calibrator needs this overlay to project detections onto the sky.
  static WcsOverlay _overlayFromSolution(MasterWcsSolution wcs) {
    final cdelt1 = -math.sqrt(
      wcs.cd1_1 * wcs.cd1_1 + wcs.cd2_1 * wcs.cd2_1,
    ); // RA: neg.
    final cdelt2 = math.sqrt(wcs.cd1_2 * wcs.cd1_2 + wcs.cd2_2 * wcs.cd2_2);
    final crota2 = math.atan2(wcs.cd2_1, wcs.cd2_2) * 180.0 / math.pi;
    return WcsOverlay(
      crpix1: wcs.crpix1,
      crpix2: wcs.crpix2,
      crval1: wcs.crval1,
      crval2: wcs.crval2,
      cdelt1: cdelt1,
      cdelt2: cdelt2,
      crota2: crota2,
    );
  }

  /// Run the gated optional finishing passes on the master in place, each
  /// fail-soft (log + continue): background extraction, colour calibration
  /// (delegated to the injected [MasterColorCalibrator] when present and the
  /// master carries a solved [wcs]; skipped gracefully otherwise), and the
  /// star-reduction / deconvolution previews. Each pass that writes an artifact
  /// persists its on-disk output path onto the master (the v44
  /// `background_extracted_path` / `deconvolved_path` / `star_reduced_path` /
  /// `color_calibrated_path` columns) so the workbench can surface the result.
  ///
  /// [wcs] is the master's just-solved WCS (from [_solveAndStoreWcs]) or null
  /// when the master is un-solved — colour calibration needs it to place
  /// detections on the sky, so its gate is skipped when it is null.
  Future<void> _runOptionalFinishing({
    required int masterId,
    required IntegrateSessionResult result,
    required IntegrationSettings settings,
    required MasterWcsSolution? wcs,
  }) async {
    final masterFits = result.masterFitsPath;

    if (settings.extractBackground) {
      await _softStep('extractBackground', () async {
        final outPath = _suffixBeforeExtension(masterFits, '_bgx');
        final written = await _seam.extractBackground(<String, dynamic>{
          'inputFits': masterFits,
          'outputFits': outPath,
          'config': <String, dynamic>{
            'polyDegree': settings.backgroundPolyDegree,
            'preserveMean': settings.backgroundPreserveMean,
          },
        });
        await _mastersDao.updateSmartFields(
          masterId,
          backgroundExtracted: true,
        );
        await _mastersDao.updateFinishingPaths(
          masterId,
          backgroundExtractedPath: written,
        );
        return written;
      });
    }

    if (settings.colorCalibrate) {
      // Colour calibration needs Dart-side star↔catalogue matching (B–V), which
      // is the job of the injected [MasterColorCalibrator] (wrapping
      // [ColorCalibrationService] at the provider boundary). It also needs the
      // master's solved WCS to project detections onto the sky. Both must be
      // present; otherwise we skip gracefully rather than fabricating matches.
      final calibrator = _colorCalibrator;
      if (calibrator == null || wcs == null) {
        _logSoftFailure(
          'colorCalibrate',
          StateError(
            'colour calibration skipped: '
            '${calibrator == null ? 'no MasterColorCalibrator injected' : 'master has no solved WCS'}',
          ),
          StackTrace.current,
        );
      } else {
        await _softStep('colorCalibrate', () async {
          final outPath = _suffixBeforeExtension(masterFits, '_color');
          final written = await calibrator(
            masterFits: masterFits,
            outputFits: outPath,
            wcs: _overlayFromSolution(wcs),
            channels: result.channels,
          );
          // null ⇒ skipped (too few catalog matches / no catalog): leave the
          // master un-calibrated rather than persisting a phantom path.
          if (written == null || written.trim().isEmpty) {
            throw StateError(
              'colour calibration produced no output (too few catalogue '
              'cross-matches)',
            );
          }
          await _mastersDao.updateSmartFields(
            masterId,
            colorCalibratedPath: written,
          );
          return written;
        });
      }
    }

    if (settings.reduceStars) {
      await _softStep('reduceStarsPreview', () async {
        final outPath = _suffixBeforeExtension(masterFits, '_starred');
        final written = await _seam.reduceStarsPreview(<String, dynamic>{
          'inputFits': masterFits,
          'outputFits': outPath,
          'config': <String, dynamic>{
            'strength': settings.starReductionStrength,
            'method': settings.starReduceMethod.wire,
          },
        });
        await _mastersDao.updateFinishingPaths(
          masterId,
          starReducedPath: written,
        );
        return written;
      });
    }

    if (settings.deconvolve) {
      await _softStep('deconvolvePreview', () async {
        final outPath = _suffixBeforeExtension(masterFits, '_decon');
        final written = await _seam.deconvolvePreview(<String, dynamic>{
          'inputFits': masterFits,
          'outputFits': outPath,
          'config': <String, dynamic>{
            'iterations': settings.deconIterations,
            'regularization': settings.deconRegularization,
          },
        });
        await _mastersDao.updateFinishingPaths(
          masterId,
          deconvolvedPath: written,
        );
        return written;
      });
    }
  }

  /// Drizzle-integrate the accepted subs onto a `scale`× output grid using each
  /// sub's source→reference registration transform (surfaced per-frame by the
  /// native integrate pass), then swap the drizzled FITS in as the persisted
  /// master.
  ///
  /// Returns the (possibly rewritten) [IntegrateSessionResult]: on a successful
  /// drizzle the master FITS path + output dimensions are replaced with the
  /// drizzled artifact's, so the caller's downstream WCS solve and the persisted
  /// row both describe the drizzled master. When [IntegrationSettings.drizzle] is
  /// off — or no accepted sub carried a transform, or the drizzle fails — the
  /// input [result] is returned unchanged (fail-soft: the standard master, which
  /// is already committed, stays the master).
  Future<IntegrateSessionResult> _runDrizzle({
    required int masterId,
    required IntegrateSessionResult result,
    required IntegrationSettings settings,
    required ResolvedCalibration calibration,
  }) async {
    if (!settings.drizzle) return result;

    try {
      // Each accepted sub contributes its raw, un-resampled pixels + the
      // source→reference transform fitted during registration. Drizzle deposits
      // those raw drops onto the finer grid itself (no pre-resampling), so the
      // input is the *original* sub FITS — exactly `perFrameStats.path`. Subs
      // that failed registration carry no transform and are skipped.
      final frames = <Map<String, dynamic>>[];
      for (final record in result.perFrameStats) {
        if (!record.accepted) continue;
        final transform = record.transform;
        if (transform == null || transform.length != 9) continue;
        frames.add(<String, dynamic>{
          'fitsPath': record.path,
          'transform': transform,
          'weight': record.weight,
        });
      }
      if (frames.isEmpty) {
        _logSoftFailure(
          'drizzleIntegrate',
          StateError(
            'drizzle skipped: no accepted sub carried a registration '
            'transform',
          ),
          StackTrace.current,
        );
        return result;
      }

      final outputFits = _suffixBeforeExtension(
        result.masterFitsPath,
        '_drizzle',
      );
      final coverageFits = _suffixBeforeExtension(outputFits, '_cov');
      final coveragePng = _swapExtension(coverageFits, '.png');
      // A stretched preview PNG sibling for the drizzled master, so the hero
      // shows the (scaled) drizzled image rather than the standard 1× preview.
      final previewPng = _swapExtension(outputFits, '.png');
      final drizzleResult = await _seam.drizzleIntegrate(<String, dynamic>{
        'frames': frames,
        'refW': result.width,
        'refH': result.height,
        'config': <String, dynamic>{
          'scale': settings.drizzleScale,
          'pixfrac': settings.drizzlePixfrac,
          'kernel': settings.drizzleKernel.wire,
        },
        'bayer': settings.bayerDrizzle,
        // Drizzle deposits raw sub pixels, so it must apply the SAME resolved
        // calibration the standard integrate path applied — otherwise the
        // drizzled master that gets swapped in as canonical is uncalibrated
        // (amp glow / hot pixels / vignetting / dust). The drizzle-native side
        // consumes the same `{dark?, flat?, bias?, cosmeticCorrection}` shape
        // `api_integrate_session` does, calibrating each frame before drizzling.
        'calibration': calibration.toBridgeJson(),
        'outputFits': outputFits,
        'coverageFits': coverageFits,
        'coveragePngPath': coveragePng,
        'previewPngPath': previewPng,
      });

      final outputPath = drizzleResult['outputPath'] as String?;
      if (outputPath == null || outputPath.isEmpty) {
        _logSoftFailure(
          'drizzleIntegrate',
          StateError('drizzle returned no outputPath'),
          StackTrace.current,
        );
        return result;
      }
      final outWidth = (drizzleResult['outWidth'] as num?)?.toInt();
      final outHeight = (drizzleResult['outHeight'] as num?)?.toInt();
      final outChannels = (drizzleResult['channels'] as num?)?.toInt();
      final drizzleCoverage = drizzleResult['coveragePath'] as String?;
      final drizzleCoveragePreview =
          drizzleResult['coveragePngPath'] as String?;
      // The drizzled master's preview, when the native side wrote one; fall back
      // to the standard preview if not (older native lib / write skipped).
      final drizzlePreview = drizzleResult['previewPngPath'] as String?;
      final newPreview = (drizzlePreview != null && drizzlePreview.isNotEmpty)
          ? drizzlePreview
          : result.previewPath;

      // Swap the drizzled FITS + its preview in as the persisted master, with
      // its scaled dimensions, so the hero / overlay / WCS solve all see the
      // drizzled result rather than the standard resample-and-combine master.
      await _mastersDao.updateBookkeeping(
        masterId,
        masterFitsPath: outputPath,
        previewPngPath: newPreview,
        coverageMapPath: drizzleCoverage,
        coverageMapPreviewPath: drizzleCoveragePreview,
        width: outWidth,
        height: outHeight,
        channels: outChannels,
      );

      // Re-stamp the result so the caller's WCS solve targets the drizzled FITS
      // and its (scaled) geometry, and the immediate post-integrate hero shows
      // the drizzled preview — leaving every other field intact.
      return IntegrateSessionResult(
        masterFitsPath: outputPath,
        previewPath: newPreview,
        rejectionMapPath: result.rejectionMapPath,
        rejectionMapPreviewPath: result.rejectionMapPreviewPath,
        coverageMapPath: drizzleCoverage,
        coverageMapPreviewPath: drizzleCoveragePreview,
        framesIntegrated: result.framesIntegrated,
        framesRejected: result.framesRejected,
        totalIntegrationSec: result.totalIntegrationSec,
        rmsResidual: result.rmsResidual,
        width: outWidth ?? result.width,
        height: outHeight ?? result.height,
        channels: outChannels ?? result.channels,
        perFrameStats: result.perFrameStats,
      );
    } catch (e, st) {
      _logSoftFailure('drizzleIntegrate', e, st);
      return result;
    }
  }

  /// Mean exposure per contributing sub: total integration time over the count
  /// of integrated frames, or 0 when nothing integrated.
  static double _meanExposurePerSub(IntegrateSessionResult result) {
    final n = result.framesIntegrated;
    if (n <= 0) return 0.0;
    return result.totalIntegrationSec / n;
  }

  /// Run a fail-soft finishing step: log any throw and swallow it so the master
  /// persist is never aborted by an optional pass.
  Future<void> _softStep(String name, Future<String> Function() step) async {
    try {
      await step();
    } catch (e, st) {
      _logSoftFailure(name, e, st);
    }
  }

  void _logSoftFailure(String step, Object error, StackTrace stackTrace) {
    developer.log(
      'post-session optional step "$step" failed (continuing)',
      name: 'PostSessionIntegrationService',
      error: error,
      stackTrace: stackTrace,
      level: 900, // WARNING
    );
  }
}
