import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/backend.dart' show RunStillPaused;
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import 'command_action_result.dart';

final sequenceActionServiceProvider =
    Provider((ref) => SequenceActionService(ref));

/// The operator closed the pre-flight checks of a generated plan without
/// starting it ([SequenceActionService.startOwnedPlan]).
class PlanStartCanceled implements Exception {
  const PlanStartCanceled();

  @override
  String toString() => 'The plan was not started: pre-flight was closed.';
}

/// The distinct playback commands, keyed for the shared single-flight latch.
enum _SequenceCommand { start, pause, hold, release, resume, stop, skip, reset }

/// Centralized service for sequence playback actions.
///
/// This eliminates duplicate sequence control implementations across screens.
/// All sequence control buttons should use this service instead of implementing
/// their own try/catch patterns with sequenceExecutorProvider.
///
/// Shared single-flight: every playback surface — the desktop toolbar, the
/// mobile playback bar, the dashboard cockpit strip, and the persistent
/// app-shell mini bar — routes through this ONE service instance (the provider
/// is app-scoped), so the [_inFlight] latch below is shared across all of them.
/// Two of those surfaces are on screen at the same time during a run (the
/// dashboard renders both the cockpit strip and the mini bar), so a stray
/// double-press — one on each — is a real scenario, not just a fast double-tap.
class SequenceActionService {
  final Ref _ref;

  SequenceActionService(this._ref);

  SequenceExecutor get _executor => _ref.read(sequenceExecutorProvider);

  /// One in-flight future per command kind. A second call of the SAME command
  /// while the first is still running JOINS that future instead of issuing a
  /// duplicate backend command.
  ///
  /// The latch is load-bearing for two commands: `skip()` has NO single-use
  /// guard of its own, so two concurrent skips advance the native node pointer
  /// twice, and a double-fired start bounces off the executor's start latch as
  /// a StateError. For pause/resume/stop/reset the executor already refuses or
  /// coalesces; joining just gives every caller one truthful result instead of
  /// an "operation already in progress" error.
  final Map<_SequenceCommand, Future<CommandActionResult>> _inFlight = {};

  /// Run [body] under the single-flight latch for [kind]: return the in-flight
  /// future if one exists, otherwise start [body], track it, and clear the
  /// latch when it settles so the next press issues a fresh command.
  Future<CommandActionResult> _single(
    _SequenceCommand kind,
    Future<CommandActionResult> Function() body,
  ) {
    final existing = _inFlight[kind];
    if (existing != null) return existing;
    late final Future<CommandActionResult> future;
    future = body().whenComplete(() {
      if (identical(_inFlight[kind], future)) _inFlight.remove(kind);
    });
    _inFlight[kind] = future;
    return future;
  }

  /// Starts the sequence.
  ///
  /// `_executor.start()` is async — full pre-flight validation, including an
  /// async disk-space check — so it MUST be awaited. Without the await this
  /// returns `ok` before validation completes and swallows any
  /// [SequenceValidationException].
  Future<CommandActionResult> start() => _start(_executor.start);

  /// Starts the sequence for a start nobody is at the keyboard for (Start
  /// at dark): a manual capture left running is ended first
  /// ([SequenceExecutor.startUnattended]).
  Future<CommandActionResult> startUnattended() =>
      _start(_executor.startUnattended);

  Future<CommandActionResult> _start(Future<void> Function() run) =>
      _single(_SequenceCommand.start, () async {
        if (!_ref.read(sequenceExecutionStateProvider).canStart) {
          return CommandActionResult.ok;
        }
        try {
          await run();
          return CommandActionResult.ok;
        } catch (e) {
          // The Start control that asked may be gone by the time the refusal
          // comes back, so the reason goes out as an app-wide notification.
          final reason = userFacingError(e);
          _ref.read(loggingServiceProvider).warning(
                'The run did not start: $reason',
                source: 'SequenceActionService',
              );
          _ref.read(uiNotificationProvider.notifier).showError(
                reason,
                title: 'The run did not start',
              );
          return CommandActionResult.failure(
            'The run did not start: $reason',
            alreadyShown: true,
          );
        }
      });

