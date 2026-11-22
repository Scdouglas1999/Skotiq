/// Device status as the FFI backend reads it from the bridge. The bridge
/// contract test (`test/models/backend/device_bridge_contract_test.dart`)
/// constructs every FRB status type here with named arguments.
library;

import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

import 'device_capabilities.dart' show TrackingRate;
import 'device_status.dart';
import 'device_types.dart' show CameraState, PierSide;

CameraStatus cameraStatusFromBridge(bridge.CameraStatus s) {
  return CameraStatus(
    connected: s.connected,
    state: cameraStateFromBridge(s.state),
    sensorTemp: s.sensorTemp,
    coolerPower: s.coolerPower,
    targetTemp: s.targetTemp,
    coolerOn: s.coolerOn,
    gain: s.gain,
    offset: s.offset,
    binX: s.binX,
    binY: s.binY,
    sensorWidth: s.sensorWidth,
    sensorHeight: s.sensorHeight,
    pixelSizeX: s.pixelSizeX,
    pixelSizeY: s.pixelSizeY,
    maxAdu: s.maxAdu,
    saturationAdu: s.saturationAdu,
    canCool: s.canCool,
    canSetGain: s.canSetGain,
    canSetOffset: s.canSetOffset,
  );
}

CameraState cameraStateFromBridge(bridge.CameraState s) {
  switch (s) {
    case bridge.CameraState.idle:
      return CameraState.idle;
    case bridge.CameraState.waiting:
      return CameraState.waiting;
    case bridge.CameraState.exposing:
      return CameraState.exposing;
    case bridge.CameraState.reading:
      return CameraState.reading;
    case bridge.CameraState.download:
      return CameraState.download;
    case bridge.CameraState.error:
      return CameraState.error;
  }
}

MountStatus mountStatusFromBridge(bridge.MountStatus s) {
  return MountStatus(
    connected: s.connected,
    tracking: s.tracking,
    slewing: s.slewing,
    parked: s.parked,
    atHome: s.atHome ?? false,
    sideOfPier: s.sideOfPier == null
        ? PierSide.unknown
        : pierSideFromBridge(s.sideOfPier!),
    rightAscension: s.rightAscension,
    declination: s.declination,
    // The horizon frame as the native side reported it: null is "this mount
    // cannot say" (what `sim_gate::apply_derived_mount_telemetry` returns
    // when no observing site is configured), which the panels show as `--`.
    altitude: s.altitude,
    azimuth: s.azimuth,
    siderealTime: s.siderealTime,
    trackingRate: s.trackingRate == null
        ? null
        : trackingRateFromBridge(s.trackingRate!),
    canPark: s.canPark,
    canSlew: s.canSlew,
    canSync: s.canSync,
    canPulseGuide: s.canPulseGuide,
    canSetTrackingRate: s.canSetTrackingRate,
    availability: s.availability.map(
      (key, value) => MapEntry(key, fieldAvailabilityToWire(value)),
    ),
  );
}

/// Serialize a flutter_rust_bridge [FieldAvailability] to the stable wire
/// string the headless API and clients expect ('available' / 'unsupported' /
/// `error: <reason>`). Using `.toString()` would leak the Dart class name
/// ('FieldAvailability.available()') into the JSON contract.
String fieldAvailabilityToWire(bridge.FieldAvailability v) {
  return v.when(
    available: () => 'available',
    unsupported: () => 'unsupported',
    error: (reason) => 'error: $reason',
  );
}

PierSide pierSideFromBridge(bridge.PierSide s) {
  switch (s) {
    case bridge.PierSide.east:
      return PierSide.east;
    case bridge.PierSide.west:
      return PierSide.west;
    case bridge.PierSide.unknown:
      return PierSide.unknown;
  }
}

TrackingRate trackingRateFromBridge(bridge.TrackingRate r) {
  switch (r) {
    case bridge.TrackingRate.sidereal:
      return TrackingRate.sidereal;
    case bridge.TrackingRate.lunar:
      return TrackingRate.lunar;
    case bridge.TrackingRate.solar:
      return TrackingRate.solar;
    case bridge.TrackingRate.king:
      return TrackingRate.king;
    case bridge.TrackingRate.custom:
      return TrackingRate.custom;
  }
}

FocuserStatus focuserStatusFromBridge(bridge.FocuserStatus s) {
  return FocuserStatus(
    connected: s.connected,
    position: s.position,
    moving: s.moving,
    temperature: s.temperature,
    maxPosition: s.maxPosition,
    stepSize: s.stepSize,
    isAbsolute: s.isAbsolute,
    hasTemperature: s.hasTemperature,
  );
}

FilterWheelStatus filterWheelStatusFromBridge(bridge.FilterWheelStatus s) {
  return FilterWheelStatus(
    connected: s.connected,
    position: s.position,
    moving: s.moving,
    filterCount: s.filterCount,
    filterNames: s.filterNames,
  );
}

RotatorStatus rotatorStatusFromBridge(bridge.RotatorStatus s) {
  return RotatorStatus(
    connected: s.connected,
    position: s.position,
    moving: s.moving,
    mechanicalPosition: s.mechanicalPosition,
    isMoving: s.isMoving,
    canReverse: s.canReverse,
  );
}
