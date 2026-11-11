
/// Device actions that only a linked imaging host can take for its client:
/// the camera warm-up it runs next to the camera, and its switch channels.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostDeviceControl {
  Future<String> cameraStartHostWarmUp({double ratePerMin = 2.0});

  Future<void> cameraCancelHostWarmUp({bool restorePriorSetting = true});

  Future<bool> cameraHostIsWarming();

  Future<void> setSwitch({
    required String deviceId,
    required int switchId,
    required dynamic value,
  });

  Future<Map<String, dynamic>> getSwitchStatus({String? deviceId});
}
