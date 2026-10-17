part of '../ffi_backend.dart';

extension _FfiBackendTypeMappers on _FfiBackendBase {
  // FRB->Dart Type Mappers

  /// Convert pure Dart FitsWriteHeader to bridge FitsWriteHeader
  bridge.FitsWriteHeader _toBridgeFitsHeader(FitsWriteHeader h) {
    return bridge.FitsWriteHeader(
      objectName: h.objectName,
      exposureTime: h.exposureTime,
      captureTimestamp: h.captureTimestamp,
      frameType: h.frameType,
      filter: h.filter,
      gain: h.gain,
      offset: h.offset,
      ccdTemp: h.ccdTemp,
      ra: h.ra,
      dec: h.dec,
      altitude: h.altitude,
      telescope: h.telescope,
      instrument: h.instrument,
      observer: h.observer,
      binX: h.binX ?? 1, // Default to 1x1 binning
      binY: h.binY ?? 1,
      focalLength: h.focalLength,
      aperture: h.aperture,
      pixelSizeX: h.pixelSizeX,
      pixelSizeY: h.pixelSizeY,
      siteLatitude: h.siteLatitude,
      siteLongitude: h.siteLongitude,
      siteElevation: h.siteElevation,
    );
  }

  /// Convert bridge AutofocusResultApi to pure Dart AutofocusResult
  AutofocusResult _fromBridgeAutofocusResult(bridge_api.AutofocusResultApi r) {
    return AutofocusResult(
      bestPosition: r.bestPosition,
      bestHfr: r.bestHfr,
      focusData: r.focusData
          .map(
            (dp) => FocusDataPoint(
              position: dp.position,
              hfr: dp.hfr,
              fwhm: dp.fwhm,
              starCount: dp.starCount,
            ),
          )
          .toList(),
      method: r.method,
      temperature: r.temperature,
      timestamp: r.timestamp,
      curveFitQuality: r.curveFitQuality,
      backlashApplied: r.backlashApplied,
    );
  }

  /// Convert bridge CameraCapabilities to pure Dart CameraCapabilities
  CameraCapabilities _fromBridgeCameraCapabilities(
    bridge_caps.CameraCapabilities c,
  ) {
    return CameraCapabilities(
      maxWidth: c.maxWidth,
      maxHeight: c.maxHeight,
      bitDepth: c.bitDepth,
      hasShutter: c.hasShutter,
      canSetCcdTemperature: c.canSetCcdTemperature,
      canSetCooler: c.canSetCooler,
      canGetCoolerPower: c.canGetCoolerPower,
      canBin: c.canBin,
      maxBinX: c.maxBinX,
      maxBinY: c.maxBinY,
      canAsymmetricBin: c.canAsymmetricBin,
      canSetGain: c.canSetGain,
      gainMin: c.gainMin,
      gainMax: c.gainMax,
      canSetOffset: c.canSetOffset,
      offsetMin: c.offsetMin,
      offsetMax: c.offsetMax,
      canAbortExposure: c.canAbortExposure,
      canStopExposure: c.canStopExposure,
      canSubframe: c.canSubframe,
      pixelSizeX: c.pixelSizeX,
      pixelSizeY: c.pixelSizeY,
      isColor: c.isColor,
      bayerPattern: c.bayerPattern,
      sensorType: c.sensorType,
      hasFastReadout: c.hasFastReadout,
      readoutModes: c.readoutModes,
      exposureMin: c.exposureMin,
      exposureMax: c.exposureMax,
      ccdTemperature: c.ccdTemperature,
      setCcdTemperature: c.setCcdTemperature,
      coolerPower: c.coolerPower,
      coolerOn: c.coolerOn,
      coolerMinTempC: c.coolerMinTempC,
      coolerMaxTempC: c.coolerMaxTempC,
    );
  }

  /// Convert bridge MountCapabilities to pure Dart MountCapabilities
  MountCapabilities _fromBridgeMountCapabilities(
    bridge_caps.MountCapabilities m,
  ) {
    return MountCapabilities(
      canSlew: m.canSlew,
      canSlewAsync: m.canSlewAsync,
      canSync: m.canSync,
      canPark: m.canPark,
      canUnpark: m.canUnpark,
      canSetPark: m.canSetPark,
      canPulseGuide: m.canPulseGuide,
      canGetSideOfPier: m.canGetSideOfPier,
      canSetSideOfPier: m.canSetSideOfPier,
      canSetTracking: m.canSetTracking,
      canSetTrackingRate: m.canSetTrackingRate,
      supportedTrackingRates: m.supportedTrackingRates
          .map((r) => _fromBridgeTrackingRate(r))
          .toList(),
      isEquatorial: m.isEquatorial,
      supportsAltAz: m.supportsAltAz,
      canGetPointingState: m.canGetPointingState,
      canFindHome: m.canFindHome,
      tracking: m.tracking,
      trackingRate: m.trackingRate != null
          ? _fromBridgeTrackingRate(m.trackingRate!)
          : null,
      canAbortSlew: m.canAbortSlew,
      maxSlewRate: m.maxSlewRate,
      canMoveAxis: m.canMoveAxis,
      axisCount: m.axisCount,
      minPulseGuideMs: m.minPulseGuideMs,
      maxPulseGuideMs: m.maxPulseGuideMs,
    );
  }

