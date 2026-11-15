import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

/// Where the Image tonight chain is, so its one button can say what it is
/// doing ("Framing…", "Planning…") instead of spinning.
enum ImageTonightPhase {
  /// Nothing has run; the button is armed.
  idle,

  /// Checking that this rig can run the night at all.
  checking,

  /// Handing the target to the framing assistant.
  framing,

  /// Drafting the Smart Night sequence for the target.
  planning,

  /// Loading the sequence and starting the run.
  starting,

  /// The run is live.
  running,

  /// The chain stopped on an error (see [ImageTonightState.error]).
  failed,
}

@immutable
class ImageTonightState {
  final ImageTonightPhase phase;

  /// The target the chain is imaging, once a chain has started.
  final TargetSuggestion? target;

  /// The drafted sequence, once planning has finished.
  final SingleTargetSequenceResult? plan;

  /// What stopped the chain, in words for the operator, when [phase] is
  /// [ImageTonightPhase.failed].
  final String? error;

  const ImageTonightState({
    this.phase = ImageTonightPhase.idle,
    this.target,
    this.plan,
    this.error,
  });

  bool get isBusy =>
      phase == ImageTonightPhase.checking ||
      phase == ImageTonightPhase.framing ||
      phase == ImageTonightPhase.planning ||
      phase == ImageTonightPhase.starting;

  /// Whether the chain can still be abandoned without touching the rig:
  /// nothing has been handed to the sequencer yet. Once it is starting, the
  /// run's own Stop is the control.
  bool get canCancel =>
      phase == ImageTonightPhase.checking ||
      phase == ImageTonightPhase.framing ||
      phase == ImageTonightPhase.planning;

  ImageTonightState copyWith({
    ImageTonightPhase? phase,
    SingleTargetSequenceResult? plan,
    String? error,
  }) {
    return ImageTonightState(
      phase: phase ?? this.phase,
      target: target,
      plan: plan ?? this.plan,
      error: error ?? this.error,
    );
  }
}

/// Why the night cannot run as planned on this rig, in words for the
/// operator, or null when nothing stands in the way. Checked before anything
/// is framed or planned, so a missing prerequisite is said up front instead of
/// after a minute of planning.
typedef ImageTonightPreflight = Future<String?> Function();

/// Hands the target to the framing assistant.
typedef ImageTonightFramer = void Function(TargetSuggestion target);

/// Drafts a ready-to-run Smart Night sequence for the target.
typedef ImageTonightPlanner = Future<SingleTargetSequenceResult> Function(
  TargetSuggestion target,
);

/// Loads the drafted sequence and starts the unattended run.
typedef ImageTonightRunner = Future<void> Function(
  SingleTargetSequenceResult plan,
);

/// Image tonight: frame a target, draft a Smart Night plan for it with the
/// planner's defaults, and start the unattended run, in one press.
///
/// It owns no scheduling, exposure or scoring logic; every step is an
/// injected seam, which Best tonight wires to the live providers and the tests
/// to fakes. The plan it starts is an ordinary editable sequence, so "Build
/// sequence" (review the options, then start from Tonight) stays beside it.
class ImageTonightController extends ValueNotifier<ImageTonightState> {
  final ImageTonightPreflight _preflight;
  final ImageTonightFramer _frame;
  final ImageTonightPlanner _plan;
  final ImageTonightRunner _run;

  /// How long planning may take before the chain gives up. A local plan is
  /// built in seconds; on a linked computer it waits on the host, and a host
  /// that stopped answering must not leave the button spinning.
  final Duration _planTimeout;

  ImageTonightController({
    ImageTonightPreflight? preflight,
    required ImageTonightFramer frame,
    required ImageTonightPlanner plan,
    required ImageTonightRunner run,
    Duration planTimeout = const Duration(seconds: 60),
  })  : _preflight = preflight ?? _nothingInTheWay,
        _frame = frame,
        _plan = plan,
        _run = run,
        _planTimeout = planTimeout,
        super(const ImageTonightState());

  static Future<String?> _nothingInTheWay() async => null;

  /// Counts the chains started; a chain whose number is no longer current
  /// was canceled and publishes nothing more.
  int _chain = 0;

  /// Set once [dispose] runs. The chain's awaits can outlive the screen, and
  /// writing [value] on a disposed notifier throws.
  bool _disposed = false;

  ImageTonightState get state => value;

  void _publish(ImageTonightState next) {
    if (_disposed) return;
    value = next;
  }

  /// Runs the chain for [target]: check, frame, plan, start. A press after a
  /// failure starts over.
  Future<void> go(TargetSuggestion target) async {
    if (state.isBusy) return;
    final chain = ++_chain;
    bool current() => chain == _chain;
    _publish(ImageTonightState(
      phase: ImageTonightPhase.checking,
      target: target,
    ));
    try {
      final blocked = await _preflight();
      if (!current()) return;
      if (blocked != null) {
        _fail(blocked);
        return;
      }
      _publish(state.copyWith(phase: ImageTonightPhase.framing));
      _frame(target);

      _publish(state.copyWith(phase: ImageTonightPhase.planning));
      final plan = await _plan(target).timeout(_planTimeout);
      if (!current()) return;
      _publish(state.copyWith(phase: ImageTonightPhase.starting, plan: plan));

      await _run(plan);
      if (current()) {
        _publish(state.copyWith(phase: ImageTonightPhase.running));
      }
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
      _publish(state.copyWith(phase: ImageTonightPhase.failed, error: message));

  /// Abandons the chain before anything reaches the sequencer. Work already
  /// asked of the planner finishes on its own and is discarded.
  void cancel() {
    if (!state.canCancel) return;
    _chain++;
    _publish(const ImageTonightState());
  }

  /// Clears a failed or finished chain so the button re-arms.
  void reset() {
    if (state.isBusy) return;
    _publish(const ImageTonightState());
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
