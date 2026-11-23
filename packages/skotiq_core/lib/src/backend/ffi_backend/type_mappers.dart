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
