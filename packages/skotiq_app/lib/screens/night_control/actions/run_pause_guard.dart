// Pause the run, let the current frame finish, act, then resume what we
// paused (plan section 3, P2, "RunPauseGuard").
//
// Native pause lets the in-flight instruction finish and the Dart executor
// reports `paused` before the camera is idle (plan finding 3), so "paused"
// alone is not "safe to act". The guard waits for both.
//
// The guard never stops a run and never parks. A failed resume leaves the run
// paused and says so.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../models/command_action_result.dart';
import '../data/session/camera_exposure_provider.dart';

/// Query the host before touching equipment, including when the exposure
/// started before this screen subscribed to camera events.
final nightCameraIdleProbeProvider = Provider<Future<bool> Function()>((ref) {
  return () async {
    final camera = ref.read(cameraStateProvider);
    if (camera.connectionState != DeviceConnectionState.connected) return true;
    final id = camera.deviceId;
    if (id == null) throw StateError('Connected camera has no device ID');
    final status = await ref
        .read(backendProvider)
        .getCameraStatus(id)
        .timeout(const Duration(seconds: 5));
    if (!status.connected || status.state == CameraState.error) {
      throw StateError(
          'Camera is disconnected or reports an acquisition error');
    }
    return status.state == CameraState.idle;
  };
});

/// Where the guard is, for the action state.
enum RunHoldStage { pausing, waitingForFrame }

/// The exposure the guard is waiting on.
class RunHoldProgress {
  const RunHoldProgress(this.stage, {this.frameNumber, this.remaining});

  final RunHoldStage stage;

  /// The frame in flight; null when nothing reports it.
  final int? frameNumber;

  /// Its remaining exposure; null when nothing reports it.
  final Duration? remaining;
}

/// Why the guard gave up before the action ran.
class RunHoldAborted implements Exception {
  const RunHoldAborted(this.reason, {this.detail});

  final RunHoldAbortReason reason;
  final String? detail;

  @override
  String toString() =>
      'RunHoldAborted(${reason.name}${detail == null ? '' : ': $detail'})';
}

enum RunHoldAbortReason {
  /// The pause command failed.
  pauseFailed,

  /// The run left the paused state (resumed, stopped or failed elsewhere)
  /// before the camera went idle.
  runLeftPause,

  /// The run is in a state no manual action may act in.
  runNotPausable,

  /// The operator cancelled while waiting.
  cancelled,
}

/// What the guard holds: whether it owes a resume.
class RunHold {
  RunHold._(this.weStartedPause);

  /// True when the run was running and this guard paused it. Only then does
  /// [RunPauseGuard.release] resume it.
  final bool weStartedPause;

  /// A hold for a run that was already paused by someone else, or no run.
  static RunHold get notOwed => RunHold._(false);
}

/// The result of [RunPauseGuard.release].
enum RunReleaseOutcome {
  /// The guard did not pause the run, so it left it alone.
  notOwed,

  /// The run is no longer paused (someone resumed or stopped it), so there
  /// was nothing to resume.
  notPaused,

  resumed,

  /// Resume failed. The run stays paused; it is never stopped or parked.
  resumeFailed,
}

class RunReleaseResult {
  const RunReleaseResult(this.outcome, {this.error});

  final RunReleaseOutcome outcome;
  final String? error;
}

/// Holds the run paused around one manual action.
class RunPauseGuard {
  RunPauseGuard({
    required Ref ref,
    required Future<CommandActionResult> Function() pause,
    required Future<CommandActionResult> Function() resume,
  })  : _ref = ref,
        _pause = pause,
        _resume = resume;

  final Ref _ref;
  final Future<CommandActionResult> Function() _pause;
  final Future<CommandActionResult> Function() _resume;

  SequenceExecutionState get _runState =>
      _ref.read(sequenceExecutionStateProvider);

  /// Steps 1 and 2: pause a running run, then wait until it is paused and
  /// the camera is idle.
  ///
  /// With no run loaded it returns at once. A run the operator already
  /// paused is not paused again and not resumed later. Throws
  /// [RunHoldAborted] when the action must not run; the caller still passes
  /// the returned hold (or [RunHold.notOwed]) to [release].
  Future<RunHold> hold({
    required Future<void> cancelled,
    required void Function(RunHoldProgress progress) onProgress,
    required void Function(RunHold hold) onHeld,
  }) async {
    final initial = _runState;
    if (initial.canStart) {
      final hold = RunHold.notOwed;
      onHeld(hold);
      return hold;
    }
    if (initial != SequenceExecutionState.running &&
        initial != SequenceExecutionState.paused) {
      throw RunHoldAborted(
        RunHoldAbortReason.runNotPausable,
        detail: initial.name,
      );
    }

    var hold = RunHold.notOwed;
    if (initial == SequenceExecutionState.running) {
      onProgress(const RunHoldProgress(RunHoldStage.pausing));
      final result = await _pause();
      if (!result.isSuccess) {
        throw RunHoldAborted(
          RunHoldAbortReason.pauseFailed,
          detail: result.message,
        );
      }
      hold = RunHold._(true);
    }
    // Recorded before the wait, so a cancel or a failure while waiting still
    // resumes the run this guard paused.
    onHeld(hold);

    await _waitForIdle(cancelled: cancelled, onProgress: onProgress);
    return hold;
  }

