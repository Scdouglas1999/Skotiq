/// Device capabilities as the FFI backend reads them from the bridge. The
/// bridge contract test (`test/models/backend/device_bridge_contract_test.dart`)
/// constructs every FRB capability type here with named arguments.
library;

import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

import 'device_capabilities.dart';
import 'device_status_bridge.dart' show trackingRateFromBridge;

CameraCapabilities cameraCapabilitiesFromBridge(bridge.CameraCapabilities c) {
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

MountCapabilities mountCapabilitiesFromBridge(bridge.MountCapabilities m) {
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
        .map((r) => trackingRateFromBridge(r))
        .toList(),
    isEquatorial: m.isEquatorial,
    supportsAltAz: m.supportsAltAz,
    canGetPointingState: m.canGetPointingState,
    canFindHome: m.canFindHome,
    tracking: m.tracking,
    trackingRate: m.trackingRate != null
        ? trackingRateFromBridge(m.trackingRate!)
        : null,
    canAbortSlew: m.canAbortSlew,
    maxSlewRate: m.maxSlewRate,
    canMoveAxis: m.canMoveAxis,
    axisCount: m.axisCount,
    minPulseGuideMs: m.minPulseGuideMs,
    maxPulseGuideMs: m.maxPulseGuideMs,
  );
}

FocuserCapabilities focuserCapabilitiesFromBridge(
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

FilterWheelCapabilities filterWheelCapabilitiesFromBridge(
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

RotatorCapabilities rotatorCapabilitiesFromBridge(
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
