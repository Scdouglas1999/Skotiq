part of '../scheduler_engine.dart';

/// An operator-correctable admission failure that leaves the scheduler idle.
class SchedulerStartException implements Exception {
  final String message;

  const SchedulerStartException(this.message);

  @override
  String toString() => message;
}

/// Snapshot of a candidate target plus the live data the engine needs to
/// score it. The engine doesn't read the Targets DAO directly; the caller
/// (provider layer) builds this from drift rows so the engine remains
/// database-agnostic and easily unit-testable.
class SchedulerCandidate {
  /// Drift `targets.id`.
  final int targetId;
  final String name;
  final double raHours;
  final double decDegrees;

  /// User-set priority on the target row (higher = better).
  final int userPriority;

  /// Integration goals attached to this target.
  final List<IntegrationGoal> goals;

  /// Per-(goal) captured-frame counts, in the same order as `goals`.
  /// Length must match `goals.length`.
  final List<int> capturedCounts;

  /// Hard constraints attached to this target.
  final List<TargetConstraint> constraints;

  /// Resolved horizon profiles keyed by HorizonProfiles.id, for any
  /// constraint referencing one. May be empty if none used.
  final Map<int, HorizonProfile> horizonProfiles;

  /// Filters available in the current equipment profile (case-preserved).
  /// A target needing a filter not in this list fails the equipment
  /// availability hard constraint.
  final List<String> availableFilters;

  /// True when the target represents a multi-panel mosaic plan.
  final bool isMosaicTarget;

  SchedulerCandidate({
    required this.targetId,
    required this.name,
    required this.raHours,
    required this.decDegrees,
    required this.userPriority,
    required this.goals,
    required this.capturedCounts,
    required this.constraints,
    required this.horizonProfiles,
    required this.availableFilters,
    this.isMosaicTarget = false,
  }) {
    if (capturedCounts.length != goals.length) {
      throw ArgumentError(
        'capturedCounts length (${capturedCounts.length}) must match goals length (${goals.length})',
      );
    }
  }
}

/// Result of the engine's pure [SchedulerEngine._evaluate] step: the fully
/// built [SchedulerDecision] plus the structured outcome the side-effecting
/// caller ([SchedulerEngine._evaluateOnce]) needs to act on.
///
/// [winner] is null when no candidate is eligible (the no-eligible/empty
/// paths). [isSwitch] mirrors `decision.isSwitch` and is the signal to
/// dispatch + re-arm the end-of-night park. Keeping these alongside the
/// decision lets the read-only preview path reuse [SchedulerEngine._evaluate]
/// without re-deriving them or touching engine state.
class _EvaluationOutcome {
  final SchedulerDecision decision;
  final TargetScore? winner;
  final bool isSwitch;

  const _EvaluationOutcome({
    required this.decision,
    required this.winner,
    required this.isSwitch,
  });
}

/// Site location used for altitude/azimuth and twilight math.
class SchedulerSite {
  final double latitudeDegrees;
  final double longitudeDegrees;

  /// User's local-timezone offset used to evaluate timeWindow constraints
  /// in the operator's clock rather than UTC.
  final Duration localOffset;

  const SchedulerSite({
    required this.latitudeDegrees,
    required this.longitudeDegrees,
    required this.localOffset,
  });
}

/// Ownership oracle for the run the engine dispatched — implemented alongside
/// [SchedulerSequenceSink] by any sink that can see the executor.
///
/// This is the token behind every [SchedulerSequenceSink.stopSequence] the
/// engine issues on its own initiative. The engine cannot answer the question
/// alone: its `currentTargetId` merely records the last target it dispatched,
/// and it stays set when that run ends by a path the engine never hears about
/// (operator Stop, abort, failure — only a natural completion reaches the
/// trigger stream). Treating it as ownership is what let a no-eligible tick end
/// the sequence the operator had started by hand.
///
/// Kept separate from [SchedulerSequenceSink] deliberately: Dart `implements`
/// inherits no bodies, so folding this into that interface would break every
/// existing sink (including ones outside this package) rather than letting them
/// opt in.
abstract class SchedulerRunOwnership {
  /// True when the sequence the engine dispatched as [sequenceId] is still the
  /// run the executor has loaded and active. Implementations compare the
  /// executor's loaded plan id AND its owner AND whether it is still executing.
  bool ownsRun(String sequenceId);

