import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/focus_model_service.dart';

final focusModelServiceProvider = Provider<FocusModelService>((ref) {
  // Plumb user-configurable thresholds
  // through so the autofocus settings panel can override the rejection /
  // reliability / filter-offset gates without a recompile.
  final config = ref.watch(focusModelConfigProvider);
  final service = FocusModelService(config: config);
  unawaited(service.initialize());
  return service;
});

/// Provider for the focus-model thresholds. Defaults reproduce the prior
/// hardcoded behaviour exactly. Override this provider from the autofocus
/// settings panel (or in tests) to change behaviour.
///
final focusModelConfigProvider = StateProvider<FocusModelConfig>(
  (_) => const FocusModelConfig(),
);
