import 'run_finalization.dart';

/// Where the run this executor owns is in its life.
///
/// ```text
///   Idle ──beginLaunch──> Launching ──launchSucceeded──> Live(paused ⇄ running)
///    ^ │                      │                            │
///    │ └──attachNativeRun─────┼───────────────────────────>│
///    │                        └──claim──> Finalizing <──claim┘
///    │                                    (drive ⇄ retained)
///    └──releaseSettled── Settled <──settle──┘
///                          │
///                          └──beginLaunch──> Launching
/// ```
///
/// A terminal event can also claim the run straight from [RunIdle]: the
/// headless `load -> start` path runs natively without a Dart launch.
sealed class RunPhase {
  const RunPhase();

  String get name;

  @override
  String toString() => name;
}

/// No run is live through this executor.
final class RunIdle extends RunPhase {
  const RunIdle();

  @override
  String get name => 'idle';
}

/// A start or checkpoint resume is acquiring the run's resources.
final class RunLaunching extends RunPhase {
  const RunLaunching({this.nativeLaunchAttempted = false});

  /// True once `sequencerStart()` has been, or is about to be, called. From
  /// then on a failure may have left a partial native launch, so the rollback
  /// must stop the native executor before tearing down.
  final bool nativeLaunchAttempted;

  @override
  String get name => nativeLaunchAttempted ? 'launching(native)' : 'launching';
}

/// The run is live.
final class RunLive extends RunPhase {
  const RunLive({this.paused = false});

  /// A pause this executor commanded and the native executor confirmed. It
  /// stops the elapsed-time ticker; a pause native reports on its own does
  /// not.
  final bool paused;

  @override
  String get name => paused ? 'live(paused)' : 'live';
}

/// Teardown has been claimed: [finalization] is the run's one finalization
/// transaction.
final class RunFinalizing extends RunPhase {
  const RunFinalizing(this.finalization, {this.drive});

  final RunFinalization finalization;

  /// The drive in flight, which a racing stop joins; null while a failed drive
  /// waits for a Stop retry (`stopFailed` / `cleanupFailed`).
  final Future<void>? drive;

  @override
  String get name => drive == null ? 'finalizing(retained)' : 'finalizing';
}

/// The run has a verdict. A terminal event arriving now is a second event for
/// a finished run, never a new outcome.
final class RunSettled extends RunPhase {
  const RunSettled(this.runStatus);

  /// The `sequence_runs.status` the run settled with.
  final String runStatus;

  @override
  String get name => 'settled($runStatus)';
}

/// A transition the current phase does not allow.
class IllegalRunTransition extends StateError {
  IllegalRunTransition(String transition, RunPhase from)
    : super('Illegal run transition "$transition" from ${from.name}');
}

/// Owns the executor's [RunPhase] and the two operation latches, and is the
/// only thing that changes them. Every transition checks the phase it starts
/// from and throws [IllegalRunTransition] when the run is not there.
class RunLifecycle {
  RunPhase _phase = const RunIdle();
  RunPhase get phase => _phase;

  /// Held for the whole of a start or resume, validation included, so a second
  /// concurrent start is rejected before it touches any resource.
  final OperationLatch launch = OperationLatch('start');

  /// Held while a pause or resume waits for native confirmation.
  final OperationLatch pauseResume = OperationLatch('pause/resume');

  int _generation = 0;

  /// A new, never-reused id for the next [RunFinalization].
  int nextGeneration() => ++_generation;

  String? _lastRunEndOrigin;

  /// How the most recently settled run ended: `operator` / `scheduler` /
  /// `rollback` / `safety` (a native abort no stop() commanded), or null
  /// (completed, failed, or nothing settled yet). Kept across later launches.
  String? get lastRunEndOrigin => _lastRunEndOrigin;

  /// The claimed finalization, in flight or retained, if any.
  RunFinalization? get finalization => switch (_phase) {
    RunFinalizing(:final finalization) => finalization,
    _ => null,
  };

  /// The finalization drive in flight, if any.
  Future<void>? get drive => switch (_phase) {
    RunFinalizing(:final drive) => drive,
    _ => null,
  };

  /// Whether a pause this executor commanded is in force.
  bool get isPausedByExecutor => switch (_phase) {
    RunLive(:final paused) => paused,
    _ => false,
  };

