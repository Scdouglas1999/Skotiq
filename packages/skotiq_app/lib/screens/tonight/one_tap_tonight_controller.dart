import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// The phase the one-tap chain is in, surfaced to the UI so the single
/// primary action can narrate progress ("Framing…", "Planning…", "Starting…")
/// instead of an opaque spinner.
enum OneTapPhase {
  /// Nothing has run yet — the GO button is armed.
  idle,

  /// Resolving tonight's opinionated target pick.
  picking,

  /// Handing the pick to the framing assistant (auto-frame).
  framing,

  /// Drafting the Smart Night sequence for the pick.
  planning,

  /// Loading the sequence and starting the unattended run.
  starting,

  /// The run is live.
  running,

  /// The chain stopped on an error (see [OneTapTonightState.error]).
  failed,
}

@immutable
class OneTapTonightState {
  final OneTapPhase phase;

  /// The target the chain picked / is running, once resolved.
  final TargetSuggestion? target;

  /// The drafted sequence, once the planning phase completes.
  final SingleTargetSequenceResult? plan;

  /// Human-readable failure message when [phase] is [OneTapPhase.failed].
  final String? error;

  const OneTapTonightState({
    this.phase = OneTapPhase.idle,
    this.target,
    this.plan,
    this.error,
  });

  bool get isBusy =>
      phase == OneTapPhase.picking ||
      phase == OneTapPhase.framing ||
      phase == OneTapPhase.planning ||
      phase == OneTapPhase.starting;

  /// Whether the chain can still be abandoned without touching the rig:
  /// nothing has been handed to the sequencer yet. Once it is starting, the
  /// run's own Stop is the control.
  bool get canCancel =>
      phase == OneTapPhase.picking ||
      phase == OneTapPhase.framing ||
      phase == OneTapPhase.planning;