  /// True when the executor has ANY run in flight — the autopilot's or the
  /// operator's — in any non-settled phase.
  ///
  /// [ownsRun] alone cannot tell the two ways it returns false apart, and they
  /// call for opposite actions:
  ///   * the autopilot's run ended and nothing replaced it — the rig is FREE,
  ///     so the next eligible evaluation must dispatch again (a failed run
  ///     otherwise ends the unattended night) and dawn must still park;
  ///   * the operator took the rig back with a run of their own — the rig is
  ///     BUSY, so the autopilot must neither dispatch over it nor park it.
  bool get hasActiveRun;

  /// How the run the engine dispatched as [sequenceId] left the executor, asked
  /// only once [ownsRun] has gone false.
  ///
  /// The engine re-dispatches after a run that ended on its own and stands down
  /// after one somebody stopped, so the two cannot be folded together. Only the
  /// sink can tell them apart: it sees the executor's terminal state, which is
  /// `failed` for a run that died and settled/idle for a run that was stopped.
  SchedulerRunEnding endingFor(String sequenceId);
}

/// How a dispatched run stopped being the executor's active run.
enum SchedulerRunEnding {
  /// The run finished all of its work.
  completed,

  /// The run died on its own: a failed Center, a mount fault, a node error.
  /// Nobody decided anything, so the autopilot re-dispatches — one failed run
  /// must not end the unattended night.
  failed,

  /// Somebody outside the autopilot ended it: the operator's Stop, or a
  /// takeover that loaded a different plan. The autopilot pauses and asks
  /// before touching the rig again.
  stoppedByOperator,

  /// The executor has not settled yet (a stop or finalization still in flight),
  /// so the question has no answer at this tick. The engine keeps the run id
  /// and asks again next tick rather than guessing.
  unknown,
}

/// Sink for sequences generated by the engine. Concrete implementations
/// hand off to `SequencerService.startSequence(...)` or the
/// `SequenceExecutor.start()` provider. Tests inject a fake.
abstract class SchedulerSequenceSink {
  /// Called when the engine has selected a target and wants to start
  /// imaging. Implementations must persist or load the sequence and start
  /// it; the future completes once the sequencer accepts the sequence.
  Future<void> dispatchSequence(Sequence sequence);

  /// Called when the engine wants to pause whatever is currently running.
  Future<void> pauseSequence();

  /// Called when the engine wants to resume from pause.
  Future<void> resumeSequence();

  /// Called when the engine wants to stop the active sequence (e.g. on
  /// engine stop or a hard target swap).
  Future<void> stopSequence();

  /// Called exactly once when the autopilot is fully DISENGAGED (engine
  /// `stop()` / `dispose()`), as opposed to a mid-night target swap or a
  /// transient no-eligible tick (which use [stopSequence] and keep the
  /// autopilot engaged).
  ///
  /// Implementations restore manual ownership of the editor slot, returning the
  /// operator's stashed unsaved sequence that [dispatchSequence] preserved when
  /// the autopilot first took over. Default no-op so test/headless sinks that
  /// don't model editor ownership need no change.
  Future<void> releaseSequenceOwnership() async {}

  /// Called exactly once when the engine determines the observing night is
  /// genuinely over — every candidate is rejected AND the Sun has risen above
  /// the configured darkness limit ([SchedulerConfig.maxSunAltitudeDegrees]).
  ///
  /// This is the distinct end-of-night hook: [stopSequence] is also invoked on
  /// every mid-night target swap and on a transient no-eligible tick (clouds,
  /// all goals momentarily complete), so it cannot be used to park — that would
  /// park the mount on every swap. Implementations park the mount (stop
  /// tracking into the ground at dawn) and notify the operator. The engine
  /// guarantees this is called at most once per dawn transition; it re-arms
  /// only after the engine successfully dispatches another target (a new
  /// night begins).
  Future<void> parkForEndOfNight();
}
