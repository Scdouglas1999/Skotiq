import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/bridge_events.dart' show SequencerEvent_InstructionProgress;
import '../backend/remote_host.dart';
import '../backend/sequencer_run_events.dart' show sequencerEventOf;
import '../models/meridian_flip_event.dart';
import '../models/sequence/sequence_models.dart';
import 'backend_provider.dart';
import 'meridian_flip_provider.dart';
import 'sequence/sequence_progress.dart' show sequenceExecutionStateProvider;
import '../models/meridian_flip_progress.dart';
import '../utils/logging_service.dart';

/// Native flip steps feed the same state that linked clients mirror. Listen
/// on the host only; a viewer's authoritative source is its runtime snapshot.
final meridianFlipTelemetryProvider = Provider<void>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend.hostPlace.isLinked) return;
  // The flip the run's end ended, until the next flip starts: its own end
  // may still arrive and keeps what the flip reached.
  var endedAtRunEnd = false;
  final subscription = backend.eventStream.listen(
    (event) {
      if (sequencerEventOf(event) case SequencerEvent_InstructionProgress(
        detailKind: 'MeridianFlip',
        detailJson: final raw,
      )) {
        endedAtRunEnd = _applyFlipStep(ref, raw, endedAtRunEnd: endedAtRunEnd);
      }
    },
    onError: (Object error, StackTrace stack) {
      Log.debug(
        'Meridian flip telemetry failed',
        source: 'MeridianFlip',
        error: error,
        stackTrace: stack,
      );
    },
  );
  ref.onDispose(subscription.cancel);
  // The native run ends a flip before it lets go of the rig, but a flip it
  // drops (a stop whose cleanup ran out of time) sends no end. A flip still
  // in progress once the run lets go of the rig has ended.
  ref.listen<SequenceExecutionState>(sequenceExecutionStateProvider, (
    previous,
    next,
  ) {
    if (previous == null || !previous.ownsHardware || next.ownsHardware) {
      return;
    }
    // The flip monitor's own flip can run while a run winds down; it ends
    // with its own outcome.
    if (!ref.read(isFlipInProgressProvider) ||
        ref.read(standaloneFlipInFlightProvider)) {
      return;
    }
    Log.warning(
      'The run ended while its meridian flip was in progress; '
      'ending the flip as aborted',
      source: 'MeridianFlip',
    );
    ref
        .read(flipMonitorProgressProvider.notifier)
        .end(
          FlipExecutionState.aborted,
          'The run ended during the meridian flip',
        );
    endedAtRunEnd = true;
  });
});

/// Applies one native flip step; returns whether the flip is still the one
/// the run's end ended ([endedAtRunEnd] until another flip starts).
bool _applyFlipStep(Ref ref, String raw, {required bool endedAtRunEnd}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return endedAtRunEnd;
  }
  final progress = ref.read(flipMonitorProgressProvider.notifier);
  switch (MeridianFlipEvent.fromWire(decoded)) {
    case null:
      return endedAtRunEnd;
    case MeridianFlipStarting():
      endedAtRunEnd = false;
      progress.update(
        (p) => p.copyWith(
          state: FlipExecutionState.executing,
          attempt: 1,
          clearStep: true,
          percent: 0,
          clearError: true,
        ),
      );
    case MeridianFlipStepStarted(:final step):
      progress.update(
        (p) => p.copyWith(
          state: FlipExecutionState.executing,
          step: step,
          clearStep: step == null,
        ),
      );
    case MeridianFlipStepCompleted():
      break;
    case MeridianFlipStepFailed(:final step, :final error):
      progress.update(
        (p) => p.copyWith(
          step: step,
          clearStep: step == null,
          error: error,
          clearError: error == null,
        ),
      );
    case MeridianFlipProgress(:final percent):
      if (percent != null) {
        progress.update((p) => p.copyWith(percent: percent.clamp(0, 100)));
      }
    case MeridianFlipRetryScheduled(:final attempt):
      progress.update(
        (p) => p.copyWith(
          state: FlipExecutionState.retrying,
          attempt: attempt == null ? null : attempt + 1,
          percent: 0,
        ),
      );
    case MeridianFlipCompleted():
      progress.update(
        (p) => p.copyWith(
          state: FlipExecutionState.completed,
          clearStep: true,
          percent: 100,
          clearError: true,
        ),
      );
      endedAtRunEnd = false;
    case MeridianFlipFailed(:final error):
      _endWith(progress, FlipExecutionState.failed, error, endedAtRunEnd);
      endedAtRunEnd = false;
    case MeridianFlipAborted(:final reason):
      _endWith(progress, FlipExecutionState.aborted, reason, endedAtRunEnd);
      endedAtRunEnd = false;
  }
  return endedAtRunEnd;
}

/// Ends the flip as [outcome]; a flip the run's end already ended keeps the
/// attempt, step and progress it reached.
void _endWith(
  FlipMonitorProgressNotifier progress,
  FlipExecutionState outcome,
  String? error,
  bool endedAtRunEnd,
) => endedAtRunEnd
    ? progress.update(
        (p) =>
            p.copyWith(state: outcome, error: error, clearError: error == null),
      )
    : progress.end(outcome, error);
