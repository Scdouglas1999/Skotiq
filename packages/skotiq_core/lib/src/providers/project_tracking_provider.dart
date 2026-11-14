import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database_provider.dart';
import 'scheduler_provider.dart' show integrationGoalsStreamProvider;
import '../services/project_tracking_service.dart';

final projectTrackingServiceProvider = Provider<ProjectTrackingService>((ref) {
  return const ProjectTrackingService();
});

final projectProgressListProvider = Provider<AsyncValue<List<ProjectProgress>>>(
  (ref) {
    final targetsAsync = ref.watch(allDbTargetsProvider);
    final sessionsAsync = ref.watch(allSessionsProvider);
    final framesAsync = ref.watch(allDbImagesProvider);
    final goalsAsync = ref.watch(integrationGoalsStreamProvider);
    final service = ref.watch(projectTrackingServiceProvider);

    for (final source in [
      targetsAsync,
      sessionsAsync,
      framesAsync,
      goalsAsync,
    ]) {
      if (source.hasError) {
        return AsyncValue.error(
          source.error!,
          source.stackTrace ?? StackTrace.current,
        );
      }
    }
    if (targetsAsync.isLoading ||
        sessionsAsync.isLoading ||
        framesAsync.isLoading ||
        goalsAsync.isLoading) {
      return const AsyncValue.loading();
    }

    return AsyncValue.data(
      service.summarize(
        targets: targetsAsync.value ?? const [],
        sessions: sessionsAsync.value ?? const [],
        frames: framesAsync.value ?? const [],
        goals: goalsAsync.value ?? const [],
      ),
    );
  },
);
