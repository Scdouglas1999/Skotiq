part of '../science_processing_service.dart';

extension _ScienceProcessingFrameLanes on ScienceProcessingService {
  Future<void> _processFrame({
    required String imagePath,
    String? deviceId,
    int? capturedImageId,
    int? sessionId,
  }) async {
    bool frameBegun = false;
    // Snapshots gathered during processing and consumed by the FITS
    // writeback stage at the end. They stay local so a partial pipeline
    // (e.g. calibration succeeds, transparency fails) still gets the
    // succeeded fields written back.
    FramePhotometricCalibration? writebackCalibration;
    TransparencySample? writebackTransparency;
    try {
      db.CapturedImage? capturedImage;
      if (capturedImageId != null) {
        capturedImage = await _imagesRepo.getImageById(capturedImageId);
        final frameType = capturedImage?.frameType.toLowerCase();
        // Science products in v1 are computed for light frames only.
        if (frameType != null && frameType != 'light') {
          _status.dequeue();
          return;
        }
      }

      _status.beginFrame(
        imagePath: imagePath,
        capturedImageId: capturedImageId,
        sessionId: sessionId,
      );
      frameBegun = true;

      final globalSettings = await _ref.read(scienceSettingsProvider.future);
      final sessionConfig = sessionId == null
          ? const ScienceSessionConfig()
          : await _ref
                    .read(scienceSessionConfigProvider(sessionId).future)
                    .catchError((_) => null) ??
                const ScienceSessionConfig();
      final frameTimestamp = await _resolveFrameTimestamp(
        imagePath: imagePath,
        capturedImage: capturedImage,
      );

      if (globalSettings.frameQualityMapsEnabled) {
        final sw = _status.beginStage(ScienceStage.frameQuality);
        try {
          await _processImmediateQualityLane(
            imagePath: imagePath,
            deviceId: deviceId,
            capturedImageId: capturedImageId,
            sessionId: sessionId,
            timestamp: frameTimestamp,
          );
          _status.endStage(
            ScienceStage.frameQuality,
            ScienceStageOutcome.ok,
            stopwatch: sw,
          );
        } catch (error) {
          _status.endStage(
            ScienceStage.frameQuality,
            ScienceStageOutcome.failed,
            stopwatch: sw,
            note: error.toString(),
          );
          rethrow;
        }
      } else {
        _status.skipStage(
          ScienceStage.frameQuality,
          note: 'Frame quality maps disabled',
        );
      }

      final solveSw = _status.beginStage(ScienceStage.plateSolve);
      WcsSolution? wcs;
      try {
        wcs = await _resolveWcsSolution(
          imagePath: imagePath,
          capturedImageId: capturedImageId,
          capturedImage: capturedImage,
        );
        _status.endStage(
          ScienceStage.plateSolve,
          wcs == null ? ScienceStageOutcome.noData : ScienceStageOutcome.ok,
          stopwatch: solveSw,
          note: wcs == null ? 'No WCS available for this frame' : null,
        );
      } catch (error) {
        _status.endStage(
          ScienceStage.plateSolve,
          ScienceStageOutcome.failed,
          stopwatch: solveSw,
          note: error.toString(),
        );
        rethrow;
      }
      final frameContext = await _buildFrameContext(
        imagePath: imagePath,
        capturedImageId: capturedImageId,
        sessionId: sessionId,
        capturedImage: capturedImage,
        wcs: wcs,
      );

      if (globalSettings.photometricCalibrationEnabled &&
          sessionConfig.calibrationEnabled &&
          wcs != null) {
        final sw = _status.beginStage(ScienceStage.calibration);
        try {
          final calibration = await _scienceBackend.calibrateFramePhotometry(
            imagePath,
            wcs,
            PhotometricCatalogSource.auto,
            frameContext,
          );
          if (calibration != null) {
            final calibrationRow =
                db.FramePhotometricCalibrationCompanion.insert(
                  capturedImageId: drift.Value(capturedImageId),
                  sessionId: drift.Value(sessionId),
                  isCalibrated: drift.Value(calibration.isCalibrated),
                  zeroPoint: drift.Value(calibration.zeroPoint),
                  limitingMag3Sigma: drift.Value(calibration.limitingMag3Sigma),
                  limitingMag5Sigma: drift.Value(calibration.limitingMag5Sigma),
                  matchedStarCount: drift.Value(calibration.matchedStarCount),
                  calibrationRms: drift.Value(calibration.calibrationRms),
                  catalogSource: drift.Value(calibration.catalogSource.name),
                  solverId: drift.Value(calibration.solverId),
                  timestamp: drift.Value(frameContext.capturedAt),
                );
            if (capturedImageId != null) {
              await _scienceDao.replaceFrameCalibrationForImage(
                capturedImageId,
                calibrationRow,
              );
            } else {
              await _scienceDao.insertFrameCalibration(calibrationRow);
            }
            // Remember for the writeback pass — only the scientific fields
            // we want to stamp; the row identity is not needed.
            writebackCalibration = calibration;
            _status.endStage(
              ScienceStage.calibration,
              ScienceStageOutcome.ok,
              stopwatch: sw,
              note:
                  'ZP ${calibration.zeroPoint?.toStringAsFixed(2) ?? "—"}, '
                  '${calibration.matchedStarCount} stars',
            );
          } else {
            _status.endStage(
              ScienceStage.calibration,
              ScienceStageOutcome.noData,
              stopwatch: sw,
              note: 'Too few catalog matches for a reliable fit',
            );
          }
        } catch (error) {
          _status.endStage(
            ScienceStage.calibration,
            ScienceStageOutcome.failed,
            stopwatch: sw,
            note: error.toString(),
          );
          rethrow;
        }
      } else {
        _status.skipStage(
          ScienceStage.calibration,
          note: wcs == null
              ? 'No plate solve — calibration skipped'
              : 'Calibration disabled in settings',
        );
      }

      if (globalSettings.transparencyEnabled &&
          sessionConfig.transparencyEnabled &&
          sessionId != null) {
        final transparencySw = _status.beginStage(ScienceStage.transparency);
        try {
          final recentRows = await _scienceDao.getRecentCalibrations(
            sessionId,
            limit: 20,
          );
          final recent = <FramePhotometricCalibration>[];
          for (final row in recentRows) {
            db.CapturedImage? rowImage;
            if (row.capturedImageId != null) {
              rowImage = await _imagesRepo.getImageById(row.capturedImageId!);
            }
            final airmass = rowImage == null
                ? null
                : await _airmassForCapturedImage(
                    image: rowImage,
                    timestamp: row.timestamp,
                  );
            final exposureSeconds = rowImage?.exposureDuration;
            if (exposureSeconds == null ||
                !exposureSeconds.isFinite ||
                exposureSeconds <= 0) {
              _logger.warning(
                'Transparency sample skipped for calibration ${row.id}: missing or invalid exposure metadata.',
                source: 'ScienceProcessingService',
              );
              continue;
            }
            recent.add(
              FramePhotometricCalibration(
                capturedImageId: row.capturedImageId,
                sessionId: row.sessionId,
                timestamp: row.timestamp,
                airmass: airmass,
                exposureSeconds: exposureSeconds.clamp(0.001, 1e6).toDouble(),
                isCalibrated: row.isCalibrated,
                zeroPoint: row.zeroPoint,
                limitingMag3Sigma: row.limitingMag3Sigma,
                limitingMag5Sigma: row.limitingMag5Sigma,
                matchedStarCount: row.matchedStarCount,
                calibrationRms: row.calibrationRms,
                solverId: row.solverId,
                catalogSource: _catalogFromName(row.catalogSource),
              ),
            );
          }

          final sample = await _scienceBackend.estimateTransparency(
            recent,
            const TransparencyOptions(rollingWindowSize: 12),
          );

          if (sample != null) {
            final sampleRow = db.TransparencySamplesCompanion.insert(
              capturedImageId: drift.Value(capturedImageId),
              sessionId: drift.Value(sessionId),
              transparencyPercent: sample.transparencyPercent,
              extinctionCoefficient: drift.Value(sample.extinctionCoefficient),
              qualityBucket: drift.Value(sample.qualityBucket),
              confidence: drift.Value(sample.confidence),
              timestamp: drift.Value(frameContext.capturedAt),
            );
            if (capturedImageId != null) {
              await _scienceDao.replaceTransparencySampleForImage(
                capturedImageId,
                sampleRow,
              );
            } else {
              await _scienceDao.insertTransparencySample(sampleRow);
            }
            writebackTransparency = sample;
            _status.endStage(
              ScienceStage.transparency,
              ScienceStageOutcome.ok,
              stopwatch: transparencySw,
              note:
                  '${sample.transparencyPercent.toStringAsFixed(1)}% (${sample.qualityBucket})',
            );
          } else {
            _status.endStage(
              ScienceStage.transparency,
              ScienceStageOutcome.noData,
              stopwatch: transparencySw,
              note:
                  'Need more calibrated frames before a transparency sample stabilises',
            );
          }
        } catch (error) {
          _status.endStage(
            ScienceStage.transparency,
            ScienceStageOutcome.failed,
            stopwatch: transparencySw,
            note: error.toString(),
          );
          rethrow;
        }
      } else {
        _status.skipStage(
          ScienceStage.transparency,
          note: sessionId == null
              ? 'Transparency requires an active session'
              : 'Transparency disabled in settings',
        );
      }

      if (globalSettings.psfMapEnabled && sessionConfig.psfMapEnabled) {
        final sw = _status.beginStage(ScienceStage.psfMap);
        try {
          final psfMap = await _scienceBackend.buildPsfFieldMap(
            imagePath,
            wcs,
            PsfMapOptions(
              gridRows: sessionConfig.psfGridRows,
              gridCols: sessionConfig.psfGridCols,
            ),
          );

          if (capturedImageId != null) {
            final rows = psfMap.tiles
                .map(
                  (tile) => db.PsfFieldTilesCompanion.insert(
                    capturedImageId: drift.Value(capturedImageId),
                    sessionId: drift.Value(sessionId),
                    tileRow: tile.row,
                    tileCol: tile.col,
                    starCount: drift.Value(tile.starCount),
                    medianFwhm: drift.Value(tile.medianFwhm),
                    medianHfr: drift.Value(tile.medianHfr),
                    medianEccentricity: drift.Value(tile.medianEccentricity),
                    roundness: drift.Value(tile.roundness),
                    timestamp: drift.Value(frameContext.capturedAt),
                  ),
                )
                .toList(growable: false);
            await _scienceDao.replacePsfTilesForImage(capturedImageId, rows);

            final fwhmTiles = psfMap.tiles
                .map(
                  (tile) => db.ScienceTileMetricsCompanion.insert(
                    capturedImageId: drift.Value(capturedImageId),
                    sessionId: drift.Value(sessionId),
                    timestamp: drift.Value(frameContext.capturedAt),
                    layerType: ScienceLayerType.fwhm.dbValue,
                    tileRow: tile.row,
                    tileCol: tile.col,
                    sampleCount: drift.Value(tile.starCount),
                    value: drift.Value(tile.medianFwhm),
                    p05: drift.Value(tile.medianFwhm),
                    p50: drift.Value(tile.medianFwhm),
                    p95: drift.Value(tile.medianFwhm),
                    auxValue: drift.Value(tile.roundness),
                  ),
                )
                .toList(growable: false);
            final hfrTiles = psfMap.tiles
                .map(
                  (tile) => db.ScienceTileMetricsCompanion.insert(
                    capturedImageId: drift.Value(capturedImageId),
                    sessionId: drift.Value(sessionId),
                    timestamp: drift.Value(frameContext.capturedAt),
                    layerType: ScienceLayerType.hfr.dbValue,
                    tileRow: tile.row,
                    tileCol: tile.col,
                    sampleCount: drift.Value(tile.starCount),
                    value: drift.Value(tile.medianHfr),
                    p05: drift.Value(tile.medianHfr),
                    p50: drift.Value(tile.medianHfr),
                    p95: drift.Value(tile.medianHfr),
                    auxValue: drift.Value(tile.roundness),
                  ),
                )
                .toList(growable: false);
            final eccTiles = psfMap.tiles
                .map(
                  (tile) => db.ScienceTileMetricsCompanion.insert(
                    capturedImageId: drift.Value(capturedImageId),
                    sessionId: drift.Value(sessionId),
                    timestamp: drift.Value(frameContext.capturedAt),
                    layerType: ScienceLayerType.eccentricity.dbValue,
                    tileRow: tile.row,
                    tileCol: tile.col,
                    sampleCount: drift.Value(tile.starCount),
                    value: drift.Value(tile.medianEccentricity),
                    p05: drift.Value(tile.medianEccentricity),
                    p50: drift.Value(tile.medianEccentricity),
                    p95: drift.Value(tile.medianEccentricity),
                    auxValue: drift.Value(tile.roundness),
                  ),
                )
                .toList(growable: false);

            await _scienceDao.replaceTileMetricsForImageLayer(
              capturedImageId,
              ScienceLayerType.fwhm.dbValue,
              fwhmTiles,
            );
            await _scienceDao.replaceTileMetricsForImageLayer(
              capturedImageId,
              ScienceLayerType.hfr.dbValue,
              hfrTiles,
            );
            await _scienceDao.replaceTileMetricsForImageLayer(
              capturedImageId,
              ScienceLayerType.eccentricity.dbValue,
              eccTiles,
            );
            _status.endStage(
              ScienceStage.psfMap,
              ScienceStageOutcome.ok,
              stopwatch: sw,
              note:
                  '${psfMap.tiles.length} tiles, '
                  '${sessionConfig.psfGridRows}×${sessionConfig.psfGridCols} grid',
            );
          } else {
            _status.endStage(
              ScienceStage.psfMap,
              ScienceStageOutcome.noData,
              stopwatch: sw,
              note: 'Sessionless capture — PSF map needs a captured-image id',
            );
          }
        } catch (error) {
          _status.endStage(
            ScienceStage.psfMap,
            ScienceStageOutcome.failed,
            stopwatch: sw,
            note: error.toString(),
          );
          rethrow;
        }
      } else {
        _status.skipStage(
          ScienceStage.psfMap,
          note: 'PSF map disabled in settings',
        );
      }

      if (globalSettings.astrometricResidualsEnabled &&
          sessionConfig.residualsEnabled &&
          wcs != null &&
          capturedImageId != null) {
        final sw = _status.beginStage(ScienceStage.residuals);
        try {
          final residualMap = await _scienceBackend.computeAstrometricResiduals(
            imagePath,
            wcs,
            const AstrometryOptions(sampleCount: 180),
          );
          if (residualMap != null) {
            final rows = residualMap.vectors
                .map(
                  (vector) => db.AstrometryResidualVectorsCompanion.insert(
                    capturedImageId: drift.Value(capturedImageId),
                    sessionId: drift.Value(sessionId),
                    x: vector.x,
                    y: vector.y,
                    dxArcsec: vector.dxArcsec,
                    dyArcsec: vector.dyArcsec,
                    magnitudeArcsec: vector.magnitudeArcsec,
                    recommendationCode: drift.Value(residualMap.suggestionCode),
                    timestamp: drift.Value(frameContext.capturedAt),
                  ),
                )
                .toList(growable: false);
            await _scienceDao.replaceResidualVectorsForImage(
              capturedImageId,
              rows,
            );
            _status.endStage(
              ScienceStage.residuals,
              ScienceStageOutcome.ok,
              stopwatch: sw,
              note: '${rows.length} residual vectors',
            );
          } else {
            _status.endStage(
              ScienceStage.residuals,
              ScienceStageOutcome.noData,
              stopwatch: sw,
              note: 'Solver did not provide residual vectors',
            );
          }
        } catch (error) {
          _status.endStage(
            ScienceStage.residuals,
            ScienceStageOutcome.failed,
            stopwatch: sw,
            note: error.toString(),
          );
          rethrow;
        }
      } else {
        _status.skipStage(
          ScienceStage.residuals,
          note: wcs == null
              ? 'Residuals need a plate solve'
              : capturedImageId == null
              ? 'Residuals need a captured-image id'
              : 'Residuals disabled in settings',
        );
      }

      if (globalSettings.photometryEnabled && sessionConfig.photometryEnabled) {
        final sw = _status.beginStage(ScienceStage.photometry);
        try {
          final photometrySelection = await _ref
              .read(sciencePhotometrySelectionProvider.future)
              .catchError((_) => const SciencePhotometrySelection());
          final photometryResult = await _computeAndStorePhotometry(
            imagePath: imagePath,
            capturedImageId: capturedImageId,
            sessionId: sessionId,
            wcs: wcs,
            selection: photometrySelection,
            frameTimestamp: frameContext.capturedAt,
            exposureSeconds: frameContext.exposureSeconds,
            filterName: frameContext.filterName,
            airmass: frameContext.airmass,
          );
          _status.endStage(
            ScienceStage.photometry,
            photometryResult == 0
                ? ScienceStageOutcome.noData
                : ScienceStageOutcome.ok,
            stopwatch: sw,
            note: photometryResult == 0
                ? 'No target/comparison anchors matched in field'
                : '$photometryResult '
                      'measurement${photometryResult == 1 ? '' : 's'}',
          );
        } catch (error) {
          _status.endStage(
            ScienceStage.photometry,
            ScienceStageOutcome.failed,
            stopwatch: sw,
            note: error.toString(),
          );
          rethrow;
        }
      } else {
        _status.skipStage(
          ScienceStage.photometry,
          note: 'Photometry disabled in settings',
        );
      }

      if (globalSettings.movingObjectsEnabled &&
          sessionConfig.movingObjectsEnabled &&
          wcs != null &&
          sessionId != null) {
        final sw = _status.beginStage(ScienceStage.movingObjects);
        try {
          final recent = await _imagesRepo.getRecentImagesForSession(
            sessionId,
            limit: 5,
          );
          final recentPaths =
              recent
                  .where((image) => image.filePath.isNotEmpty)
                  .toList(growable: false)
                ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
          final paths = recentPaths
              .map((image) => image.filePath)
              .toList(growable: false);

          if (paths.length >= 2) {
            final candidates = await _scienceBackend.detectMovingObjects(
              paths,
              wcs,
              const MovingObjectOptions(),
            );

            final rows = candidates
                .map(
                  (candidate) => db.MovingObjectCandidatesCompanion.insert(
                    capturedImageId: drift.Value(capturedImageId),
                    sessionId: drift.Value(sessionId),
                    candidateId: candidate.candidateId,
                    raDegrees: candidate.raDegrees,
                    decDegrees: candidate.decDegrees,
                    motionArcsecPerMinute: candidate.motionArcsecPerMinute,
                    positionAngleDegrees: candidate.positionAngleDegrees,
                    confidence: candidate.confidence,
                    isKnownObject: drift.Value(candidate.isKnownObject),
                    objectName: drift.Value(candidate.objectName),
                    source: const drift.Value('local'),
                    magnitude: drift.Value(
                      ScienceProcessingService._candidateApparentMagnitude(
                        fluxEstimate: candidate.fluxEstimate,
                        calibration: writebackCalibration,
                        exposureSeconds: frameContext.exposureSeconds,
                      ),
                    ),
                    // The zero point is fitted against catalog V magnitudes,
                    // so the derived value approximates Johnson V.
                    magnitudeBand: const drift.Value('V'),
                    // The candidate's RA/Dec is a mid-stack position; store
                    // its true astrometric epoch so MPC export lines pair
                    // position and time correctly for fast movers.
                    timestamp: drift.Value(
                      candidate.epochUtc ?? frameContext.capturedAt,
                    ),
                  ),
                )
                .toList(growable: false);

            if (capturedImageId != null) {
              await _scienceDao.replaceMovingObjectCandidatesForImage(
                capturedImageId,
                rows,
              );
            } else {
              await _scienceDao.insertMovingObjectCandidates(rows);
            }
            _status.endStage(
              ScienceStage.movingObjects,
              candidates.isEmpty
                  ? ScienceStageOutcome.noData
                  : ScienceStageOutcome.ok,
              stopwatch: sw,
              note: candidates.isEmpty
                  ? 'No candidates passed motion checks'
                  : '${candidates.length} '
                        'candidate${candidates.length == 1 ? '' : 's'}',
            );
          } else {
            _status.endStage(
              ScienceStage.movingObjects,
              ScienceStageOutcome.noData,
              stopwatch: sw,
              note: 'Need 2+ recent frames; have ${paths.length}',
            );
          }
        } catch (error) {
          _status.endStage(
            ScienceStage.movingObjects,
            ScienceStageOutcome.failed,
            stopwatch: sw,
            note: error.toString(),
          );
          rethrow;
        }
      } else {
        _status.skipStage(
          ScienceStage.movingObjects,
          note: wcs == null
              ? 'Moving objects need a plate solve'
              : sessionId == null
              ? 'Moving objects require an active session'
              : 'Moving objects disabled in settings',
        );
      }

      await _runFitsHeaderWriteback(
        imagePath: imagePath,
        capturedImage: capturedImage,
        globalSettings: globalSettings,
        calibration: writebackCalibration,
        transparency: writebackTransparency,
      );

      if (capturedImageId != null) {
        await _runAutoGrade(capturedImageId: capturedImageId);
      }
    } catch (error, stack) {
      _logger.error(
        'Science frame processing failed for $imagePath: $error\n$stack',
        source: 'ScienceProcessingService',
      );
    } finally {
      _queueDepth = math.max(0, _queueDepth - 1);
      if (frameBegun) {
        _status.endFrame();
      }
    }
  }
}
