import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/focus_model_service.dart';
import '../utils/logging_service.dart';
import 'database_provider.dart';

final focusModelServiceProvider = Provider<FocusModelService>((ref) {
  // Plumb user-configurable thresholds
  // through so the autofocus settings panel can override the rejection /
  // reliability / filter-offset gates without a recompile.
  final config = ref.watch(focusModelConfigProvider);
  final service = FocusModelService(
    ref.watch(databaseProvider).focusHistoryDao,
    config: config,
  );
  // Readers await initialize() themselves; this early start only warms the
  // cache, so its failure is logged here and raised again to those readers.
  unawaited(
    service.initialize().catchError((Object e, StackTrace s) {
      Log.error(
        'Focus models did not load: $e',
        source: 'focusModelServiceProvider',
        error: e,
        stackTrace: s,
      );
    }),
  );
  return service;
});

/// Provider for the focus-model thresholds. Defaults reproduce the prior
/// hardcoded behaviour exactly. Override this provider from the autofocus
/// settings panel (or in tests) to change behaviour.
///
final focusModelConfigProvider = StateProvider<FocusModelConfig>(
  (_) => const FocusModelConfig(),
);