  /// Idle or Settled -> Launching. A fresh run starts with no claimed
  /// finalization and no verdict.
  void beginLaunch() {
    switch (_phase) {
      case RunIdle() || RunSettled():
        _phase = const RunLaunching();
      default:
        throw IllegalRunTransition('beginLaunch', _phase);
    }
  }

  /// Launching -> Launching(native): the launch is about to call
  /// `sequencerStart()`.
  void markNativeLaunchAttempted() {
    switch (_phase) {
      case RunLaunching():
        _phase = const RunLaunching(nativeLaunchAttempted: true);
      default:
        throw IllegalRunTransition('markNativeLaunchAttempted', _phase);
    }
  }

  /// Launching -> Live. When a terminal event already claimed the run while
  /// the launch was finishing, the run stays with that finalization.
  void launchSucceeded() {
    switch (_phase) {
      case RunLaunching():
        _phase = const RunLive();
      case RunFinalizing() || RunSettled():
        return;
      default:
        throw IllegalRunTransition('launchSucceeded', _phase);
    }
  }

  /// A native run this executor did not launch (the headless `load -> start`
  /// path) is now attached. Idle or Settled -> Live; in every other phase the
  /// run already belongs to this executor and nothing changes. Returns true
  /// when a settled run was released to make way for it.
  bool attachNativeRun() {
    switch (_phase) {
      case RunIdle():
        _phase = const RunLive();
        return false;
      case RunSettled():
        _phase = const RunLive();
        return true;
      default:
        return false;
    }
  }

  /// Live -> Live(paused) and back, after native confirmed the pause or
  /// resume.
  void setPaused(bool paused) {
    switch (_phase) {
      case RunLive():
        _phase = RunLive(paused: paused);
      default:
        throw IllegalRunTransition(
          paused ? 'setPaused(true)' : 'setPaused(false)',
          _phase,
        );
    }
  }

  /// Idle, Launching or Live -> Finalizing([f]): claim the run's one
  /// finalization. A run that already has one (or a verdict) cannot claim
  /// another.
  void claim(RunFinalization f) {
    switch (_phase) {
      case RunIdle() || RunLaunching() || RunLive():
        _phase = RunFinalizing(f);
      default:
        throw IllegalRunTransition('claim', _phase);
    }
  }

  /// Finalizing([f], retained) -> Finalizing([f], [drive]).
  void driveStarted(RunFinalization f, Future<void> drive) {
    switch (_phase) {
      case RunFinalizing(:final finalization, drive: null)
          when identical(finalization, f):
        _phase = RunFinalizing(f, drive: drive);
      default:
        throw IllegalRunTransition('driveStarted', _phase);
    }
  }

  /// [drive] ended without settling: Finalizing([f], [drive]) ->
  /// Finalizing([f], retained). A no-op once the run settled or another drive
  /// took over.
  void driveEnded(RunFinalization f, Future<void> drive) {
    if (_phase case RunFinalizing(
      :final finalization,
      drive: final current,
    ) when identical(finalization, f) && identical(current, drive)) {
      _phase = RunFinalizing(f);
    }
  }

  /// Finalizing([f]) -> Settled. [endOrigin] becomes [lastRunEndOrigin].
  void settle(RunFinalization f, {String? endOrigin}) {
    switch (_phase) {
      case RunFinalizing(:final finalization) when identical(finalization, f):
        _phase = RunSettled(f.runStatus);
        _lastRunEndOrigin = endOrigin;
      default:
        throw IllegalRunTransition('settle', _phase);
    }
  }

  /// Settled -> Idle, for a new native run that does not come through a
  /// launch. Returns false (and changes nothing) in any other phase.
  bool releaseSettled() {
    if (_phase is! RunSettled) return false;
    _phase = const RunIdle();
    return true;
  }
}

/// A re-entrancy guard for one kind of operation.
class OperationLatch {
  OperationLatch(this.operation);

  final String operation;
  bool _held = false;

  bool get isHeld => _held;

  /// Take the latch; throws [StateError] when it is already held.
  void acquire() {
    if (_held) {
      throw StateError('A $operation operation is already in progress');
    }
    _held = true;
  }

  void release() => _held = false;
}
