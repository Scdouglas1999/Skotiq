// Every FRB device status and capability type, built with named arguments
// (so a required field Rust adds or drops stops this compiling), reaches the
// core model field for field and survives the model's JSON round trip; the
// generated field list is compared too, for optional fields Rust adds.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/src/models/backend/device_capabilities.dart';
import 'package:skotiq_core/src/models/backend/device_capabilities_bridge.dart';
import 'package:skotiq_core/src/models/backend/device_status.dart';
import 'package:skotiq_core/src/models/backend/device_status_bridge.dart';
import 'package:skotiq_core/src/models/backend/device_types.dart';

import '../../harness/frb_contract.dart';

void main() {
  test('camera status', () {
    final mapped = cameraStatusFromBridge(
      const bridge.CameraStatus(
        connected: true,
        state: bridge.CameraState.exposing,
        sensorTemp: -9.5,
        coolerPower: 41.0,
        targetTemp: -10.0,
        coolerOn: true,
        gain: 120,
        offset: 30,
        binX: 2,
        binY: 3,
        sensorWidth: 4144,
        sensorHeight: 2822,
        pixelSizeX: 4.63,
        pixelSizeY: 4.64,
        maxAdu: 65535,
        saturationAdu: 61000,
        canCool: true,
        canSetGain: true,
        canSetOffset: true,
      ),
    );
    const expected = CameraStatus(
      connected: true,
      state: CameraState.exposing,
      sensorTemp: -9.5,
      coolerPower: 41.0,
      targetTemp: -10.0,
      coolerOn: true,
      gain: 120,
      offset: 30,
      binX: 2,
      binY: 3,
      sensorWidth: 4144,
      sensorHeight: 2822,
      pixelSizeX: 4.63,
      pixelSizeY: 4.64,
      maxAdu: 65535,
      saturationAdu: 61000,
      canCool: true,
      canSetGain: true,
      canSetOffset: true,
    );
    expect(mapped.toJson(), expected.toJson());
    expect(CameraStatus.fromJson(mapped.toJson()).toJson(), mapped.toJson());
    expect(
      frbFields('device.dart', 'CameraStatus'),
      expected.toJson().keys.toSet(),
    );
  });

  test('mount status', () {
    final mapped = mountStatusFromBridge(
      const bridge.MountStatus(
        connected: true,
        tracking: true,
        slewing: false,
        parked: false,
        atHome: true,
        sideOfPier: bridge.PierSide.west,
        rightAscension: 5.5,
        declination: -12.25,
        altitude: 44.0,
        azimuth: 181.0,
        siderealTime: 6.75,
        trackingRate: bridge.TrackingRate.lunar,
        canPark: true,
        canSlew: true,
        canSync: false,
        canPulseGuide: true,
        canSetTrackingRate: false,
        availability: {
          'altitude': bridge.FieldAvailability.available(),
          'atHome': bridge.FieldAvailability.unsupported(),
          'sideOfPier': bridge.FieldAvailability.error('timeout'),
        },
      ),
    );
    const expected = MountStatus(
      connected: true,
      tracking: true,
      slewing: false,
      parked: false,
      atHome: true,
      sideOfPier: PierSide.west,
      rightAscension: 5.5,
      declination: -12.25,
      altitude: 44.0,
      azimuth: 181.0,
      siderealTime: 6.75,
      trackingRate: TrackingRate.lunar,
      canPark: true,
      canSlew: true,
      canSync: false,
      canPulseGuide: true,
      canSetTrackingRate: false,
      availability: {
        'altitude': 'available',
        'atHome': 'unsupported',
        'sideOfPier': 'error: timeout',
      },
    );
    expect(mapped.toJson(), expected.toJson());
    expect(MountStatus.fromJson(mapped.toJson()).toJson(), mapped.toJson());
    expect(frbFields('device.dart', 'MountStatus'), {
      'connected',
      'tracking',
      'slewing',
      'parked',
      'atHome',
      'sideOfPier',
      'rightAscension',
      'declination',
      'altitude',
      'azimuth',
      'siderealTime',
      'trackingRate',
      'canPark',
      'canSlew',
      'canSync',
      'canPulseGuide',
      'canSetTrackingRate',
      'availability',
    });
  });

  test('a mount that cannot say its pier side or home reads unknown and '
      'not home', () {
    final mapped = mountStatusFromBridge(
      const bridge.MountStatus(
        connected: true,
        tracking: false,
        slewing: false,
        parked: true,
        rightAscension: 0,
        declination: 90,
        canPark: true,
        canSlew: true,
        canSync: true,
        canPulseGuide: true,
        canSetTrackingRate: true,
        availability: {},
      ),
    );
    expect(mapped.sideOfPier, PierSide.unknown);
    expect(mapped.atHome, isFalse);
    expect(mapped.altitude, isNull);
    expect(mapped.trackingRate, isNull);
  });

  test('focuser, filter wheel and rotator status', () {
    final focuser = focuserStatusFromBridge(
      const bridge.FocuserStatus(
        connected: true,
        position: 12345,
        moving: true,
        temperature: 3.5,
        maxPosition: 60000,
        stepSize: 1.5,
        isAbsolute: true,
        hasTemperature: true,
      ),
    );
    const focuserExpected = FocuserStatus(
      connected: true,
      position: 12345,
      moving: true,
      temperature: 3.5,
      maxPosition: 60000,
      stepSize: 1.5,
      isAbsolute: true,
      hasTemperature: true,
    );
    expect(focuser.toJson(), focuserExpected.toJson());
    expect(FocuserStatus.fromJson(focuser.toJson()).toJson(), focuser.toJson());
    expect(
      frbFields('device.dart', 'FocuserStatus'),
      focuserExpected.toJson().keys.toSet(),
    );

    final wheel = filterWheelStatusFromBridge(
      const bridge.FilterWheelStatus(
        connected: true,
        position: 3,
        moving: false,
        filterCount: 5,
        filterNames: ['L', 'R', 'G', 'B', 'Ha'],
      ),
    );
    const wheelExpected = FilterWheelStatus(
      connected: true,
      position: 3,
      moving: false,
      filterCount: 5,
      filterNames: ['L', 'R', 'G', 'B', 'Ha'],
    );
    expect(wheel.toJson(), wheelExpected.toJson());
    expect(FilterWheelStatus.fromJson(wheel.toJson()).toJson(), wheel.toJson());
    expect(
      frbFields('device.dart', 'FilterWheelStatus'),
      wheelExpected.toJson().keys.toSet(),
    );

    final rotator = rotatorStatusFromBridge(
      const bridge.RotatorStatus(
        connected: true,
        position: 91.5,
        moving: true,
        mechanicalPosition: 88.25,
        isMoving: false,
        canReverse: true,
      ),
    );
    const rotatorExpected = RotatorStatus(
      connected: true,
      position: 91.5,
      moving: true,
      mechanicalPosition: 88.25,
      isMoving: false,
      canReverse: true,
    );
    expect(rotator.toJson(), rotatorExpected.toJson());
    expect(RotatorStatus.fromJson(rotator.toJson()).toJson(), rotator.toJson());
    expect(
      frbFields('device.dart', 'RotatorStatus'),
      rotatorExpected.toJson().keys.toSet(),
    );
  });

  test('camera capabilities', () {
    final mapped = cameraCapabilitiesFromBridge(
      bridge.CameraCapabilities(
        maxWidth: 6248,
        maxHeight: 4176,
        bitDepth: 14,
        hasShutter: false,
        canSetCcdTemperature: true,
        canSetCooler: true,
        canGetCoolerPower: true,
        canBin: true,
        maxBinX: 4,
        maxBinY: 3,
        canAsymmetricBin: false,
        canSetGain: true,
        gainMin: 0,
        gainMax: 570,
        isoSpeeds: Int32List.fromList([100, 200, 400]),
        canSetOffset: true,
        offsetMin: 1,
        offsetMax: 80,
        canAbortExposure: true,
        canStopExposure: false,
        canSubframe: true,
        pixelSizeX: 3.76,
        pixelSizeY: 3.77,
        isColor: true,
        bayerPattern: 'RGGB',
        sensorType: 'CMOS',
        hasFastReadout: true,
        readoutModes: const ['Normal', 'High Speed'],
        exposureMin: 0.000032,
        exposureMax: 2000,
        ccdTemperature: -5.5,
        setCcdTemperature: -10,
        coolerPower: 37,
        coolerOn: true,
        coolerMinTempC: -40,
        coolerMaxTempC: 30,
      ),
    );
    const expected = CameraCapabilities(
      maxWidth: 6248,
      maxHeight: 4176,
      bitDepth: 14,
      hasShutter: false,
      canSetCcdTemperature: true,
      canSetCooler: true,
      canGetCoolerPower: true,
      canBin: true,
      maxBinX: 4,
      maxBinY: 3,
      canAsymmetricBin: false,
      canSetGain: true,
      gainMin: 0,
      gainMax: 570,
      isoSpeeds: [100, 200, 400],
      canSetOffset: true,
      offsetMin: 1,
      offsetMax: 80,
      canAbortExposure: true,
      canStopExposure: false,
      canSubframe: true,
      pixelSizeX: 3.76,
      pixelSizeY: 3.77,
      isColor: true,
      bayerPattern: 'RGGB',
      sensorType: 'CMOS',
      hasFastReadout: true,
      readoutModes: ['Normal', 'High Speed'],
      exposureMin: 0.000032,
      exposureMax: 2000,
      ccdTemperature: -5.5,
      setCcdTemperature: -10,
      coolerPower: 37,
      coolerOn: true,
      coolerMinTempC: -40,
      coolerMaxTempC: 30,
    );
    expect(mapped.toJson(), expected.toJson());
    expect(
      CameraCapabilities.fromJson(mapped.toJson()).toJson(),
      mapped.toJson(),
    );
    expect(
      frbFields('device_capabilities/types.dart', 'CameraCapabilities'),
      expected.toJson().keys.toSet(),
    );
  });

  test('mount capabilities', () {
    final mapped = mountCapabilitiesFromBridge(
      const bridge.MountCapabilities(
        canSlew: true,
        canSlewAsync: true,
        canSync: false,
        canPark: true,
        canUnpark: true,
        canSetPark: false,
        canPulseGuide: true,
        canGetSideOfPier: true,
        canSetSideOfPier: false,
        canSetTracking: true,
        canSetTrackingRate: true,
        supportedTrackingRates: [
          bridge.TrackingRate.sidereal,
          bridge.TrackingRate.solar,
          bridge.TrackingRate.king,
        ],
        isEquatorial: true,
        supportsAltAz: false,
        canGetPointingState: true,
        canFindHome: false,
        tracking: true,
        trackingRate: bridge.TrackingRate.custom,
        canAbortSlew: true,
        maxSlewRate: 4.5,
        canMoveAxis: true,
        axisCount: 2,
        minPulseGuideMs: 10,
        maxPulseGuideMs: 5000,
      ),
    );
    const expected = MountCapabilities(
      canSlew: true,
      canSlewAsync: true,
      canSync: false,
      canPark: true,
      canUnpark: true,
      canSetPark: false,
      canPulseGuide: true,
      canGetSideOfPier: true,
      canSetSideOfPier: false,
      canSetTracking: true,
      canSetTrackingRate: true,
      supportedTrackingRates: [
        TrackingRate.sidereal,
        TrackingRate.solar,
        TrackingRate.king,
      ],
      isEquatorial: true,
      supportsAltAz: false,
      canGetPointingState: true,
      canFindHome: false,
      tracking: true,
      trackingRate: TrackingRate.custom,
      canAbortSlew: true,
      maxSlewRate: 4.5,
      canMoveAxis: true,
      axisCount: 2,
      minPulseGuideMs: 10,
      maxPulseGuideMs: 5000,
    );
    expect(mapped.toJson(), expected.toJson());
    expect(
      MountCapabilities.fromJson(mapped.toJson()).toJson(),
      mapped.toJson(),
    );
    expect(
      frbFields('device_capabilities/types.dart', 'MountCapabilities'),
      expected.toJson().keys.toSet(),
    );
  });

  test('focuser, filter wheel and rotator capabilities', () {
    final focuser = focuserCapabilitiesFromBridge(
      const bridge.FocuserCapabilities(
        maxPosition: 60000,
        maxIncrement: 5000,
        stepSize: 2.5,
        absolute: true,
        tempCompAvailable: true,
        tempComp: false,
        temperature: 4.25,
        isMoving: true,
        position: 31000,
        canHalt: true,
        canReverse: true,
        reverse: false,
      ),
    );
    const focuserExpected = FocuserCapabilities(
      maxPosition: 60000,
      maxIncrement: 5000,
      stepSize: 2.5,
      absolute: true,
      tempCompAvailable: true,
      tempComp: false,
      temperature: 4.25,
      isMoving: true,
      position: 31000,
      canHalt: true,
      canReverse: true,
      reverse: false,
    );
    expect(focuser.toJson(), focuserExpected.toJson());
    expect(
      FocuserCapabilities.fromJson(focuser.toJson()).toJson(),
      focuser.toJson(),
    );
    expect(
      frbFields('device_capabilities/types.dart', 'FocuserCapabilities'),
      focuserExpected.toJson().keys.toSet(),
    );

    final wheel = filterWheelCapabilitiesFromBridge(
      bridge.FilterWheelCapabilities(
        positionCount: 7,
        currentPosition: 2,
        filterNames: const ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII'],
        focusOffsets: Int32List.fromList([0, 12, 15, 9, -40, -22, -31]),
        isMoving: false,
        canSetFilterNames: true,
        canSetFocusOffsets: false,
      ),
    );
    const wheelExpected = FilterWheelCapabilities(
      positionCount: 7,
      currentPosition: 2,
      filterNames: ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII'],
      focusOffsets: [0, 12, 15, 9, -40, -22, -31],
      isMoving: false,
      canSetFilterNames: true,
      canSetFocusOffsets: false,
    );
    expect(wheel.toJson(), wheelExpected.toJson());
    expect(
      FilterWheelCapabilities.fromJson(wheel.toJson()).toJson(),
      wheel.toJson(),
    );
    expect(
      frbFields('device_capabilities/types.dart', 'FilterWheelCapabilities'),
      wheelExpected.toJson().keys.toSet(),
    );

    final rotator = rotatorCapabilitiesFromBridge(
      const bridge.RotatorCapabilities(
        canReverse: true,
        reverse: true,
        stepSize: 0.125,
        isMoving: false,
        mechanicalPosition: 179.5,
        position: 181.0,
        canMoveAbsolute: true,
        canHalt: false,
        canSync: true,
        minAngleDeg: -5,
        maxAngleDeg: 365,
      ),
    );
    const rotatorExpected = RotatorCapabilities(
      canReverse: true,
      reverse: true,
      stepSize: 0.125,
      isMoving: false,
      mechanicalPosition: 179.5,
      position: 181.0,
      canMoveAbsolute: true,
      canHalt: false,
      canSync: true,
      minAngleDeg: -5,
      maxAngleDeg: 365,
    );
    expect(rotator.toJson(), rotatorExpected.toJson());
    expect(
      RotatorCapabilities.fromJson(rotator.toJson()).toJson(),
      rotator.toJson(),
    );
    expect(
      frbFields('device_capabilities/types.dart', 'RotatorCapabilities'),
      rotatorExpected.toJson().keys.toSet(),
    );
  });
}
