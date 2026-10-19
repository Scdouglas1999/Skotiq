// Tonight's manual actions: the [NightActionApi] implementation (P2).
//
// Every action runs the same way (plan section 3, P2):
//  1. one at a time; pressing the action in flight joins it, any other
//     action is ignored until it finishes;
//  2. [RunPauseGuard] pauses a running run, waits for the frame in flight,
//     and afterwards resumes only a run it paused itself;
//  3. a failure lands in [ManualActionState.error] and the log. Nothing here
//     stops a run or parks the mount; a failed resume leaves the run paused.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../services/manual_capture_controller.dart';
import '../../sequencer/widgets/run_dashboard/run_dashboard_providers.dart'
    show runDashboardActiveTargetProvider;
import '../night_control_contracts.dart';
import 'armed_start_provider.dart';
import 'manual_action_gating.dart';
import 'night_rig_ops.dart';
import 'run_pause_guard.dart';
import 'solve_and_sync.dart';

const _logSource = 'NightActions';

/// The detail shown when a service failed without saying why.
const _noReason = 'no reason was given';

/// The action controller. Read it through [nightActionApiProvider] and
/// [nightActionStateProvider]; widget tests override those two with values.
final nightActionControllerProvider =
    NotifierProvider<NightActionController, ManualActionState>(
  NightActionController.new,
);

final nightActionApiProvider = Provider<NightActionApi>(
  (ref) => ref.watch(nightActionControllerProvider.notifier),
);

final nightActionStateProvider = Provider<ManualActionState>(
  (ref) => ref.watch(nightActionControllerProvider),
);

/// The target Center slews to: the run's active target, else the first
/// target of the loaded plan, else the session target. Null when none has
/// coordinates.
final nightCenterTargetProvider = Provider<NightCenterTarget?>((ref) {
  final header = ref.watch(runDashboardActiveTargetProvider);
  if (header != null) {
    return NightCenterTarget(
      name: header.targetName,
      raHours: header.raHours,
      decDegrees: header.decDegrees,
    );
  }
  final session = ref.watch(sessionStateProvider);
  final ra = session.targetRa;
  final dec = session.targetDec;
  if (ra == null || dec == null) return null;
  return NightCenterTarget(
    name: session.targetName,
    raHours: ra,
    decDegrees: dec,
  );
});

/// The cooler setpoint: the active profile's, else the plan's when all its
/// cool-camera steps agree on one. Null when neither names one.
final nightCoolerSetpointProvider = Provider<double?>((ref) {
  final profileTemp =
      ref.watch(activeEquipmentProfileProvider)?.defaultCoolingTemp;
  if (profileTemp != null && profileTemp.isFinite) return profileTemp;
  final sequence = ref.watch(currentSequenceProvider);
  if (sequence == null) return null;
  final temps = sequence.nodes.values
      .whereType<CoolCameraNode>()
      .where((node) => node.isEnabled)
      .map((node) => node.targetTemp)
      .toSet();
  return temps.length == 1 ? temps.single : null;
});

/// Everything the action bar's gating reads.
final nightActionInputsProvider = Provider<NightActionInputs>(
  (ref) => readNightActionInputs(
    ref.watch,
    ref.watch(nightActionControllerProvider),
  ),
);

/// Builds the gating inputs with [read] (a `watch` for the provider, a
/// `read` inside the controller, which cannot depend on its own state).
NightActionInputs readNightActionInputs(
  T Function<T>(ProviderListenable<T> provider) read,
  ManualActionState action,
) {
  bool connected(DeviceConnectionState state) =>
      state == DeviceConnectionState.connected;
  final camera = read(cameraStateProvider);
  final mount = read(mountStateProvider);
  final focuser = read(focuserStateProvider);
  final guider = read(guiderStateProvider);
  final target = read(nightCenterTargetProvider);
  return NightActionInputs(
    canCommand: read(backendCanCommandProvider),
    runState: read(sequenceExecutionStateProvider),
    action: action,
    loopActive: action.isBusy && action.active == ManualActionId.loop,
    cameraConnected: connected(camera.connectionState),
    mountConnected: connected(mount.connectionState),
    focuserConnected: connected(focuser.connectionState),
    guiderConnected: connected(guider.connectionState),
    isGuiding: guider.isGuiding,
    mountParked: mount.isParked,
    mountTracking: mount.isTracking,
    cameraCooling: camera.isCooling,
    coolerSetpoint: read(nightCoolerSetpointProvider),
    targetName: target?.name,
    hasTarget: target != null,
    hasFrame: read(currentImageProvider)?.filePath != null,
    exposureSeconds: read(exposureSettingsProvider).exposureTime,
    filterName: read(filterWheelStateProvider).currentFilterName,
  );
}