  /// Convert bridge FocuserCapabilities to pure Dart FocuserCapabilities
  FocuserCapabilities _fromBridgeFocuserCapabilities(
    bridge_caps.FocuserCapabilities f,
  ) {
    return FocuserCapabilities(
      maxPosition: f.maxPosition,
      maxIncrement: f.maxIncrement,
      stepSize: f.stepSize,
      absolute: f.absolute,
      tempCompAvailable: f.tempCompAvailable,
      tempComp: f.tempComp,
      temperature: f.temperature,
      isMoving: f.isMoving,
      position: f.position,
      canHalt: f.canHalt,
      canReverse: f.canReverse,
      reverse: f.reverse,
    );
  }

  /// Convert bridge FilterWheelCapabilities to pure Dart FilterWheelCapabilities
  FilterWheelCapabilities _fromBridgeFilterWheelCapabilities(
    bridge_caps.FilterWheelCapabilities fw,
  ) {
    return FilterWheelCapabilities(
      positionCount: fw.positionCount,
      currentPosition: fw.currentPosition,
      filterNames: fw.filterNames,
      focusOffsets: fw.focusOffsets,
      isMoving: fw.isMoving,
      canSetFilterNames: fw.canSetFilterNames,
      canSetFocusOffsets: fw.canSetFocusOffsets,
    );
  }

  /// Convert bridge RotatorCapabilities to pure Dart RotatorCapabilities
  RotatorCapabilities _fromBridgeRotatorCapabilities(
    bridge_caps.RotatorCapabilities r,
  ) {
    return RotatorCapabilities(
      canReverse: r.canReverse,
      reverse: r.reverse,
      stepSize: r.stepSize,
      isMoving: r.isMoving,
      mechanicalPosition: r.mechanicalPosition,
      position: r.position,
      canMoveAbsolute: r.canMoveAbsolute,
      canHalt: r.canHalt,
      canSync: r.canSync,
      minAngleDeg: r.minAngleDeg,
      maxAngleDeg: r.maxAngleDeg,
    );
  }

  // Error conversion

  /// Convert any exception to a structured SkotiqError.
  ///
  /// This handles:
  /// - FRB-generated SkotiqError (from Rust)
  /// - AnyhowException (fallback from Rust)
  /// - Generic Dart exceptions
  dart_error.SkotiqError _toSkotiqError(Object exception, [String? context]) {
    // Handle FRB-generated SkotiqError from Rust
    if (exception is bridge_error.SkotiqError) {
      return _fromBridgeSkotiqError(exception);
    }

    // Handle generic exceptions with context
    final message = context != null
        ? '$context: ${exception.toString()}'
        : exception.toString();

    return dart_error.SkotiqError.fromString(message);
  }

  /// Convert FRB-generated SkotiqError to pure Dart SkotiqError.
  ///
  /// This preserves all the structured error information from Rust.
  dart_error.SkotiqError _fromBridgeSkotiqError(bridge_error.SkotiqError e) {
    return e.when(
      // Connection errors
      deviceNotFound: (deviceId) =>
          dart_error.SkotiqError.deviceNotFound(deviceId),
      connectionFailed: (deviceId, reason) =>
          dart_error.SkotiqError.connectionFailed(deviceId, reason),
      alreadyConnected: (deviceId) => dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.connection,
        message: 'Device already connected: $deviceId',
        userMessage: "'$deviceId' is already connected",
        deviceId: deviceId,
      ),
      notConnected: (deviceId) => dart_error.SkotiqError.notConnected(deviceId),
      deviceDisconnected: (deviceId, reason) =>
          dart_error.SkotiqError.deviceDisconnected(deviceId, reason),

      // Hardware errors
      hardwareError: (deviceId, message, errorCode) =>
          dart_error.SkotiqError.hardwareError(
            deviceId,
            message,
            errorCode: errorCode,
          ),
      communicationError: (deviceId, message) => dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.hardware,
        message: 'Communication error: $deviceId - $message',
        userMessage: "Communication error with '$deviceId'",
        isRecoverable: true,
        shouldReconnect: true,
        deviceId: deviceId,
      ),

