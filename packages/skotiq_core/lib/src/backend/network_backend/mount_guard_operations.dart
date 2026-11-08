part of '../network_backend.dart';

/// The host's mount motion guard over REST (`/api/mount/guard*`).
mixin _NetworkBackendMountGuardOperations on _NetworkBackendTransport
    implements MountGuardBackend {
  @override
  Future<List<MountGuardEntry>> mountGuardState() async {
    final json = await _get('mount/guard');
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
    await _post('mount/guard/acknowledge', {'deviceId': deviceId});
  }

  @override
  Future<void> mountGuardConfirmRehomed(String deviceId) async {
    await _post('mount/guard/confirm-home', {'deviceId': deviceId});
  }

  @override
  Future<MountGuardSolveResult> mountGuardSolve(
    String deviceId, {
    String? cameraId,
    double exposureSecs = 5,
  }) async {
    final json = await _post('mount/guard/solve', {
      'deviceId': deviceId,
      'cameraId': ?cameraId,
      'exposureSecs': exposureSecs,
    });
    return MountGuardSolveResult.fromJson(json);
  }

  @override
  Future<void> mountGuardRecoverySync(
    String deviceId,
    double raHours,
    double decDegrees,
  ) async {
    await _post('mount/guard/recovery-sync', {
      'deviceId': deviceId,
      'raHours': raHours,
      'decDegrees': decDegrees,
    });
  }

  @override
  Future<void> mountGuardSetAutoSyncResume(bool enabled) async {
    // The host owns this setting and pushes it to its own guard; a client
    // changes it through the mirrored app settings.
  }
}