  /// Hands the editor to the generated [sequence], owned by [owner], and
  /// starts it: Smart Night, a planner recommendation and a mosaic project.
  /// Taking ownership keeps the operator's unsaved sequence, which a stop of
  /// the run restores. The start shares the Start command's single-flight
  /// latch. A refusal to start is thrown to the caller; one the executor's
  /// state or a start already under way makes is thrown before the editor
  /// changes, so the editor keeps showing the run that is on.
  ///
  /// A caller with a screen passes [confirm], the pre-flight checks the
  /// editor's own Start shows: the plan is loaded for them, and closing them
  /// gives the editor back and throws [PlanStartCanceled]. Without [confirm]
  /// (no window to show them on) the checks run beside the start and their
  /// findings are posted as a notification; they never hold the start back.
  Future<void> startOwnedPlan(
    Sequence sequence,
    ActivePlanOwner owner, {
    Future<bool> Function()? confirm,
  }) async {
    _ensureStartAdmissible();
    final editor = _ref.read(currentSequenceProvider.notifier);
    Future<void> report = Future<void>.value();
    if (confirm != null) {
      editor.takeOwnership(sequence, owner);
      final bool go;
      try {
        go = await confirm();
      } on Object {
        editor.releaseOwnership();
        rethrow;
      }
      if (!go) {
        editor.releaseOwnership();
        throw const PlanStartCanceled();
      }
      try {
        _ensureStartAdmissible();
      } on Object {
        editor.releaseOwnership();
        rethrow;
      }
    } else {
      // Beside the start, not before it: the run does not wait for the check.
      report = _reportPreflight(sequence);
    }
    (Object, StackTrace)? refusal;
    await _single(_SequenceCommand.start, () async {
      if (confirm == null) editor.takeOwnership(sequence, owner);
      try {
        await _executor.start();
        return CommandActionResult.ok;
      } catch (e, stack) {
        // A Start, Pause or Stop pressed meanwhile waits on this latch and
        // gets the refusal as a result; the plan's caller gets it thrown.
        refusal = (e, stack);
        return CommandActionResult.failure(
          'The run did not start: ${userFacingError(e)}',
        );
      }
    });
    await report;
    if (refusal case (final error, final stack)) {
      Error.throwWithStackTrace(error, stack);
    }
  }

  void _ensureStartAdmissible() {
    final state = _ref.read(sequenceExecutionStateProvider);
    if (_inFlight.containsKey(_SequenceCommand.start) || !state.canStart) {
      throw StateError(
        'Cannot start: a sequence start is already in flight or the executor '
        'is not in an admissible state (state: ${state.name}).',
      );
    }
    _executor.ensureRigFreeForStart();
  }

  /// The pre-flight findings of a plan started without a screen to show them
  /// on, as one notification.
  Future<void> _reportPreflight(Sequence sequence) async {
    try {
      final result = await _ref.read(sequenceValidatorProvider).validate(
            sequence,
          );
      final issues = [
        for (final issue in result.issues)
          if (issue.severity != ValidationSeverity.info) issue,
      ];
      if (issues.isEmpty) return;
      final more = issues.length > 1 ? ' (and ${issues.length - 1} more)' : '';
      _ref.read(uiNotificationProvider.notifier).showWarning(
            '${issues.first.title}$more',
            title: 'Pre-flight for ${sequence.name}',
          );
    } catch (e) {
      _ref.read(loggingServiceProvider).warning(
            'The pre-flight check of ${sequence.name} did not run: $e',
            source: 'SequenceActionService',
          );
    }
  }

  Future<CommandActionResult> pause() => _single(
      _SequenceCommand.pause,
      () => _afterStart(() async {
            if (!_ref.read(sequenceExecutionStateProvider).canPause) {
              return CommandActionResult.ok;
            }
            try {
              await _executor.pause();
              return CommandActionResult.ok;
            } catch (e) {
              return CommandActionResult.failure(
                  'Failed to pause sequence: ${userFacingError(e)}');
            }
          }));

  /// Holds the run for a manual action this app runs: a running run is
  /// paused, a paused one stays paused, and until [endActionHold] the
  /// run's host refuses every other resume or skip.
  Future<CommandActionResult> holdForAction() => _single(
      _SequenceCommand.hold,
      () => _afterStart(() async {
            final state = _ref.read(sequenceExecutionStateProvider);
            if (!state.canPause && state != SequenceExecutionState.paused) {
              return CommandActionResult.ok;
            }
            try {
              await _executor.holdForAction();
              return CommandActionResult.ok;
            } catch (e) {
              return CommandActionResult.failure(
                  'Failed to pause sequence: ${userFacingError(e)}');
            }
          }));

  /// Ends this app's manual-action hold. The run's host resumes the run when
  /// the hold is what paused it; a run it found paused is left as it is
  /// ([CommandActionResult.leftPaused]). The hold ends even when the resume
  /// fails.
  Future<CommandActionResult> endActionHold() => _single(
      _SequenceCommand.release,
      () => _afterStart(() async {
            try {
              final resumed = await _executor.endActionHold();
              return resumed
                  ? CommandActionResult.ok
                  : const CommandActionResult.leftPaused();
            } on RunStillPaused catch (stillPaused) {
              return CommandActionResult.stillPaused(stillPaused.pausedBy);
            } catch (e) {
              return CommandActionResult.failure(
                  'Failed to resume sequence: ${userFacingError(e)}');
            }
          }));

