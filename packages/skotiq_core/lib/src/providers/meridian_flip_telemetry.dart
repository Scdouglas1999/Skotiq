import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/remote_host.dart';
import '../models/meridian_flip_event.dart';
import 'backend_provider.dart';
import 'meridian_flip_provider.dart';

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
      if (decoded is! Map<String, dynamic> || decoded.length != 1) return;
      final data = decoded.values.single;
      if (data is! Map<String, dynamic>) return;
      final stepName = data['step'];
      final step = stepName is String ? flipStepFromNativeName(stepName) : null;
      switch (decoded.keys.single) {
        case 'Starting':
          ref.read(flipExecutionStateProvider.notifier).state =
              FlipExecutionState.executing;
          ref.read(flipCurrentAttemptProvider.notifier).state = 1;
          ref.read(flipCurrentStepProvider.notifier).state = null;
          ref.read(flipProgressProvider.notifier).state = 0;
          ref.read(flipLastErrorProvider.notifier).state = null;
        case 'StepStarted':
          ref.read(flipExecutionStateProvider.notifier).state =
              FlipExecutionState.executing;
          ref.read(flipCurrentStepProvider.notifier).state = step;
        case 'StepFailed':
          ref.read(flipCurrentStepProvider.notifier).state = step;
          ref.read(flipLastErrorProvider.notifier).state =
              data['error'] as String?;
        case 'Progress':
          final percent = data['percent'];
          if (percent is num) {
            ref.read(flipProgressProvider.notifier).state = percent
                .toInt()
                .clamp(0, 100);
          }
        case 'RetryScheduled':
          ref.read(flipExecutionStateProvider.notifier).state =
              FlipExecutionState.retrying;
          final attempt = data['attempt'];
          if (attempt is num) {
            ref.read(flipCurrentAttemptProvider.notifier).state =
                attempt.toInt() + 1;
          }
          ref.read(flipProgressProvider.notifier).state = 0;
        case 'Completed':
          ref.read(flipExecutionStateProvider.notifier).state =
              FlipExecutionState.completed;
          ref.read(flipCurrentStepProvider.notifier).state = null;
          ref.read(flipProgressProvider.notifier).state = 100;
          ref.read(flipLastErrorProvider.notifier).state = null;
        case 'Failed':
          ref.read(flipExecutionStateProvider.notifier).state =
              FlipExecutionState.failed;
          ref.read(flipLastErrorProvider.notifier).state =
              data['error'] as String?;
        case 'Aborted':
          ref.read(flipExecutionStateProvider.notifier).state =
              FlipExecutionState.aborted;
          ref.read(flipLastErrorProvider.notifier).state =
              data['reason'] as String?;
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
