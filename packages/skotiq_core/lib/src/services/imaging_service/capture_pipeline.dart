part of '../imaging_service.dart';

extension _ImagingServiceCapturePipeline on ImagingService {
  /// The single exposure pipeline.
  ///
  /// [persistFrame] decides whether the frame is a keeper. `false` marks it a
  /// live-view frame: it still lands on disk — one reused scratch file per
  /// camera — so plate solving, annotation and the preview loader keep
  /// working, but it never enters the light-frame folder, the database, or the
  /// session's frame/integration totals.
  Future<CapturedImageData?> _capture({
    required ExposureSettings settings,
    String? targetName,
    int? frameNumber,
    String? producingNodeId,
    String? producingRunId,
    required bool persistFrame,
  }) async {
    if (_isCapturing) {
      throw const DeviceBusyException(
        message: 'Already capturing',
        userMessage: 'A capture is already in progress',
        currentOperation: 'capture',
      );
    }

    // Check camera connected
    final cameraState = _ref.read(cameraStateProvider);
    if (cameraState.connectionState != DeviceConnectionState.connected) {
      throw const ConnectionException(
        message: 'Camera not connected',
        userMessage: 'The camera is not connected',
      );
    }

    // The wheel the light actually passed through is the only truthful source
    // of a frame's filter. Carrying it on [ExposureSettings] makes every UI
    // that changes a filter responsible for mirroring the name back into the
    // settings object, and the Imaging screen's own filter strip shipped
    // without doing so: every manual capture was written with no FILTER card,
    // a "NoFilter" filename and an empty `captured_images.filter`, while the
    // banner displayed the active filter one row below. Resolving from the
    // live wheel here means no call site can drop it again.
    settings = _withLiveFilter(settings);

    _isCapturing = true;
    _cancelRequested = false;

    // `$SEQ`/`$FRAMENUM` number the operator's KEEPERS. Live-view and utility
    // frames are never saved under the naming pattern and never indexed, so
    // letting them move this counter made the next saved frame claim a
    // sequence number that counts throwaway exposures: a 30-minute framing
    // loop left the next Snapshot numbered 0361, and a short loop pushed it
    // BACKWARDS onto a number already on disk (which then landed as
    // `..._0003_001.fits`). They still get a number for the progress ring —
    // just a local one.
    final int captureFrameNumber;
    if (persistFrame) {
      _frameNumber =
          frameNumber ??
          await _nextKeeperFrameNumber(
            exposureSettings: settings,
            targetName: targetName,
          );
      captureFrameNumber = _frameNumber;
    } else {
      captureFrameNumber = frameNumber ?? (_frameNumber + 1);
    }

    final cameraNotifier = _ref.read(cameraStateProvider.notifier);
    final progressNotifier = _ref.read(exposureProgressProvider.notifier);

    try {
      // Get backend and camera ID
      final backend = _ref.read(backendProvider);
      final deviceId = cameraState.deviceId;

      if (deviceId == null) {
        throw const ConnectionException(
          message: 'Camera device ID not available',
          userMessage: 'The camera device is not available',
        );
      }

      _activeCaptureBackend = backend;
      _activeCaptureDeviceId = deviceId;
      _activeAbortFuture = null;

      // Apply readout mode before starting exposure.
      //
      // C6/C9: honour the user's explicit `readoutModeIndex` choice from the
      // camera panel. The index is resolved against the camera's *actual*
      // reported readout-mode count so a middle mode on a >2-mode sensor
      // (e.g. index 2 of 4) is sent verbatim rather than being collapsed to
      // the legacy 0/1 binary. `resolveReadoutModeIndex` returns the explicit
      // index when set, otherwise maps the legacy `fastReadout` flag (slow ->
      // first mode, fast -> last mode) using the same mode count.
      //
      // When the camera reports no readout modes (unknown to the driver, or a
      // protocol that doesn't expose them) we fall back to the legacy
      // `fastReadout ? 1 : 0` mapping — the same behaviour the panel uses when
      // it hides the read-mode dropdown — rather than forcing index 0.
      final int? readoutModeIndex = await _resolveReadoutModeIndex(
        deviceId,
        settings,
      );
      if (!_hasBackendAuthority(backend)) return null;
      if (readoutModeIndex != null) {
        // A reported readout-mode list means the setting is part of the
        // requested capture configuration. If the driver rejects it, abort the
        // exposure instead of producing a frame in an unknown mode while the
        // FITS metadata and UI still claim the user's selection.
        await backend.cameraSetReadoutMode(deviceId, readoutModeIndex);
        if (!_hasBackendAuthority(backend)) return null;
      }

      // Update state to exposing
      _activeCameraNotifier = cameraNotifier;
      _activeProgressNotifier = progressNotifier;
      _ownsSharedExposureState = true;
      cameraNotifier.setExposing(true, progress: 0.0);
      progressNotifier.startExposure(
        settings.exposureTime,
        captureFrameNumber,
        null,
      );

      // Set up event listener BEFORE starting exposure to avoid race condition
      // The exposure call blocks until complete, so events would be missed if
      // we set up the listener after the call returns
      final exposureCompleter = Completer<bool>();
      _activeExposureCompleter = exposureCompleter;

      // Timeout margin: exposure time + 30 seconds for readout/download
      // Long exposures need more margin for sensor readout
      final timeoutDuration = Duration(
        milliseconds: (settings.exposureTime * 1000).toInt() + 30000,
      );

      // Listen for exposure events and complete when done
      final eventSubscription = backend.eventStream.listen((event) {
        if (!_hasBackendAuthority(backend)) return;
        if (event.category == EventCategory.imaging) {
          if (!ImagingService._eventNamesCamera(event, deviceId)) return;
          if (event.eventType == 'ExposureProgress') {
            final progress = event.data['progress'] as double? ?? 0.0;
            final remainingSecs = event.data['remainingSecs'] as double? ?? 0.0;
            final elapsed = settings.exposureTime - remainingSecs;

            cameraNotifier.setExposing(true, progress: progress);
            progressNotifier.updateProgress(
              elapsed,
              remainingSecs,
              progress * 100,
            );
          } else if (event.eventType == 'ExposureComplete') {
            // Exposure is complete - signal the completer
            _logger.debug(
              'ExposureComplete event received',
              source: 'ImagingService',
            );
            if (!exposureCompleter.isCompleted) {
              exposureCompleter.complete(true);
            }
          } else if (event.eventType == 'ExposureCancelled') {
            // Exposure was cancelled
            if (!exposureCompleter.isCompleted) {
              exposureCompleter.complete(false);
            }
          } else if (event.eventType == 'ExposureFailed') {
            // Exposure failed
            if (!exposureCompleter.isCompleted) {
              final errorMsg =
                  event.data['error'] as String? ?? 'Unknown error';
              exposureCompleter.completeError(
                Exception('Exposure failed: $errorMsg'),
              );
            }
          }
        }
      });

      try {
        if (_cancelRequested) {
          return null;
        }
        // Start the real exposure via backend with gain/offset from UI settings
        // This call may block until the exposure completes (depending on backend)
        // Events are published during the exposure, so the listener above catches them
        // Reference instant for the staleness check below only. It goes
        // through `clockProvider` rather than `DateTime.now()` so tests can
        // control it — bypassing that seam is how an earlier attempt at the
        // DATE-OBS fix silently made the written timestamp untestable.
        //
        // `nowUtc()`, not `now().toUtc()`: `now()` renders the operator's
        // chosen zone by re-tagging shifted fields as host-local, so
        // converting it back to UTC lands offset+hostOffset away from reality.
        // Against a Tokyo site that pushed this reference hours into the
        // future and made the stale-frame check below reject every frame a
        // timed-out exposure returned; a site west of the host pushed it into
        // the past and the check stopped firing at all.
        final exposureStartedAt = _ref.read(clockProvider).nowUtc();
        try {
          await backend.cameraStartExposure(
            deviceId: deviceId,
            exposureTime: settings.exposureTime,
            frameType: settings.frameType,
            gain: settings.gain,
            offset: settings.offset,
            binX: settings.binningX,
            binY: settings.binningY,
          );
        } catch (e) {
          // An abort reaches the driver while this call is still blocked on the
          // exposure, so the driver reports the acquisition as failed
          // ("Exposure cancelled"). That is the abort working. Reported as a
          // capture error it put "Capture failed: Exposure cancelled" on screen
          // every time the operator pressed the X. Only a cancel THIS service
          // asked for is swallowed; every other driver failure still propagates.
          if (!_cancelRequested) rethrow;
          _logger.info(
            'Exposure ended by operator abort: $e',
            source: 'ImagingService',
          );
          _releaseSharedExposureState();
          return null;
        }
        if (!_hasBackendAuthority(backend)) return null;
        _logger.debug('cameraStartExposure returned', source: 'ImagingService');

        // Wait for exposure completion event OR timeout
        // The Completer is completed by the event listener above
        var exposureTimedOut = false;
        final completed = await exposureCompleter.future.timeout(
          timeoutDuration,
          onTimeout: () {
            // Timeout - exposure took too long, warn user but still try to retrieve image
            // Events may have been missed but image could still be available
            exposureTimedOut = true;
            _logger.warning(
              'Exposure timeout reached, checking for image...',
              source: 'ImagingService',
            );
            _ref
                .read(uiNotificationProvider.notifier)
                .showWarning(
                  'Exposure event not received in time - checking for image. Camera may be unresponsive.',
                  title: 'Exposure Timeout',
                );
            return true;
          },
        );
        if (!_hasBackendAuthority(backend)) return null;

        // Check if cancelled
        if (!completed || _cancelRequested) {
          if (_cancelRequested) {
            await _abortActiveExposure();
          }
          _releaseSharedExposureState();
          return null;
        }

        if (exposureTimedOut) {
          // The camera may genuinely still be mid-exposure (the event was
          // not merely lost). Abort it so the NEXT frame cannot collide
          // with a stuck one — aborting an already-complete exposure is a
          // harmless no-op on every backend.
          try {
            await backend.cameraAbortExposure(deviceId);
          } catch (e) {
            _logger.warning(
              'Abort after exposure timeout failed (camera may be disconnected): $e',
              source: 'ImagingService',
            );
          }
        }

        // Update to downloading state
        progressNotifier.startDownload();

        // Get the captured image from backend (remote uses JPEG wire format).
        _logger.debug(
          'Calling cameraGetLastImage (${backend is NetworkBackend ? 'remote/jpeg' : 'local'})...',
          source: 'ImagingService',
        );
        final capturedImage = await backend
            .cameraGetLastImage(deviceId)
            .timeout(
              ImagingService._imageDownloadTimeout,
              onTimeout: () {
                throw TimeoutException(
                  'Timed out retrieving image from camera after '
                  '${ImagingService._imageDownloadTimeout.inSeconds}s',
                );
              },
            );
        if (!_hasBackendAuthority(backend)) return null;
        _logger.debug(
          'cameraGetLastImage returned: ${capturedImage != null ? "${capturedImage.width}x${capturedImage.height}" : "null"}',
          source: 'ImagingService',
        );

        if (capturedImage == null) {
          throw const ImagingException(
            message: 'Failed to retrieve captured image',
            userMessage: 'Could not retrieve the captured image',
          );
        }

        _logger.debug(
          'Parsing timestamp: ${capturedImage.timestamp}',
          source: 'ImagingService',
        );
        // Capture timestamp before any processing - use try-catch for robustness
        DateTime captureTimestamp;
        try {
          captureTimestamp = parseUtcTimestamp(capturedImage.timestamp);
        } catch (e) {
          _logger.warning(
            'Failed to parse timestamp "${capturedImage.timestamp}": $e - using current time',
            source: 'ImagingService',
          );
          // Why: when the bridge timestamp is unparseable we fall back to
          // the user-chosen clock so the recovered timestamp matches the
          // rest of the session's records. It must be the same UTC instant
          // `parseUtcTimestamp` would have produced — this value becomes
          // FITS DATE-OBS and the database's capture time, and a zone-shifted
          // rendering there is an untrue observation time, not a display
          // preference.
          captureTimestamp = _ref.read(clockProvider).nowUtc();
        }
        _logger.debug(
          'Timestamp parsed: $captureTimestamp',
          source: 'ImagingService',
        );

        // FITS DATE-OBS means the START of the observation, and every
        // photometry, occultation and astrometry tool reads it that way. The
        // bridge reports when the frame finished downloading, so stamping that
        // straight into the header made DATE-OBS late by exactly EXPTIME on
        // every frame the app has ever written (measured: a 30 s exposure
        // starting 14:04:37 recorded 14:05:09).
        //
        // Derived from the camera's own timestamp rather than the host clock on
        // purpose. The hardware instant is the authoritative one, its timezone
        // handling is pinned by tests, and using `DateTime.now()` here instead
        // both bypassed that and left the file disagreeing with the database.
        final observationStartedAt = captureTimestamp.subtract(
          Duration(microseconds: (settings.exposureTime * 1e6).round()),
        );

        if (exposureTimedOut &&
            captureTimestamp.isBefore(
              exposureStartedAt.subtract(const Duration(seconds: 5)),
            )) {
          // After a timeout, the "last image" can be the PREVIOUS frame still
          // sitting in the camera buffer. Saving it would silently duplicate an
          // earlier exposure under new metadata, so this fails loudly and the
          // user/sequencer learns the frame is lost.
          throw ImagingException(
            message:
                'Exposure timed out and the camera returned a stale image '
                '(captured ${captureTimestamp.toIso8601String()}, exposure '
                'started ${exposureStartedAt.toIso8601String()}). Frame discarded.',
            userMessage: 'Exposure timed out; the frame was discarded',
          );
        }

        // IMMEDIATELY create CapturedImageData and update providers
        // This ensures the UI shows the image even if file saving fails
        _logger.debug(
          'Creating CapturedImageData...',
          source: 'ImagingService',
        );
        late CapturedImageData imageData;
        try {
          imageData = capturedImageDataFromResult(
            capturedImage: capturedImage,
            settings: settings,
            capturedAt: observationStartedAt,
            targetName: targetName,
            previewSource: backend is NetworkBackend
                ? CapturePreviewSource.remote
                : CapturePreviewSource.local,
          );
        } catch (e) {
          _logger.error(
            'Error creating CapturedImageData: $e',
            source: 'ImagingService',
          );
          rethrow; // This is a critical error, must propagate
        }

        _logger.debug(
          'CapturedImageData created, publishing JPEG preview...',
          source: 'ImagingService',
        );
        // JPEG/display buffer first; host raw loads in the background when remote.
        if (!_hasBackendAuthority(backend)) return null;
        _ref
            .read(capturePreviewPublisherProvider)
            .publish(_ref, imageData, deviceId);
        _logger.debug(
          'Preview published; raw may load in background.',
          source: 'ImagingService',
        );

        // Persisting the FITS is part of capture success. A preview in memory
        // is useful for diagnosis, but it is not an astrophotography frame the
        // user can integrate later. File-write failure therefore fails the
        // capture and stops loop callers instead of silently losing images.
        // Database indexing remains best-effort once the FITS is safely on
        // disk.
        String? savedFilePath;
        String? effectiveFilePath;
        int? dbImageId;
        bool isTempFile = false;

        try {
          // Get app settings for file path
          final appSettingsAsync = _ref.read(appSettingsProvider);
          final appSettings = appSettingsAsync.valueOrNull;

          if (persistFrame &&
              appSettings != null &&
              appSettings.imageOutputPath.isNotEmpty) {
            // Generate file path using naming pattern
            savedFilePath = await _generateImageFilePath(
              appSettings: appSettings,
              exposureSettings: settings,
              targetName: targetName,
              frameNumber: captureFrameNumber,
              timestamp: observationStartedAt,
            );
            if (!_hasBackendAuthority(backend)) return null;
          } else {
            // No output path configured - save to temp directory for annotation/plate solving
            // This ensures live annotation can still work even without a configured save location
            final tempDir = Directory.systemTemp;
            final skotiqTemp = Directory(
              path.join(tempDir.path, 'skotiq_captures'),
            );
            if (!await skotiqTemp.exists()) {
              await skotiqTemp.create(recursive: true);
            }
            if (!_hasBackendAuthority(backend)) return null;
            if (!persistFrame) {
              // A live-view frame. It still has to reach the disk so "solve the
              // latest camera frame", annotation and the preview loader keep
              // working, but it reuses ONE scratch path per camera instead
              // of accumulating: looping 5 s subs at ~23 MB a frame is
              // ~27 GB/hour of the operator's LIGHT folder, each indexed as a
              // light frame.
              savedFilePath = path.join(
                skotiqTemp.path,
                'liveview_${ImagingService._scratchKey(deviceId)}.fits',
              );
            } else {
              // Epoch millis of the real instant. `now()` renders a zone and
              // is not an instant, so its `millisecondsSinceEpoch` is a
              // fabricated number — fine for uniqueness, misleading in a
              // filename an operator may later sort by.
              final timestamp = _ref
                  .read(clockProvider)
                  .nowUtc()
                  .millisecondsSinceEpoch;
              savedFilePath = path.join(
                skotiqTemp.path,
                'capture_$timestamp.fits',
              );
            }
            isTempFile = true;
            _logger.debug(
              persistFrame
                  ? 'No output path configured, saving to temp: $savedFilePath'
                  : 'Live-view frame, using scratch path: $savedFilePath',
              source: 'ImagingService',
            );
          }

          // Call native FITS save API
          // Note: This uses the raw data still in memory on the Rust side
          await _saveFitsFile(
            backend: backend,
            deviceId: deviceId,
            filePath: savedFilePath,
            width: capturedImage.width,
            height: capturedImage.height,
            capturedImage: capturedImage,
            exposureSettings: settings,
            appSettings: appSettings,
            targetName: targetName,
            timestamp: observationStartedAt,
          );
          if (!_hasBackendAuthority(backend)) return null;

          imageData = imageData.copyWith(filePath: savedFilePath);
          final currentPreview = _ref.read(currentImageProvider);
          if (currentPreview != null &&
              currentPreview.capturedAt == imageData.capturedAt) {
            _ref.read(currentImageProvider.notifier).state = currentPreview
                .copyWith(filePath: savedFilePath);
          }
          effectiveFilePath = savedFilePath;

          // Insert into the database only for permanent saves. The FITS has
          // already been written, so an indexing failure must not misreport
          // the physical image as lost or discard its usable file path.
          if (!isTempFile && appSettings != null) {
            try {
              dbImageId = await _saveToDatabase(
                backend: backend,
                filePath: savedFilePath,
                capturedImage: capturedImage,
                exposureSettings: settings,
                appSettings: appSettings,
                targetName: targetName,
                // Same instant the FITS records as DATE-OBS. Storing the
                // download time here instead would leave the database and the
                // file it points at disagreeing about when the frame was taken,
                // by the length of the exposure -- and the session charts and
                // night grouping are built on this column.
                timestamp: observationStartedAt,
              );
              if (!_hasBackendAuthority(backend)) return null;
              // Thumbnail provenance is UI-only and remains best-effort.
              if (dbImageId != null &&
                  producingNodeId != null &&
                  producingNodeId.isNotEmpty) {
                try {
                  final records = _ref.read(imagingRecordsRepositoryProvider);
                  await records.stampProducingNode(
                    imageId: dbImageId,
                    producingNodeId: producingNodeId,
                    producingRunId: producingRunId,
                  );
                } catch (e) {
                  if (!_hasBackendAuthority(backend)) return null;
                  _logger.warning(
                    'Thumbnail: stampProducingNode failed for '
                    'image $dbImageId (node $producingNodeId): $e',
                    source: 'ImagingService',
                  );
                }
              }
            } catch (e) {
              if (!_hasBackendAuthority(backend)) return null;
              _logger.error(
                'FITS saved but database indexing failed for '
                '$savedFilePath: $e',
                source: 'ImagingService',
              );
              try {
                await _ref
                    .read(notificationServiceProvider)
                    .notifyError(
                      errorTitle: 'Image Indexing Failed',
                      errorMessage:
                          'The FITS file was saved to $savedFilePath, but it could '
                          'not be added to the image library: $e',
                      source: 'Imaging Service',
                    );
              } catch (notificationError) {
                if (!_hasBackendAuthority(backend)) return null;
                _logger.warning(
                  'Failed to send image-indexing notification: '
                  '$notificationError',
                  source: 'ImagingService',
                );
              }
              if (!_hasBackendAuthority(backend)) return null;
            }
          }
        } catch (e) {
          if (!_hasBackendAuthority(backend)) return null;
          _logger.error('Error saving image: $e', source: 'ImagingService');

          try {
            await _ref
                .read(notificationServiceProvider)
                .notifyError(
                  errorTitle: 'Image Save Failed',
                  errorMessage:
                      'Failed to save FITS file${savedFilePath != null ? ' to $savedFilePath' : ''}: $e',
                  source: 'Imaging Service',
                );
          } catch (notificationError) {
            if (!_hasBackendAuthority(backend)) return null;
            _logger.warning(
              'Failed to send image-save notification: $notificationError',
              source: 'ImagingService',
            );
          }
          if (!_hasBackendAuthority(backend)) return null;

          throw ImagingException(
            message:
                'Captured frame could not be saved${savedFilePath != null ? ' to $savedFilePath' : ''}: $e',
            userMessage:
                'The captured frame could not be saved. Check the output '
                'folder and available disk space before retrying.',
            deviceId: deviceId,
          );
        }

        _logger.debug('FITS save complete.', source: 'ImagingService');

        // Auto-calibration: apply dark/flat/bias correction if enabled
        // Only calibrate light frames - darks, flats, and biases should not be calibrated
        if (savedFilePath.isNotEmpty &&
            !isTempFile &&
            settings.frameType == FrameType.light) {
          try {
            final calSettings = _ref.read(calibrationSettingsProvider);
            if (calSettings.autoCalibrate) {
              _logger.info(
                'Auto-calibrating: $savedFilePath',
                source: 'ImagingService',
              );
              final calibrationService = _ref.read(calibrationServiceProvider);
              final calResult = await calibrationService.calibrateFile(
                lightPath: savedFilePath,
                settings: calSettings,
                exposureTime: settings.exposureTime,
                gain: settings.gain,
                offset: settings.offset,
                binX: settings.binningX,
                binY: settings.binningY,
                sensorTemperature: cameraState.temperature,
              );
              if (!_hasBackendAuthority(backend)) return null;
              _logger.info(
                'Calibration complete: dark=${calResult.darkApplied}, '
                'flat=${calResult.flatApplied}, bias=${calResult.biasApplied} '
                '-> ${calResult.outputPath}',
                source: 'ImagingService',
              );
              effectiveFilePath = calResult.outputPath;

              if (dbImageId != null && effectiveFilePath != savedFilePath) {
                await _ref
                    .read(imagingRecordsRepositoryProvider)
                    .updateImageFilePath(dbImageId, effectiveFilePath);
                if (!_hasBackendAuthority(backend)) return null;
              }

              imageData = imageData.copyWith(filePath: effectiveFilePath);
              final currentPreview = _ref.read(currentImageProvider);
              if (currentPreview != null &&
                  currentPreview.capturedAt == imageData.capturedAt) {
                _ref.read(currentImageProvider.notifier).state = currentPreview
                    .copyWith(filePath: effectiveFilePath);
              }
            }
          } catch (e) {
            if (!_hasBackendAuthority(backend)) return null;
            // Calibration failure should not prevent the capture from succeeding.
            // Log and notify the user, but do not lose the uncalibrated image.
            _logger.error(
              'Auto-calibration failed: $e',
              source: 'ImagingService',
            );
            final notificationService = _ref.read(notificationServiceProvider);
            await notificationService.notifyError(
              errorTitle: 'Auto-Calibration Failed',
              errorMessage:
                  'Failed to calibrate $savedFilePath: ${e.toString()}',
              source: 'Calibration',
            );
            if (!_hasBackendAuthority(backend)) return null;
          }
        }

        final processedFilePath = effectiveFilePath ?? savedFilePath;
        if (!_hasBackendAuthority(backend)) return null;
        // Live-view frames are scratch, so they get neither science processing
        // nor a place in the session's frame list — the same rule the
        // `captured_images` insert above already follows. Without this a
        // framing loop still inflated the session's frame count and queued
        // photometry on a throwaway file that the next frame overwrites.
        if (persistFrame && processedFilePath.isNotEmpty) {
          final sessionState = _ref.read(sessionStateProvider);
          // Science processing is informational-only and runs in background.
          unawaited(
            _ref
                .read(scienceProcessingServiceProvider)
                .processCapturedFrame(
                  imagePath: processedFilePath,
                  deviceId: deviceId,
                  capturedImageId: dbImageId,
                  sessionId: sessionState.dbSessionId,
                ),
          );
        }

        // Store as session image. Keepers only, per the note above.
        try {
          if (persistFrame) {
            _ref
                .read(sessionImagesProvider.notifier)
                .addImage(
                  CapturedImage(
                    id:
                        dbImageId?.toString() ??
                        DateTime.now().millisecondsSinceEpoch.toString(),
                    filePath: processedFilePath,
                    capturedAt: imageData.capturedAt,
                    settings: settings,
                    stats: imageData.stats,
                    targetName: targetName,
                  ),
                );
          }
        } catch (e) {
          _logger.warning(
            'Error adding to session images: $e',
            source: 'ImagingService',
          );
          // Non-critical, continue
        }

        // Reset state BEFORE returning so UI updates immediately
        // Don't rely only on finally block since eventSubscription.cancel() may hang
        _logger.debug(
          'Resetting capture state before return...',
          source: 'ImagingService',
        );
        _isCapturing = false;
        _releaseSharedExposureState();
        _logger.debug(
          'State reset, returning imageData from captureImage',
          source: 'ImagingService',
        );
        return imageData;
      } finally {
        _logger.debug(
          'Inner finally: cancelling event subscription',
          source: 'ImagingService',
        );
        // Add timeout to prevent hanging
        try {
          await eventSubscription.cancel().timeout(
            const Duration(seconds: 2),
            onTimeout: () {
              _logger.warning(
                'eventSubscription.cancel() timed out',
                source: 'ImagingService',
              );
            },
          );
        } catch (e) {
          _logger.warning(
            'Error cancelling event subscription: $e',
            source: 'ImagingService',
          );
        }
        _logger.debug('Inner finally complete', source: 'ImagingService');
      }
    } finally {
      // This is a safety net - state should already be reset above
      // but ensure it happens even on exceptions
      _logger.debug(
        'Outer finally: ensuring state is reset',
        source: 'ImagingService',
      );
      _isCapturing = false;
      _activeExposureCompleter = null;
      _activeCaptureBackend = null;
      _activeCaptureDeviceId = null;
      _activeAbortFuture = null;
      _releaseSharedExposureState();
      _logger.debug('captureImage complete!', source: 'ImagingService');
    }
  }
}
