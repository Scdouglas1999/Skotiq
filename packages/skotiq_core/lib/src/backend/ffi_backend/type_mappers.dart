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
      isoSpeeds: c.isoSpeeds.toList(),
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
      return skotiqErrorFromBridge(exception);
    }

    final message = context != null
        ? '$context: ${exception.toString()}'
        : exception.toString();

    return dart_error.SkotiqError.fromString(message);
  }
}
