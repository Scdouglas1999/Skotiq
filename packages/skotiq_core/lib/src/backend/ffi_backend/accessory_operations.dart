part of '../ffi_backend.dart';

mixin _FfiAccessoryOperations on _FfiBackendBase
    implements AccessoryDeviceBackend {
  @override
  Future<DomeStatusReading> readDomeStatus(String deviceId) async {
    final status = await bridge.apiGetDomeStatus(deviceId: deviceId);
    return DomeStatusReading(
      connected: status.connected,
      azimuth: status.azimuth,
      altitude: status.altitude,
      shutter: switch (status.shutterStatus) {
        bridge.ShutterState.open => ShutterStatus.open,
        bridge.ShutterState.closed => ShutterStatus.closed,
        bridge.ShutterState.opening => ShutterStatus.opening,
        bridge.ShutterState.closing => ShutterStatus.closing,
        bridge.ShutterState.error => ShutterStatus.error,
        bridge.ShutterState.unknown => ShutterStatus.unknown,
      },
      slewing: status.slewing,
      atHome: status.atHome,
      atPark: status.atPark,
      canSetAltitude: status.canSetAltitude,
      canSetAzimuth: status.canSetAzimuth,
      canSetShutter: status.canSetShutter,
      canSlave: status.canSlave,
      isSlaved: status.isSlaved,
    );
  }

  @override
  Future<({int count, List<SwitchChannelInfo> channels})> readSwitchChannels(
    String deviceId,
  ) async {
    final caps = await bridge.apiGetSwitchCapabilities(deviceId: deviceId);
    return (
      count: caps.switchCount,
      channels: [
        for (final s in caps.switches)
          SwitchChannelInfo(
            index: s.index,
            name: s.name,
            description: s.description,
            isBoolean: s.isBoolean,
            minValue: s.minValue,
            maxValue: s.maxValue,
            step: s.step,
            canWrite: s.canWrite,
            value: s.value,
          ),
      ],
    );
  }

  @override
  Future<double> readSwitchValue(String deviceId, int switchId) =>
      bridge.apiSwitchGetValue(deviceId: deviceId, switchId: switchId);

  @override
  Future<int> switchChannelCount(String deviceId) =>
      bridge.apiSwitchGetMax(deviceId: deviceId);

  @override
  Future<void> writeSwitchState(String deviceId, int switchId, bool state) =>
      bridge.apiSwitchSetState(
        deviceId: deviceId,
        switchId: switchId,
        state: state,
      );

  @override
  Future<void> writeSwitchValue(String deviceId, int switchId, double value) =>
      bridge.apiSwitchSetValue(
        deviceId: deviceId,
        switchId: switchId,
        value: value,
      );

  @override
  Future<CoverCalibratorReading> readCoverCalibrator(String deviceId) async {
    final status = await bridge.apiCoverCalibratorGetStatus(deviceId: deviceId);
    return CoverCalibratorReading(
      connected: status.connected,
      cover: switch (status.coverState) {
        bridge.CoverState.notPresent => CoverStatus.notPresent,
        bridge.CoverState.closed => CoverStatus.closed,
        bridge.CoverState.moving => CoverStatus.moving,
        bridge.CoverState.open => CoverStatus.open,
        bridge.CoverState.unknown => CoverStatus.unknown,
        bridge.CoverState.error => CoverStatus.error,
      },
      calibrator: switch (status.calibratorState) {
        bridge.CalibratorState.notPresent => CalibratorStatus.notPresent,
        bridge.CalibratorState.off => CalibratorStatus.off,
        bridge.CalibratorState.notReady => CalibratorStatus.notReady,
        bridge.CalibratorState.ready => CalibratorStatus.ready,
        bridge.CalibratorState.unknown => CalibratorStatus.unknown,
        bridge.CalibratorState.error => CalibratorStatus.error,
      },
      brightness: status.brightness,
      maxBrightness: status.maxBrightness,
    );
  }
}
