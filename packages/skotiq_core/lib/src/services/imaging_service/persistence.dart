part of '../imaging_service.dart';

extension _ImagingServicePersistence on ImagingService {
  Future<void> _saveFitsFile({
    required SkotiqBackend backend,
    required String deviceId,
    required String filePath,
    required int width,
    required int height,
    required CapturedImageResult capturedImage,
    required ExposureSettings exposureSettings,
    AppSettingsState? appSettings,
    String? targetName,
    required DateTime timestamp,
  }) async {
    if (!_hasBackendAuthority(backend)) return;

    // Get equipment states for header metadata
    final cameraState = _ref.read(cameraStateProvider);
    final mountState = _ref.read(mountStateProvider);
    String? telescope;
    double? focalLength;
    double? aperture;
    if (backend is NetworkBackend) {
      final activeProfile = await backend.getActiveProfile();
      if (!_hasBackendAuthority(backend)) return;
      if (activeProfile != null) {
        telescope = activeProfile.telescopeName ?? activeProfile.name;
        focalLength = activeProfile.focalLength > 0
            ? activeProfile.focalLength
            : activeProfile.telescopeFocalLength;
        aperture = activeProfile.aperture > 0
            ? activeProfile.aperture
            : activeProfile.telescopeAperture;
      }
    } else {
      final profilesDao = _ref.read(equipmentProfilesDaoProvider);
      final activeProfile = await profilesDao.getActiveProfile();
      if (!_hasBackendAuthority(backend)) return;
      telescope = activeProfile?.telescopeName ?? activeProfile?.name;
      focalLength = activeProfile?.focalLength;
      aperture = activeProfile?.aperture;
    }
    final hasConfiguredSite = appSettings?.isLocationSet ?? false;
    final observerName = appSettings?.observerName.trim();

    // XPIXSZ/YPIXSZ describe the detector and the driver is the only place
    // that knows them — the `equipment_profiles` table has no pixel-size
    // column. Without them a frame carries FOCALLEN but no pixel pitch, so
    // ASTAP, PixInsight and AstroBin cannot derive the plate scale from the
    // file alone.
    //
    // The Rust writer multiplies these by XBINNING/YBINNING, so the UNBINNED
    // sensor pitch is what belongs here. Each axis is written only when the
    // driver reports a positive value: a camera that reports one axis gets one
    // card rather than a fabricated square-pixel assumption, and a driver that
    // reports 0.0 for "unknown" gets none.
    final (pixelSizeX, pixelSizeY) = await _sensorPixelPitchMicrons(
      backend: backend,
      deviceId: deviceId,
    );
    if (!_hasBackendAuthority(backend)) return;

    // Build FITS header with complete metadata
    final header = FitsWriteHeader(
      objectName: targetName,
      exposureTime: exposureSettings.exposureTime,
      captureTimestamp: timestamp
          .toUtc()
          .toIso8601String(), // Use UTC for FITS standard
      frameType: exposureSettings
          .frameType
          .displayName, // Use display name for FITS standard
      filter: exposureSettings.filter,
      gain: exposureSettings.gain,
      offset: exposureSettings.offset,
      ccdTemp: cameraState.temperature,
      ra: mountState.ra,
      dec: mountState.dec,
      altitude: mountState.altitude,
      telescope: telescope,
      instrument: cameraState.deviceName, // Use connected camera name
      observer: observerName == null || observerName.isEmpty
          ? null
          : observerName,
      binX: exposureSettings.binningX,
      binY: exposureSettings.binningY,
      focalLength: focalLength,
      aperture: aperture,
      pixelSizeX: pixelSizeX,
      pixelSizeY: pixelSizeY,
      siteLatitude: hasConfiguredSite ? appSettings!.latitude : null,
      siteLongitude: hasConfiguredSite ? appSettings!.longitude : null,
      // Sea level is real metadata, not an unset sentinel. Once the lat/long
      // pair establishes a configured site, preserve elevation even at 0 m.
      siteElevation: hasConfiguredSite ? appSettings!.elevation : null,
    );

    // Use the optimized API that saves directly from Rust-side stored image data
    // This avoids the expensive raw data roundtrip (Rust -> Dart -> Rust)
    if (!_hasBackendAuthority(backend)) return;
    await backend.saveFitsFromLastCapture(
      deviceId: deviceId,
      filePath: filePath,
      headerData: header,
    );
  }

  /// The connected camera's unbinned pixel pitch in microns, per axis.
  ///
  /// A camera that reports nothing yields `(null, null)`. So does a capability
  /// query that fails here: a genuine driver fault has already aborted the
  /// exposure at the readout-mode step, so the only way to reach this catch is
  /// a late invalidation, and by then the FITS is on its way to disk — a
  /// missing header card must never turn a captured frame into a failed one.
  Future<(double?, double?)> _sensorPixelPitchMicrons({
    required SkotiqBackend backend,
    required String deviceId,
  }) async {
    if (deviceId.isEmpty) return (null, null);
    try {
      final caps = await _ref.read(
        equipmentCameraCapabilitiesProvider(deviceId).future,
      );
      double? micronsOrNull(double? value) =>
          value != null && value > 0 ? value : null;
      return (micronsOrNull(caps?.pixelSizeX), micronsOrNull(caps?.pixelSizeY));
    } catch (e) {
      _logger.warning(
        'Camera $deviceId did not report a pixel size ($e) — the FITS will '
        'omit XPIXSZ/YPIXSZ',
        source: 'ImagingService',
      );
      return (null, null);
    }
  }

