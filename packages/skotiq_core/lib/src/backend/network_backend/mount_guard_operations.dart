part of '../network_backend.dart';

/// The host's mount motion guard over REST (`/api/mount/guard*`).
mixin _NetworkBackendMountGuardOperations on _NetworkBackendTransport
    implements MountGuardBackend {
  @override
  Future<List<MountGuardEntry>> mountGuardState() async {
    final json = await _get(DeviceApi.mountGuardState);
    final mounts = json['mounts'];
    if (mounts is! List) {
      throw const FormatException('The host answered without a mounts list');
    }
    return [
      for (final m in mounts)
        if (m is Map<String, dynamic>) MountGuardEntry.fromJson(m),
    ];
  }

  @override
  Future<void> mountGuardAcknowledgeFault(String deviceId) async {
    await _post(DeviceApi.mountGuardAcknowledge, body: {'deviceId': deviceId});
  }

  @override
  Future<void> mountGuardConfirmRehomed(String deviceId) async {
    await _post(DeviceApi.mountGuardConfirmHome, body: {'deviceId': deviceId});
  }

  @override
  Future<MountGuardSolveResult> mountGuardSolve(
    String deviceId, {
    String? cameraId,
    double exposureSecs = 5,
  }) async {
    final json = await _post(
      DeviceApi.mountGuardSolve,
      body: {
        'deviceId': deviceId,
        'cameraId': ?cameraId,
        'exposureSecs': exposureSecs,
      },
    );
    return MountGuardSolveResult.fromJson(json);
  }

  @override
  Future<void> mountGuardRecoverySync(
    String deviceId,
    double raHours,
    double decDegrees,
  ) async {
    await _post(
      DeviceApi.mountGuardRecoverySync,
      body: {
        'deviceId': deviceId,
        'raHours': raHours,
        'decDegrees': decDegrees,
      },
    );
  }

  @override
  Future<void> mountGuardSetAutoSyncResume(bool enabled) async {
    // The host owns this setting and pushes it to its own guard; a client
    // changes it through the mirrored app settings.
  }
}