/// The action bar's buttons, in board order.
final nightManualActionsProvider = Provider<List<ManualActionVm>>((ref) {
  final inputs = ref.watch(nightActionInputsProvider);
  return [
    for (final id in visibleManualActions(inputs)) manualActionVm(inputs, id),
  ];
});

class NightActionController extends Notifier<ManualActionState>
    implements NightActionApi {
  Future<void>? _inFlight;
  ManualActionId? _inFlightId;
  Completer<void>? _cancelSignal;
  bool _cancelRequested = false;

  /// Set when the operator asked the loop to stop, so its end is not an
  /// error.
  bool _loopStopRequested = false;

  NightRigOps get _ops => ref.read(nightRigOpsProvider);

  LoggingService get _log => ref.read(loggingServiceProvider);

  @override
  ManualActionState build() {
    // Keep the frame-pointing recorder alive so Solve & sync can tell
    // whether the frame on screen is at the current pointing.
    ref.listen(nightFramePointingProvider, (_, __) {});
    return ManualActionState.idle;
  }

  // -------------------------------------------------------------------------
  // NightActionApi
  // -------------------------------------------------------------------------

  @override
  Future<void> run(ManualActionId id) => switch (id) {
        ManualActionId.snapshot => snapshot(),
        ManualActionId.loop => toggleLoop(),
        ManualActionId.autofocus => autofocus(),
        ManualActionId.solve => solve(),
        ManualActionId.solveSync => solveAndSync(),
        ManualActionId.center => center(),
        ManualActionId.dither => dither(),
        ManualActionId.flip => flipNow(),
        ManualActionId.tracking => toggleTracking(),
        ManualActionId.cooler => toggleCooler(),
      };

  @override
  Future<void> snapshot() =>
      _start(ManualActionId.snapshot, () => _ops.snapshot());

  @override
  Future<void> toggleLoop() {
    final inFlight = _inFlight;
    if (inFlight != null && _inFlightId == ManualActionId.loop) {
      _loopStopRequested = true;
      _ops.stopCapture();
      // Still pausing or waiting for the run's frame: nothing loops yet.
      _signalCancel();
      return inFlight;
    }
    return _start(ManualActionId.loop, () async {
      _loopStopRequested = false;
      if (state.startedRunPause) {
        _update(message: const NightText('nightActLoopHoldsRun'));
      }
      String? lastError;
      await _ops.loop(onError: (error) {
        lastError = error;
        _log.warning('Loop frame failed: $error', source: _logSource);
      });
      final error = lastError;
      if (!_loopStopRequested && error != null) throw StateError(error);
    });
  }

  @override
  Future<void> autofocus() => _start(ManualActionId.autofocus, () async {
        try {
          final result = await _ops.autofocus();
          _log.info(
            'Autofocus finished at ${result.bestPosition}, '
            'HFR ${result.bestHfr.toStringAsFixed(2)}',
            source: _logSource,
          );
        } on AutofocusCancelledException {
          _log.info('Autofocus cancelled', source: _logSource);
        }
      });

  @override
  Future<void> solve() => _start(
        ManualActionId.solve,
        holdRun: false,
        () async {
          final path = ref.read(currentImageProvider)?.filePath;
          if (path == null) {
            throw const _ActionFailure(NightText('nightScopeWhyNoFrame'));
          }
          final watch = Stopwatch()..start();
          final result = await _ops.solveFile(path);
          watch.stop();
          _update(lastSolveDuration: watch.elapsed);
          if (!result.success) {
            throw _ActionFailure(NightText('nightActErrSolve', params: {
              'detail': result.error ?? _noReason,
            }));
          }
          _log.info('Solved in ${watch.elapsedMilliseconds} ms',
              source: _logSource);
        },
      );

  @override
  Future<void> solveAndSync() => _start(ManualActionId.solveSync, () async {
        final result =
            await _ops.solveAndSync(cancelled: () => _cancelRequested);
        final duration = result.solveDuration;
        if (duration != null) _update(lastSolveDuration: duration);
        if (_cancelRequested) return;
        final error = result.error;
        if (error != null) throw StateError(error);
        _log.info(
          'Solved in ${duration?.inMilliseconds} ms and synced '
          '(${result.usedLastFrame ? 'last frame' : 'new frame'})',
          source: _logSource,
        );
      });

  @override
  Future<void> center() => _start(ManualActionId.center, () async {
        final target = ref.read(nightCenterTargetProvider);
        if (target == null) {
          throw const _ActionFailure(NightText('nightActWhyNoTarget'));
        }
        // A slew under active guiding drags the guide star off and reads as a
        // lost star, so guiding stops first. If it cannot, nothing slews.
        final wasGuiding = _ops.isGuiding;
        if (wasGuiding) await _ops.stopGuiding();

        Object? centerError;
        try {
          final result = await _ops.center(target);
          if (!result.success && !_cancelRequested) {
            centerError = StateError(result.errorMessage ?? 'Centering failed');
          }
        } catch (e) {
          centerError = e;
        }

        // The run resumes assuming guiding is active, so it restarts and
        // settles before the guard resumes the run.
        if (wasGuiding) {
          _update(message: const NightText('nightActRestartingGuiding'));
          try {
            await _ops.startGuidingAndSettle();
          } catch (e) {
            if (centerError != null) {
              _log.error('Centering failed: $centerError', source: _logSource);
            }
            throw _ActionFailure(
              NightText('nightActErrGuiding', params: {'detail': _clean(e)}),
            );
          }
        }
        if (centerError != null) throw centerError;
      });

  @override
  Future<void> dither() => _start(ManualActionId.dither, () => _ops.dither());

  @override
  Future<void> flipNow() => _start(ManualActionId.flip, () async {
        final error = await _ops.flip();
        if (error != null) throw StateError(error);
      });

  @override
  Future<void> toggleTracking() => _start(ManualActionId.tracking, () async {
        final enable = !ref.read(mountStateProvider).isTracking;
        final result = await _ops.setTracking(enable);
        if (!result.isSuccess) {
          throw StateError(result.message ?? 'Tracking change failed');
        }
      });

  @override
  Future<void> toggleCooler() => _start(ManualActionId.cooler, () async {
        if (ref.read(cameraStateProvider).isCooling) {
          await _ops.setCooler(enabled: false);
          return;
        }
        final setpoint = ref.read(nightCoolerSetpointProvider);
        if (setpoint == null) {
          throw const _ActionFailure(NightText('nightActWhyNoSetpoint'));
        }
        await _ops.setCooler(enabled: true, targetTemp: setpoint);
      });

  @override
  Future<void> cancel() async {
    final inFlight = _inFlight;
    final id = _inFlightId;
    if (inFlight == null || id == null) return;
    _cancelRequested = true;
    _signalCancel();
    try {
      switch (id) {
        case ManualActionId.autofocus:
          await _ops.cancelAutofocus();
        case ManualActionId.snapshot:
        case ManualActionId.loop:
          _loopStopRequested = true;
          _ops.stopCapture();
        case ManualActionId.solveSync:
          _ops.cancelSolve();
        case ManualActionId.center:
          await _ops.cancelCenter();
        case ManualActionId.solve:
        case ManualActionId.dither:
        case ManualActionId.flip:
        case ManualActionId.tracking:
        case ManualActionId.cooler:
          // No interrupt exists; the action finishes and the run resumes.
          break;
      }
    } catch (e) {
      _log.error('Cancelling ${id.name} failed: $e', source: _logSource);
    }
    await inFlight;
  }

  @override
  DateTime? get armedStartAt => ref.read(nightArmedStartProvider);

  @override
  Future<void> armStartAtDark() async {
    final refusal = _armRefusal();
    final dark = ref.read(nightAstroDarkProvider);
    if (refusal != null || dark == null) {
      _update(error: refusal ?? const NightText('nightActErrArmNoDark'));
      return;
    }
    _update(clearError: true);
    ref.read(nightArmedStartProvider.notifier).arm(dark, _fireArmedStart);
    _log.info('Start at dark armed for ${dark.toIso8601String()}',
        source: _logSource);
  }

  NightText? _armRefusal() {
    if (!ref.read(backendCanCommandProvider)) {
      return const NightText('nightActWhyNoHost');
    }
    if (ref.read(currentSequenceProvider) == null) {
      return const NightText('nightActErrArmNoPlan');
    }
    if (!ref.read(sequenceExecutionStateProvider).canStart) {
      return const NightText('nightActErrArmRunActive');
    }
    final dark = ref.read(nightAstroDarkProvider);
    if (dark == null) return const NightText('nightActErrArmNoDark');
    if (!dark.isAfter(DateTime.now().toUtc())) {
      return const NightText('nightActErrArmAlreadyDark');
    }
    return null;
  }

  @override
  void cancelArmedStart() {
    if (ref.read(nightArmedStartProvider) == null) return;
    ref.read(nightArmedStartProvider.notifier).disarm();
    _log.info('Start at dark cancelled', source: _logSource);
  }

  Future<void> _fireArmedStart() async {
    _log.info('Start at dark: starting the run', source: _logSource);
    if (!ref.read(backendCanCommandProvider)) {
      _update(error: const NightText('nightActWhyNoHost'));
      _log.error('Start at dark skipped: no command path to the host',
          source: _logSource);
      return;
    }
    try {
      final result = await _ops.startRun();
      if (!result.isSuccess) {
        final detail = result.message ?? _noReason;
        _update(
          error: NightText('nightActErrArmStart', params: {'detail': detail}),
        );
        _log.error('Start at dark failed: $detail', source: _logSource);
      }
    } catch (e) {
      _update(
        error: NightText('nightActErrArmStart', params: {'detail': _clean(e)}),
      );
      _log.error('Start at dark failed: $e', source: _logSource);
    }
  }

  // -------------------------------------------------------------------------
  // Orchestration
  // -------------------------------------------------------------------------

  /// Single flight: the action in flight is joined, a different one while
  /// busy is ignored, a disabled one is refused. [holdRun] false skips the
  /// run pause for an action that touches no device.
  Future<void> _start(
    ManualActionId id,
    Future<void> Function() body, {
    bool holdRun = true,
  }) {
    final inFlight = _inFlight;
    if (inFlight != null) {
      return _inFlightId == id ? inFlight : Future<void>.value();
    }
    final reason =
        manualActionDisabledReason(readNightActionInputs(ref.read, state), id);
    if (reason != null) {
      _log.info('${id.name} refused: ${reason.key}', source: _logSource);
      return Future<void>.value();
    }
    _inFlightId = id;
    final future = _execute(id, body, holdRun: holdRun);
    _inFlight = future;
    return future;
  }

  Future<void> _execute(
    ManualActionId id,
    Future<void> Function() body, {
    required bool holdRun,
  }) async {
    _cancelRequested = false;
    final cancelSignal = _cancelSignal = Completer<void>();
    final lastSolve = state.lastSolveDuration;
    state = ManualActionState(
      phase: ManualActionPhase.running,
      active: id,
      lastSolveDuration: lastSolve,
    );
    _log.info('${id.name} started', source: _logSource);

    final guard = RunPauseGuard(
      ref: ref,
      pause: _ops.pauseRun,
      resume: _ops.resumeRun,
    );
    var hold = RunHold.notOwed;
    NightText? error;
    try {
      if (holdRun) {
        await guard.hold(
          cancelled: cancelSignal.future,
          onHeld: (held) {
            hold = held;
            _update(startedRunPause: held.weStartedPause);
          },
          onProgress: _onHoldProgress,
        );
      }
      _update(
        phase: ManualActionPhase.running,
        message: null,
        clearMessage: true,
        clearWaiting: true,
      );
      await body();
      if (!_cancelRequested) {
        _log.info('${id.name} finished', source: _logSource);
      }
    } on RunHoldAborted catch (e) {
      error = _holdError(e);
      _log.warning('${id.name} did not run: $e', source: _logSource);
    } on _ActionFailure catch (e) {
      error = e.text;
      _log.error('${id.name} failed: ${e.text.key} ${e.text.params}',
          source: _logSource);
    } catch (e) {
      if (_cancelRequested) {
        // An aborted exposure or centering unwinds as an error; the operator
        // asked for it, so it is not a failure.
        _log.info('${id.name} cancelled: $e', source: _logSource);
      } else {
        error = NightText(manualActionKey('nightActErr', id),
            params: {'detail': _clean(e)});
        _log.error('${id.name} failed: $e', source: _logSource);
      }
    } finally {
      var runLeftPaused = false;
      if (hold.weStartedPause) {
        _update(
          phase: ManualActionPhase.resuming,
          message: const NightText('nightActResuming'),
          clearWaiting: true,
        );
        final release = await guard.release(hold);
        switch (release.outcome) {
          case RunReleaseOutcome.resumed:
            _log.info('Run resumed after ${id.name}', source: _logSource);
          case RunReleaseOutcome.notPaused:
            _log.info(
              'Run no longer paused after ${id.name}; nothing to resume',
              source: _logSource,
            );
          case RunReleaseOutcome.resumeFailed:
            // Left paused and visible. Never stopped, never parked.
            runLeftPaused = true;
            if (error != null) {
              _log.error('${id.name} also failed: ${error.key}',
                  source: _logSource);
            }
            error = NightText('nightActErrResume',
                params: {'detail': release.error ?? _noReason});
            _log.error(
              'Resume after ${id.name} failed; the run stays paused: '
              '${release.error}',
              source: _logSource,
            );
          case RunReleaseOutcome.notOwed:
            break;
        }
      }
      state = ManualActionState(
        phase: ManualActionPhase.idle,
        error: error,
        runLeftPaused: runLeftPaused,
        lastSolveDuration: state.lastSolveDuration,
      );
      if (identical(_cancelSignal, cancelSignal)) _cancelSignal = null;
      _inFlight = null;
      _inFlightId = null;
    }
  }

  void _onHoldProgress(RunHoldProgress progress) {
    switch (progress.stage) {
      case RunHoldStage.pausing:
        _update(
          phase: ManualActionPhase.pausingRun,
          message: const NightText('nightActPausing'),
          clearWaiting: true,
        );
      case RunHoldStage.waitingForFrame:
        final frame = progress.frameNumber;
        final remaining = progress.remaining;
        _update(
          phase: ManualActionPhase.waitingForFrame,
          waitingForFrame: frame,
          exposureRemaining: remaining,
          clearWaiting: true,
          message: frame != null && remaining != null
              ? NightText('nightActPausingAfter', params: {
                  'frame': '$frame',
                  'seconds': '${remaining.inSeconds}',
                })
              : const NightText('nightActPausing'),
        );
    }
  }

  NightText? _holdError(RunHoldAborted e) => switch (e.reason) {
        RunHoldAbortReason.cancelled => null,
        RunHoldAbortReason.pauseFailed => NightText('nightActErrPause',
            params: {'detail': e.detail ?? _noReason}),
        RunHoldAbortReason.runLeftPause =>
          const NightText('nightActErrRunMoved'),
        RunHoldAbortReason.runNotPausable =>
          const NightText('nightActWhyRunSettling'),
      };

  void _signalCancel() {
    final signal = _cancelSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  /// Field-wise update; the contract's state has no copyWith.
  void _update({
    ManualActionPhase? phase,
    bool? startedRunPause,
    int? waitingForFrame,
    Duration? exposureRemaining,
    bool clearWaiting = false,
    NightText? message,
    bool clearMessage = false,
    NightText? error,
    bool clearError = false,
    Duration? lastSolveDuration,
  }) {
    final s = state;
    state = ManualActionState(
      phase: phase ?? s.phase,
      active: s.active,
      startedRunPause: startedRunPause ?? s.startedRunPause,
      waitingForFrame:
          waitingForFrame ?? (clearWaiting ? null : s.waitingForFrame),
      exposureRemaining:
          exposureRemaining ?? (clearWaiting ? null : s.exposureRemaining),
      message: message ?? (clearMessage ? null : s.message),
      error: error ?? (clearError ? null : s.error),
      runLeftPaused: s.runLeftPaused,
      lastSolveDuration: lastSolveDuration ?? s.lastSolveDuration,
    );
  }

  static String _clean(Object error) =>
      ManualCaptureController.cleanError(error);
}

/// A failure that already has its operator-facing text.
class _ActionFailure implements Exception {
  const _ActionFailure(this.text);
  final NightText text;
}
