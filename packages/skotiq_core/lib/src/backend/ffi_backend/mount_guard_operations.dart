part of '../ffi_backend.dart';

/// The native mount motion guard over the FFI bridge. Refusals arrive as
/// `SkotiqError.operationFailed(reason)` written for the operator and are not
/// caught here.
mixin _FfiMountGuardOperations on _FfiBackendBase implements MountGuardBackend {
  @override
  Future<List<MountGuardEntry>> mountGuardState() async {
    final entries = await bridge_api.apiMountGuardGetState();
    return [
      for (final e in entries)
        MountGuardEntry(
          deviceId: e.deviceId,
          blockReason: e.blockReason,
          autoRecovering: e.autoRecovering,
          fault: switch (e.fault) {
            null => null,
            final f => MountMotionFault(
              kind: f.kind,
              message: f.message,
              detectedAt: DateTime.fromMillisecondsSinceEpoch(
                f.detectedAtUnix.toInt() * 1000,
                isUtc: true,
              ),
              rateDegPerSec: f.rateDegPerSec,
              raHours: f.raHours,
              decDegrees: f.decDegrees,
              altitudeDegrees: f.altitudeDegrees,
              stillMoving: f.stillMoving,
              stopAttempts: f.stopAttempts,
              runPaused: f.runPaused,
            ),
          },
          positionUnknown: switch (e.positionUnknown) {
            null => null,
            final l => MountPositionUnknown(
              reason: l.reason,
              message: l.message,
              flaggedAt: DateTime.fromMillisecondsSinceEpoch(
                l.flaggedAtUnix.toInt() * 1000,
                isUtc: true,
              ),
              runPaused: l.runPaused,
            ),
          },
        ),
    ];
  }

  @override
  Future<void> mountGuardAcknowledgeFault(String deviceId) =>
      bridge_api.apiMountGuardAcknowledgeFault(deviceId: deviceId);

  @override
  Future<void> mountGuardConfirmRehomed(String deviceId) =>
      bridge_api.apiMountGuardConfirmRehomed(deviceId: deviceId);

  @override
  Future<MountGuardSolveResult> mountGuardSolve(
    String deviceId, {
    String? cameraId,
    double exposureSecs = 5,
  }) async {
    final s = await bridge_api.apiMountGuardSolve(
      deviceId: deviceId,
      cameraId: cameraId,
      exposureSecs: exposureSecs,
    );
    return MountGuardSolveResult(
      raHours: s.raHours,
      decDegrees: s.decDegrees,
      mountRaHours: s.mountRaHours,
      mountDecDegrees: s.mountDecDegrees,
      separationDegrees: s.separationDegrees,
    );
  }

  @override
  Future<void> mountGuardRecoverySync(
    String deviceId,
    double raHours,
    double decDegrees,
  ) => bridge_api.apiMountGuardRecoverySync(
    deviceId: deviceId,
    raHours: raHours,
    decDegrees: decDegrees,
  );

  @override
  Future<void> mountGuardSetAutoSyncResume(bool enabled) async {
    final current = await bridge_api.apiMountGuardGetSettings();
    await bridge_api.apiMountGuardSetSettings(
      settings: bridge_api.MountGuardSettings(
        enabled: current.enabled,
        stopWhenIdle: current.stopWhenIdle,
        autoSyncResume: enabled,
        solveMismatchDegrees: current.solveMismatchDegrees,
      ),
    );
  }
}