  /// Save image metadata to database
  Future<int?> _saveToDatabase({
    required SkotiqBackend backend,
    required String filePath,
    required CapturedImageResult capturedImage,
    required ExposureSettings exposureSettings,
    required AppSettingsState appSettings,
    String? targetName,
    required DateTime timestamp,
  }) async {
    if (!_hasBackendAuthority(backend)) return null;
    final records = _ref.read(imagingRecordsRepositoryProvider);

    // Get current session ID if available
    final sessionState = _ref.read(sessionStateProvider);
    final sessionId = sessionState.dbSessionId;

    // Get equipment states
    final cameraState = _ref.read(cameraStateProvider);
    final mountState = _ref.read(mountStateProvider);
    final focuserState = _ref.read(focuserStateProvider);
    final rotatorState = _ref.read(rotatorStateProvider);
    final guiderState = _ref.read(guiderStateProvider);

    // Calculate quality score using Rust implementation
    final qualityScore = _calculateQualityScore(
      hfr: capturedImage.stats.hfr,
      starCount: capturedImage.stats.starCount,
      mean: capturedImage.stats.mean,
      stdDev: capturedImage.stats.stdDev,
    );

    // Stat the on-disk file BEFORE inserting so the row carries
    // a real byte count. The caller's _saveFitsFile() finishes writing
    // the FITS synchronously before we get here, so the file is on disk.
    // If the stat fails (permissions, race with external deletion), the
    // row goes in with NULL size — the size is auxiliary metadata, the
    // row itself must be written so the capture is recorded.
    int? fileSize;
    try {
      fileSize = await File(filePath).length();
    } catch (e) {
      if (!_hasBackendAuthority(backend)) return null;
      _logger.warning(
        'Failed to stat captured FITS for size: $filePath ($e) — '
        'row will be inserted with NULL file_size',
        source: 'ImagingService',
      );
    }
    if (!_hasBackendAuthority(backend)) return null;

    // Create image record with complete metadata
    final companion = CapturedImagesCompanion(
      filePath: drift.Value(filePath),
      fileName: drift.Value(path.basename(filePath)),
      fileFormat: const drift.Value('fits'),
      fileSize: drift.Value(fileSize),
      sessionId: drift.Value(sessionId),
      targetId: const drift.Value(null), // Link to target if available
      frameType: drift.Value(exposureSettings.frameType.name),
      exposureDuration: drift.Value(exposureSettings.exposureTime),
      gain: drift.Value(exposureSettings.gain),
      offset: drift.Value(exposureSettings.offset),
      binX: drift.Value(exposureSettings.binningX),
      binY: drift.Value(exposureSettings.binningY),
      filter: drift.Value(exposureSettings.filter),
      sensorTemp: drift.Value(cameraState.temperature),
      coolerPower: drift.Value(cameraState.coolerPower),
      hfr: drift.Value(capturedImage.stats.hfr),
      starCount: drift.Value(capturedImage.stats.starCount.toInt()),
      background: drift.Value(capturedImage.stats.mean),
      noise: drift.Value(capturedImage.stats.stdDev),
      qualityScore: drift.Value(qualityScore),
      guidingRmsRa: drift.Value(guiderState.rmsRa),
      guidingRmsDec: drift.Value(guiderState.rmsDec),
      guidingRmsTotal: drift.Value(guiderState.rmsTotal),
      mountRa: drift.Value(mountState.ra),
      mountDec: drift.Value(mountState.dec),
      mountAltitude: drift.Value(mountState.altitude),
      mountAzimuth: drift.Value(mountState.azimuth),
      pierSide: const drift.Value(null),
      focuserPosition: drift.Value(focuserState.position),
      focuserTemp: drift.Value(focuserState.temperature),
      rotatorAngle: drift.Value(rotatorState.position),
      isPlateSolved: const drift.Value(false),
      solvedRa: const drift.Value(null),
      solvedDec: const drift.Value(null),
      solvedRotation: const drift.Value(null),
      solvedPixelScale: const drift.Value(null),
      capturedAt: drift.Value(timestamp),
      isAccepted: const drift.Value(true),
      rejectionReason: const drift.Value(null),
    );

    final imageId = await records.createImage(companion);
    if (!_hasBackendAuthority(backend)) return null;

    final eccentricity = capturedImage.stats.eccentricity;
    final fwhm = capturedImage.stats.fwhm;
    if (eccentricity != null || fwhm != null) {
      try {
        await records.stampProducingNode(
          imageId: imageId,
          eccentricity: eccentricity,
          fwhm: fwhm,
        );
      } catch (e) {
        if (!_hasBackendAuthority(backend)) return null;
        _logger.warning(
          'Failed to stamp eccentricity for image $imageId ($filePath): $e',
          source: 'ImagingService',
        );
      }
      if (!_hasBackendAuthority(backend)) return null;
    }

    // Schedule fire-and-forget sidecar generation for ad-hoc
    // captures (the sequencer-driven path goes through
    // `insertSequenceFrame` which schedules its own sidecar). Local-only:
    // the remote-companion case is handled by the host's headless server
    // when it processes the `POST /api/images` request (see
    // `session_handlers.dart::handleCreateImage`). We probe `_imagesDao`
    // indirectly via the provider — when running against a remote
    // backend the provider still points at the local (empty) DB, but the
    // sidecar service is a no-op on an unreachable path so the
    // ergonomics are the same.
    if (_hasBackendAuthority(backend) &&
        !records.isRemote &&
        filePath.isNotEmpty) {
      try {
        final sidecarService = _ref.read(thumbnailSidecarServiceProvider);
        final ImagesDao imagesDao = _ref.read(imagesDaoProvider);
        sidecarService.scheduleSidecarWrite(
          imageId: imageId,
          fitsPath: filePath,
          imagesDao: imagesDao,
        );
      } catch (e) {
        _logger.warning(
          'Failed to schedule sidecar for image $imageId ($filePath): $e',
          source: 'ImagingService',
        );
      }
    }

    return imageId;
  }
}
