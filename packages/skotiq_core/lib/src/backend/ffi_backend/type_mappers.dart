part of '../ffi_backend.dart';

extension _FfiBackendTypeMappers on _FfiBackendBase {
  bridge.FitsWriteHeader _toBridgeFitsHeader(FitsWriteHeader h) {
    return bridge.FitsWriteHeader(
      objectName: h.objectName,
      exposureTime: h.exposureTime,
      frameType: h.frameType,
      filter: h.filter,
      gain: h.gain,
      offset: h.offset,
      binX: h.binX ?? 1,
      binY: h.binY ?? 1,
      telescope: h.telescope,
      instrument: h.instrument,
      observer: h.observer,
      focalLength: h.focalLength,
      aperture: h.aperture,
      siteLatitude: h.siteLatitude,
      siteLongitude: h.siteLongitude,
      siteElevation: h.siteElevation,
      mountId: h.mountId,
      focuserId: h.focuserId,
      filterWheelId: h.filterWheelId,
      rotatorId: h.rotatorId,
    );
  }

  AutofocusResult _fromBridgeAutofocusResult(bridge.AutofocusResultApi r) {
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

  CameraCapabilities _fromBridgeCameraCapabilities(
    bridge.CameraCapabilities c,
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

  MountCapabilities _fromBridgeMountCapabilities(bridge.MountCapabilities m) {
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

  FocuserCapabilities _fromBridgeFocuserCapabilities(
    bridge.FocuserCapabilities f,
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

  FilterWheelCapabilities _fromBridgeFilterWheelCapabilities(
    bridge.FilterWheelCapabilities fw,
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

  RotatorCapabilities _fromBridgeRotatorCapabilities(
    bridge.RotatorCapabilities r,
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

  /// Convert any exception to a structured SkotiqError.
  ///
  /// This handles:
  /// - FRB-generated SkotiqError (from Rust)
  /// - AnyhowException (fallback from Rust)
  /// - Generic Dart exceptions
  dart_error.SkotiqError _toSkotiqError(Object exception, [String? context]) {
    if (exception is bridge.SkotiqError) {
      return _fromBridgeSkotiqError(exception);
    }

    final message = context != null
        ? '$context: ${exception.toString()}'
        : exception.toString();

    return dart_error.SkotiqError.fromString(message);
  }

  /// Convert FRB-generated SkotiqError to pure Dart SkotiqError.
  ///
  /// This preserves all the structured error information from Rust.
  dart_error.SkotiqError _fromBridgeSkotiqError(bridge.SkotiqError e) {
    return e.when(
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

      operationFailed: (message) => dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.system,
        message: 'Operation failed: $message',
        isRecoverable: true,
      ),
      notSupported: (deviceId, operation) =>
          dart_error.SkotiqError.notSupported(deviceId, operation),
      deviceBusy: (deviceId, currentOperation) =>
          dart_error.SkotiqError.deviceBusy(deviceId, currentOperation),

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

      sequenceError: (message) => dart_error.SkotiqError(
        category: dart_error.BackendErrorCategory.sequence,
        message: 'Sequence error: $message',
      ),

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