  /// Resumes a paused run. While a manual action holds the pause, only that
  /// action's end resumes it ([endActionHold]): any other resume
  /// would move the run on while the action still uses the rig.
  Future<CommandActionResult> resume() => _single(
      _SequenceCommand.resume,
      () => _afterStart(() async {
            if (!_ref.read(sequenceExecutionStateProvider).canResume) {
              return CommandActionResult.ok;
            }
            if (_actionHoldsRun) return _heldByAction;
            try {
              await _executor.resume();
              return CommandActionResult.ok;
            } catch (e) {
              return CommandActionResult.failure(
                  'Failed to resume sequence: ${userFacingError(e)}');
            }
          }));

  /// Stops the sequence.
  ///
  /// Audit C3 — user-initiated stops preserve the checkpoint by default
  /// so the operator can resume the run later (e.g. paused last night,
  /// stopped this morning, want to keep going tonight). Pass
  /// `preserveCheckpoint: false` from a "discard and stop" affordance
  /// when the user explicitly wants the checkpoint cleared.
  ///
  /// Single-flight note: a Stop retry (from stopFailed / cleanupFailed) or a
  /// second surface pressing Stop JOINS the in-flight stop — the first caller's
  /// [preserveCheckpoint] intent wins, matching the executor's own
  /// finalization join, so a retry never duplicates the native stop or cleanup.
  Future<CommandActionResult> stop({bool preserveCheckpoint = true}) => _single(
      _SequenceCommand.stop,
      () => _afterStart(() async {
            // start() publishes `running` before it has finished acquiring the
            // session, run row, event subscription, and native executor. A Stop
            // from another visible control surface during that window must wait;
            // otherwise teardown can race resources that start is still creating.
            if (!_ref.read(sequenceExecutionStateProvider).canStop) {
              return CommandActionResult.ok;
            }
            try {
              await _executor.stop(preserveCheckpoint: preserveCheckpoint);
              return CommandActionResult.ok;
            } catch (e) {
              return CommandActionResult.failure(
                  'Failed to stop sequence: ${userFacingError(e)}');
            }
          }));

  /// Skips the current sequence item.
  ///
  /// [showFeedback] - If true, shows a snackbar confirming the skip.
  ///
  /// Guards on [SequenceExecutionStateCapabilities.canSkip] before forwarding:
  /// skip only advances the node pointer while the run is running or paused, so
  /// if the state has already moved on (e.g. the run ended between the tap and
  /// this async callback) we return a silent no-op instead of issuing a
  /// meaningless native skip and then falsely reporting "Skipped current item".
  Future<CommandActionResult> skip({bool showFeedback = true}) => _single(
      _SequenceCommand.skip,
      () => _afterStart(() async {
            if (!_ref.read(sequenceExecutionStateProvider).canSkip) {
              return CommandActionResult.ok;
            }
            if (_actionHoldsRun) return _heldByAction;
            try {
              await _executor.skip();
              if (showFeedback) {
                return const CommandActionResult.success(
                  message: 'Skipped current item',
                  feedbackType: CommandFeedbackType.info,
                );
              }
              return CommandActionResult.ok;
            } catch (e) {
              return CommandActionResult.failure(
                  'Failed to skip: ${userFacingError(e)}');
            }
          }));

  /// Resets the sequence to its initial state.
  ///
  /// Awaited end to end: [SequenceExecutor.reset] first stops any live (or
  /// stop-failed / cleanup-failed) run before clearing progress — and a stop
  /// that cannot confirm the hardware stopped (or whose cleanup failed) throws,
  /// so the reset does NOT force a resettable idle. Returning a
  /// [CommandActionResult] lets toolbar callbacks await the reset, gate their
  /// busy state on it, and surface a failure rather than swallow it.
  Future<CommandActionResult> reset() => _single(
      _SequenceCommand.reset,
      () => _afterStart(() async {
            if (!_ref.read(sequenceExecutionStateProvider).canReset) {
              return CommandActionResult.ok;
            }
            try {
              await _executor.reset();
              return CommandActionResult.ok;
            } catch (e) {
              return CommandActionResult.failure(
                  'Failed to reset sequence: ${userFacingError(e)}');
            }
          }));

  /// The run's host publishes the hold, whichever window or client runs the
  /// action, and refuses the command as well.
  bool get _actionHoldsRun =>
      _ref.read(sequenceExecutionStateProvider) ==
          SequenceExecutionState.paused &&
      _ref.read(runHeldByActionProvider);

  static const _heldByAction = CommandActionResult.failure(
    'A manual action holds the run paused; it resumes the run when it '
    'finishes.',
  );

  Future<CommandActionResult> _afterStart(
    Future<CommandActionResult> Function() body,
  ) {
    final start = _inFlight[_SequenceCommand.start];
    if (start == null) return body();
    return start.then((_) => body());
  }
}