  OneTapTonightState copyWith({
    OneTapPhase? phase,
    TargetSuggestion? target,
    SingleTargetSequenceResult? plan,
    String? error,
    bool clearError = false,
  }) {
    return OneTapTonightState(
      phase: phase ?? this.phase,
      target: target ?? this.target,
      plan: plan ?? this.plan,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Resolves tonight's single opinionated target.
typedef OneTapTargetPicker = Future<TargetSuggestion?> Function();

/// Hands a picked target to the framing assistant (auto-frame step).
typedef OneTapFramer = void Function(TargetSuggestion target);

/// Drafts a ready-to-run Smart Night sequence for the picked target.
typedef OneTapPlanner = Future<SingleTargetSequenceResult> Function(
  TargetSuggestion target,
);

/// Loads the drafted sequence into the editor and starts the unattended run.
typedef OneTapRunner = Future<void> Function(SingleTargetSequenceResult plan);

/// Thrown when the picker finds no imageable target tonight. Carried as a
/// loud failure rather than a silent no-op so the screen can explain *why*
/// (location unset, sky below horizon, weather unsafe).
///
/// The default message is the genuinely-ambiguous case: a configured site with
/// nothing clearing its limits. Causes the picker can identify — an unset
/// observing location, above all — pass their own message rather than listing
/// possibilities the app could have checked.
class NoTonightTargetException implements Exception {
  final String message;
  const NoTonightTargetException([
    this.message = 'Nothing clears your horizon and moon limits right now. '
        'Try again later tonight, or widen the limits in Plan Tonight.',
  ]);
  @override
  String toString() => 'NoTonightTargetException: $message';
}

/// Opinionated one-tap chain: pick a target → auto-frame → draft a Smart
/// Night plan → start the unattended run.
///
/// This is a thin orchestrator over services that already exist
/// (`schedulerPreviewDecisionProvider`/`bestSuggestionProvider`, the framing
/// assistant, the Smart Night sequence builder, the sequence executor). It
/// owns NO scheduling, exposure, or scoring logic — every phase delegates to
/// an injected seam ([OneTapTargetPicker], [OneTapFramer], [OneTapPlanner],
/// [OneTapRunner]). The screen wires those seams to the live providers; the
/// chain test injects fakes through the same constructor, so the orchestration
/// is exercisable end-to-end without a DB / network / native bridge.
///
/// It deliberately does NOT replace the deep sequencer/scheduler: the chain
/// produces an ordinary editable sequence and starts it the same way the
/// Smart Night launcher does, so "Advanced" stays one tap away.
class OneTapTonightController extends ValueNotifier<OneTapTonightState> {
  final OneTapTargetPicker _pick;
  final OneTapFramer _frame;
  final OneTapPlanner _plan;
  final OneTapRunner _run;

  /// How long planning may take before the chain gives up. A local plan is
  /// built in seconds; on a linked computer it waits on the host, and a host
  /// that stopped answering must not leave the button spinning.
  final Duration _planTimeout;

  OneTapTonightController({
    required OneTapTargetPicker pick,
    required OneTapFramer frame,
    required OneTapPlanner plan,
    required OneTapRunner run,
    Duration planTimeout = const Duration(seconds: 60),
  })  : _pick = pick,
        _frame = frame,
        _plan = plan,
        _run = run,
        _planTimeout = planTimeout,
        super(const OneTapTonightState());

  /// Counts the chains started; a chain whose number is no longer current
  /// was canceled and publishes nothing more.
  int _chain = 0;

  /// Set once [dispose] runs. The chain's awaits (pick / plan / run) can each
  /// outlive the screen — if the operator navigates away mid-run this notifier
  /// is disposed while `go()` is still suspended, and a post-await `value =`
  /// would then throw "used after being disposed". Every publish consults this.
  bool _disposed = false;

  OneTapTonightState get state => value;

  /// Publish [next] unless the notifier was disposed mid-chain. Writing [value]
  /// on a disposed [ValueNotifier] throws; a no-op is the correct behavior once
  /// the screen (and its listeners) are gone.
  void _publish(OneTapTonightState next) {
    if (_disposed) return;
    value = next;
  }

  /// Run the whole chain: pick → frame → plan → GO. Re-arms cleanly — a
  /// second tap after a failure starts over from [OneTapPhase.picking].
  Future<void> go() async {
    if (state.isBusy) return;
    final chain = ++_chain;
    bool current() => chain == _chain;
    _publish(const OneTapTonightState(phase: OneTapPhase.picking));
    try {
      final target = await _pick();
      if (!current()) return;
      if (target == null) {
        throw const NoTonightTargetException();
      }
      _publish(state.copyWith(phase: OneTapPhase.framing, target: target));

      _frame(target);

      _publish(state.copyWith(phase: OneTapPhase.planning));
      final plan = await _plan(target).timeout(_planTimeout);
      if (!current()) return;
      _publish(state.copyWith(phase: OneTapPhase.starting, plan: plan));

      await _run(plan);
      _publish(state.copyWith(phase: OneTapPhase.running));
    } on NoTonightTargetException catch (e) {
      if (current()) _fail(e.message);
    } on SmartNightBuildException catch (e) {
      if (current()) _fail(e.message);
    } on TimeoutException {
      if (current()) {
        _fail(
          'Planning the night did not finish within '
          '${_planTimeout.inSeconds} s, so Skotiq stopped waiting. If this '
          'computer drives a rig over the network, check that the host is '
          'reachable, then try again.',
        );
      }
    } catch (e) {
      if (current()) _fail('Could not start tonight: ${userFacingError(e)}');
    }
  }

  void _fail(String message) =>
      _publish(state.copyWith(phase: OneTapPhase.failed, error: message));

  /// Abandon the chain before anything reaches the sequencer and re-arm GO.
  /// Work already asked of the planner finishes on its own and is discarded.
  void cancel() {
    if (!state.canCancel) return;
    _chain++;
    _publish(const OneTapTonightState());
  }

  /// Clear a failed run so the GO button re-arms in [OneTapPhase.idle].
  void reset() {
    if (state.isBusy) return;
    value = const OneTapTonightState();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
