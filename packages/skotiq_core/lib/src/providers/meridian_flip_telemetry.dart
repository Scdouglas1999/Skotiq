import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/remote_host.dart';
import '../models/meridian_flip_event.dart';
import 'backend_provider.dart';
import 'meridian_flip_provider.dart';
import '../models/meridian_flip_progress.dart';

/// Native flip steps feed the same state that linked clients mirror. Listen
/// on the host only; a viewer's authoritative source is its runtime snapshot.
final meridianFlipTelemetryProvider = Provider<void>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend.linksToHost) return;
  final subscription = backend.eventStream.listen(
    (event) {
      if (event.eventType != 'InstructionProgress' ||
          event.data['detail_kind'] != 'MeridianFlip') {
        return;
      }
      final raw = event.data['detail_json'];
      if (raw is! String) return;
      final Object? decoded;
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        return;
      }
      switch (MeridianFlipEvent.fromWire(decoded)) {
        case null:
          return;
        case MeridianFlipStarting():
          ref.read(flipExecutionStateProvider.notifier).state =
              FlipExecutionState.executing;
          ref.read(flipCurrentAttemptProvider.notifier).state = 1;
          ref.read(flipCurrentStepProvider.notifier).state = null;
          ref.read(flipProgressProvider.notifier).state = 0;
          ref.read(flipLastErrorProvider.notifier).state = null;
        case MeridianFlipStepStarted(:final step):
          ref.read(flipExecutionStateProvider.notifier).state =
              FlipExecutionState.executing;
          ref.read(flipCurrentStepProvider.notifier).state = step;
        case MeridianFlipStepCompleted():
          break;
        case MeridianFlipStepFailed(:final step, :final error):
          ref.read(flipCurrentStepProvider.notifier).state = step;
          ref.read(flipLastErrorProvider.notifier).state = error;
        case MeridianFlipProgress(:final percent):
          if (percent != null) {
            ref.read(flipProgressProvider.notifier).state = percent.clamp(
              0,
              100,
            );
          }
        case MeridianFlipRetryScheduled(:final attempt):
          ref.read(flipExecutionStateProvider.notifier).state =
              FlipExecutionState.retrying;
          if (attempt != null) {
            ref.read(flipCurrentAttemptProvider.notifier).state = attempt + 1;
          }
          ref.read(flipProgressProvider.notifier).state = 0;
        case MeridianFlipCompleted():
          ref.read(flipExecutionStateProvider.notifier).state =
              FlipExecutionState.completed;
          ref.read(flipCurrentStepProvider.notifier).state = null;
          ref.read(flipProgressProvider.notifier).state = 100;
          ref.read(flipLastErrorProvider.notifier).state = null;
        case MeridianFlipFailed(:final error):
          endFlipMonitorProgress(ref, FlipExecutionState.failed, error);
        case MeridianFlipAborted(:final reason):
          endFlipMonitorProgress(ref, FlipExecutionState.aborted, reason);
      }
    },
    onError: (Object error, StackTrace stack) {
      developer.log(
        'Meridian flip telemetry failed',
        name: 'MeridianFlip',
        error: error,
        stackTrace: stack,
      );
    },
  );
  ref.onDispose(subscription.cancel);
});