      // Timeout errors
      timeout: (message) => dart_error.SkotiqError.timeout(message),
      deviceTimeout: (deviceId, operation, timeoutSecs) =>
          dart_error.SkotiqError.timeout(
            operation,
            deviceId: deviceId,
            timeoutSecs: timeoutSecs,
          ),
      connectionTimeout: (deviceId, timeoutSecs) => dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.timeout,
        message:
            'Connection timeout: $deviceId after ${timeoutSecs.toStringAsFixed(1)}s',
        userMessage: "Connection to '$deviceId' timed out",
        isRecoverable: true,
        isTimeout: true,
        shouldReconnect: true,
        deviceId: deviceId,
      ),

      // Validation errors
      invalidParameter: (message) => dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.validation,
        message: 'Invalid parameter: $message',
      ),
      invalidInput: (message) => dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.validation,
        message: 'Invalid input: $message',
      ),
      invalidDeviceId: (deviceId, reason) => dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.validation,
        message: 'Invalid device ID: $deviceId - $reason',
        deviceId: deviceId,
      ),
      parameterOutOfRange: (paramName, value, min, max) => dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.validation,
        message:
            'Parameter out of range: $paramName = $value (valid: $min to $max)',
        userMessage: '$paramName value $value is out of range ($min to $max)',
      ),

      // Operation errors
      operationFailed: (message) => dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.system,
        message: 'Operation failed: $message',
        isRecoverable: true,
      ),
      notSupported: (deviceId, operation) =>
          dart_error.SkotiqError.notSupported(deviceId, operation),
      deviceBusy: (deviceId, currentOperation) =>
          dart_error.SkotiqError.deviceBusy(deviceId, currentOperation),

      // Imaging errors
      imageError: (message) => dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.imaging,
        message: 'Image error: $message',
      ),
      cameraError: (message) => dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.imaging,
        message: 'Camera error: $message',
      ),
      noImageAvailable: () => const dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.imaging,
        message: 'No image available',
      ),
      exposureCancelled: () => dart_error.SkotiqError.cancelled(),
      exposureFailed: (cameraId, reason) => dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.imaging,
        message: 'Exposure failed: $cameraId - $reason',
        userMessage: "Exposure failed on '$cameraId'",
        deviceId: cameraId,
      ),
      downloadFailed: (cameraId, reason) => dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.imaging,
        message: 'Image download failed: $cameraId - $reason',
        deviceId: cameraId,
      ),

      // I/O errors
      ioError: (message) => dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.io,
        message: 'I/O error: $message',
      ),
      serializationError: (message) => dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.io,
        message: 'Serialization error: $message',
      ),
      plateSolveError: (message) => dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.io,
        message: 'Plate solve failed: $message',
      ),

      // Sequence errors
      sequenceError: (message) => dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.sequence,
        message: 'Sequence error: $message',
      ),

      // Driver-specific errors
      ascomError: (progId, message, errorCode) => dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.driver,
        message: 'ASCOM error: $progId - $message (code: $errorCode)',
        errorCode: errorCode,
      ),
      alpacaError: (baseUrl, deviceNumber, message, errorCode) =>
          dart_error.SkotiqError(
            category: dart_error.BackendErrorCategory.driver,
            message:
                'Alpaca error: $baseUrl device $deviceNumber - $message (code: $errorCode)',
            errorCode: errorCode,
          ),
      indiError: (server, port, deviceName, message) => dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.driver,
        message: 'INDI error: $server:$port device $deviceName - $message',
      ),
      nativeError: (vendor, message, errorCode) => dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.driver,
        message: 'Native SDK error: $vendor - $message (code: $errorCode)',
        errorCode: errorCode,
      ),
      comError: (message, hresult) => dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.driver,
        message:
            'COM error: $message (HRESULT: 0x${hresult.toRadixString(16).padLeft(8, '0')})',
        errorCode: hresult,
        shouldReconnect: true,
      ),

      // System errors
      internal: (message) => dart_error.SkotiqError.internal(message),
      cancelled: () => dart_error.SkotiqError.cancelled(),
      runtimeInitFailed: (message) => dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.system,
        message: 'Runtime initialization failed: $message',
      ),
      resourceExhausted: (resource, message) => dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.system,
        message: 'Resource exhausted: $resource - $message',
        isRecoverable: true,
      ),
    );
  }
}
