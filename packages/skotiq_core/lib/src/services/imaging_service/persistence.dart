part of '../imaging_service.dart';

extension _ImagingServicePersistence on ImagingService {
  /// Saves the keeper at [filePath], or with no [filePath] a scratch frame
  /// named [scratchName]. Returns the path the frame is recorded by (see
  /// [ImagingBackend.saveFitsFromLastCapture]), or null when this backend no
  /// longer has authority.
  Future<String?> _saveFitsFile({
    required SkotiqBackend backend,
    required String deviceId,
    required String? filePath,
    String? scratchName,
    required ExposureSettings exposureSettings,
    String? targetName,
    required DateTime timestamp,
    required bool keepCameraFile,
  }) async {
    if (!_hasBackendAuthority(backend)) return null;

    // The host reads the rig when it writes the file, as it does for a
    // sequence's frame; this carries only what the devices cannot say.
    final header = await manualFrameHeader(
      _ref,
      objectName: targetName,
      exposureTime: exposureSettings.exposureTime,
      startedAtUtc: timestamp,
      frameType: exposureSettings.frameType.imageType,
      filter: exposureSettings.filter,
      gain: exposureSettings.gain,
      offset: exposureSettings.offset,
      binX: exposureSettings.binningX,
      binY: exposureSettings.binningY,
    );

    if (!_hasBackendAuthority(backend)) return null;
    if (filePath == null) {
      return backend.saveScratchFrameFromLastCapture(
        deviceId: deviceId,
        name: scratchName!,
        headerData: header,
      );
    }
    return backend.saveFitsFromLastCapture(
      deviceId: deviceId,
      filePath: filePath,
      headerData: header,
      keepCameraFile: keepCameraFile,
    );
  }

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
    final records = _ref.read(imagingRecordsProvider);

    final sessionState = _ref.read(sessionStateProvider);
    final sessionId = sessionState.dbSessionId;

    final cameraState = _ref.read(cameraStateProvider);
    final sensitivity = _ref.read(cameraSensitivityProvider);
    final commanded = sensitivity.commanded(
      gain: exposureSettings.gain,
      offset: exposureSettings.offset,
    );
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
    // A companion's frame is written on the imaging host, at a host path this
    // machine cannot open.
    if (backend.remoteHost == null) {
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
    }
    if (!_hasBackendAuthority(backend)) return null;

    final companion = CapturedImagesCompanion(
      filePath: drift.Value(filePath),
      fileName: drift.Value(path.basename(filePath)),
      fileFormat: drift.Value(frameFileFormatOf(filePath).recordName),
      fileSize: drift.Value(fileSize),
      sessionId: drift.Value(sessionId),
      targetId: const drift.Value(null), // Link to target if available
      frameType: drift.Value(exposureSettings.frameType.name),
      exposureDuration: drift.Value(exposureSettings.exposureTime),
      // A control the camera does not have (offset on a DSLR, gain on some
      // CCDs) records none, as the file's header does.
      gain: drift.Value(commanded.gain),
      gainKind: drift.Value(sensitivity.gainKind.recordName),
      offset: drift.Value(commanded.offset),
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

    // A frame the sequencer stores gets its thumbnail from
    // `insertSequenceFrame`; this is the ad-hoc capture path.
    if (_hasBackendAuthority(backend) && filePath.isNotEmpty) {
      try {
        records.scheduleThumbnail(imageId: imageId, fitsPath: filePath);
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