  /// Step 4: resume only when this guard paused the run and the run is still
  /// paused. Never throws, never stops, never parks.
  Future<RunReleaseResult> release(RunHold hold) async {
    if (!hold.weStartedPause) {
      return const RunReleaseResult(RunReleaseOutcome.notOwed);
    }
    if (_runState != SequenceExecutionState.paused) {
      return const RunReleaseResult(RunReleaseOutcome.notPaused);
    }
    try {
      final result = await _resume();
      if (result.isSuccess) {
        return const RunReleaseResult(RunReleaseOutcome.resumed);
      }
      return RunReleaseResult(
        RunReleaseOutcome.resumeFailed,
        error: result.message ?? 'Resume failed',
      );
    } catch (e) {
      return RunReleaseResult(
        RunReleaseOutcome.resumeFailed,
        error: e.toString(),
      );
    }
  }

  /// Completes when the run is paused and no exposure, slew or focuser move
  /// is in flight.
  ///
  /// Running is tolerated until the first `paused` is seen (the pause is
  /// still landing). After that, any other state means someone else moved
  /// the run, and the action is abandoned.
  Future<void> _waitForIdle({
    required Future<void> cancelled,
    required void Function(RunHoldProgress progress) onProgress,
  }) async {
    final done = Completer<void>();
    var sawPaused = false;
    var probing = false;
    Timer? retry;

    void check({bool cameraConfirmedIdle = false}) {
      if (done.isCompleted) return;
      final run = _runState;
      if (run == SequenceExecutionState.paused) {
        sawPaused = true;
      } else if (run != SequenceExecutionState.running || sawPaused) {
        done.completeError(
          RunHoldAborted(RunHoldAbortReason.runLeftPause, detail: run.name),
        );
        return;
      } else {
        onProgress(const RunHoldProgress(RunHoldStage.pausing));
        return;
      }
      final exposure = _ref.read(exposureProgressProvider);
      final exposureActive = exposure.remaining > 0 || exposure.isDownloading;
      final nativeExposure = _ref.read(nightCameraExposureProvider);
      final cameraBusy =
          nativeExposure != null || _ref.read(cameraStateProvider).isExposing;
      // The instruction in flight may be a slew or a focuser move rather than
      // an exposure; native pause lets it finish too.
      final mountBusy = _ref.read(mountStateProvider).isSlewing;
      final focuserBusy = _ref.read(focuserStateProvider).isMoving;
      if (!cameraBusy && !exposureActive && !mountBusy && !focuserBusy) {
        if (cameraConfirmedIdle) {
          done.complete();
        } else if (!probing) {
          probing = true;
          unawaited(() async {
            try {
              final idle = await _ref.read(nightCameraIdleProbeProvider)();
              if (done.isCompleted) return;
              probing = false;
              if (idle) {
                check(cameraConfirmedIdle: true);
              } else {
                onProgress(const RunHoldProgress(RunHoldStage.waitingForFrame));
                retry?.cancel();
                retry = Timer(const Duration(milliseconds: 250), check);
              }
            } catch (error) {
              if (!done.isCompleted) {
                done.completeError(RunHoldAborted(
                  RunHoldAbortReason.pauseFailed,
                  detail: 'Cannot confirm camera is idle: $error',
                ));
              }
            }
          }());
        }
        return;
      }
      onProgress(RunHoldProgress(
        RunHoldStage.waitingForFrame,
        frameNumber: exposureActive && exposure.frameNumber > 0
            ? exposure.frameNumber
            : null,
        remaining: exposureActive && !exposure.isDownloading
            ? Duration(milliseconds: (exposure.remaining * 1000).round())
            : null,
      ));
    }

    final subscriptions = <ProviderSubscription<Object?>>[
      _ref.listen(sequenceExecutionStateProvider, (_, __) => check()),
      _ref.listen(cameraStateProvider, (_, __) => check()),
      _ref.listen(nightCameraExposureProvider, (_, __) => check()),
      _ref.listen(exposureProgressProvider, (_, __) => check()),
      _ref.listen(mountStateProvider, (_, __) => check()),
      _ref.listen(focuserStateProvider, (_, __) => check()),
    ];
    unawaited(cancelled.then((_) {
      if (!done.isCompleted) {
        done.completeError(
          const RunHoldAborted(RunHoldAbortReason.cancelled),
        );
      }
    }));
    try {
      check();
      await done.future;
    } finally {
      retry?.cancel();
      for (final subscription in subscriptions) {
        subscription.close();
      }
    }
  }
}
