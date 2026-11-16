part of '../network_backend.dart';

/// Device actions that only a linked imaging host can take for its client:
/// the camera warm-up it runs next to the camera, its switch channels, and
/// the dome and cover readings a local process takes from the bridge.
final class HostDeviceControl {
  HostDeviceControl(this._host);

  final NetworkBackend _host;

  /// Remote-only: start the gradual camera warm-up on the host, which runs
  /// the ramp next to the camera. Returns the host's outcome name (see
  /// `CameraWarmupOutcome`).
  Future<String> cameraStartHostWarmUp({double ratePerMin = 2.0}) async {
    final response = await _host._post(
      DeviceApi.cameraStartWarmUp,
      body: {'ratePerMin': ratePerMin},
    );
    return response['outcome'] as String? ?? 'started';
  }

  /// Remote-only: stop the host's warm-up. With [restorePriorSetting] the
  /// cooler goes back to the set-point it held before the warm-up.
  Future<void> cameraCancelHostWarmUp({bool restorePriorSetting = true}) async {
    await _host._post(
      DeviceApi.cameraCancelWarmUp,
      body: {'restorePriorSetting': restorePriorSetting},
    );
  }

  /// Remote-only: whether the host is warming the camera.
  Future<bool> cameraHostIsWarming() async {
    final response = await _host._get(DeviceApi.cameraGetWarmUp);
    return response['warming'] == true;
  }

  /// Set a switch value. [deviceId] is required by the server
  /// (`POST /api/switch/set`); [value] is a `bool` for boolean switches or a
  /// `num` for analog ones.
  Future<void> setSwitch({
    required String deviceId,
    required int switchId,
    required dynamic value,
  }) async {
    await _host._post(
      AuxiliaryApi.switchSet,
      body: {'deviceId': deviceId, 'switchId': switchId, 'value': value},
    );
  }

  /// Get switch states.
  ///
  /// Pass [deviceId] to scope to a single device — that returns the
  /// `{switchCount, switches:[...]}` single-device shape the per-channel UI
  /// consumes. Omit it for the all-devices summary
  /// (`{devicesConnected, devices:[...]}`).
  Future<Map<String, dynamic>> getSwitchStatus({String? deviceId}) async {
    return await _host._get(
      AuxiliaryApi.switchStatus,
      query: {
        if (deviceId != null && deviceId.isNotEmpty) 'deviceId': deviceId,
      },
    );
  }

  Future<DomeCapabilities?> getDomeCapabilities(String deviceId) async {
    final json = await _host._get(
      DomeApi.capabilities,
      query: {'deviceId': deviceId},
    );
    return DomeCapabilities.fromJson(json);
  }

  Future<Map<String, dynamic>> getCoverStatus(String deviceId) async {
    return await _host._get(AuxiliaryApi.coverStatus, query: {'deviceId': deviceId});
  }
}
