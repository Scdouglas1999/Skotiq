import '../../models/mount_guard.dart';

/// The mount motion guard: its state and the operator's recovery actions.
///
/// A role of its own, not part of [DeviceBackend], so backends and test
/// fakes that have no guard need not answer for one. Callers check
/// `backend is MountGuardBackend`.
abstract interface class MountGuardBackend {
  /// Every mount with an open motion fault or an unknown position.
  Future<List<MountGuardEntry>> mountGuardState();

  /// The operator has checked the mount after it moved on its own.
  Future<void> mountGuardAcknowledgeFault(String deviceId);

  /// The operator has put the mount at its home position and confirms it.
  Future<void> mountGuardConfirmRehomed(String deviceId);

  /// Take a frame and plate solve it with no position hint.
  Future<MountGuardSolveResult> mountGuardSolve(
    String deviceId, {
    String? cameraId,
    double exposureSecs = 5,
  });

  /// Sync the mount to a solve the operator accepted (J2000) and trust its
  /// position again.
  Future<void> mountGuardRecoverySync(
    String deviceId,
    double raHours,
    double decDegrees,
  );

  /// Whether a run held by a mount fault may solve, sync and resume on its
  /// own. Only the host's native guard holds this; a linked client changes
  /// it through the host's settings.
  Future<void> mountGuardSetAutoSyncResume(bool enabled);
}
