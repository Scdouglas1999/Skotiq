import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/bridge_events.dart' show SequencerEvent_InstructionProgress;
import '../backend/remote_host.dart';
import '../backend/sequencer_run_events.dart' show sequencerEventOf;
import '../models/meridian_flip_event.dart';
import 'backend_provider.dart';
import 'meridian_flip_provider.dart';
import '../models/meridian_flip_progress.dart';
import '../utils/logging_service.dart';

/// Native flip steps feed the same state that linked clients mirror. Listen
/// on the host only; a viewer's authoritative source is its runtime snapshot.
final meridianFlipTelemetryProvider = Provider<void>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend.linksToHost) return;
  final subscription = backend.eventStream.listen(
    (event) {
      if (sequencerEventOf(event) case SequencerEvent_InstructionProgress(
        detailKind: 'MeridianFlip',
        detailJson: final raw,
      )) {
        _applyFlipStep(ref, raw);
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
});

void _applyFlipStep(Ref ref, String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return;
  }
  final progress = ref.read(flipMonitorProgressProvider.notifier);
  switch (MeridianFlipEvent.fromWire(decoded)) {
    case null:
      return;
    case MeridianFlipStarting():
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
    case MeridianFlipFailed(:final error):
      progress.end(FlipExecutionState.failed, error);
    case MeridianFlipAborted(:final reason):
      progress.end(FlipExecutionState.aborted, reason);
  }
}
