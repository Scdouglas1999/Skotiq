import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database_provider.dart';
import '../services/project_tracking_service.dart';

final projectTrackingServiceProvider = Provider<ProjectTrackingService>((ref) {
  return const ProjectTrackingService();
});

final projectProgressListProvider = Provider<AsyncValue<List<ProjectProgress>>>(
  (ref) {
    final targetsAsync = ref.watch(allDbTargetsProvider);
    final sessionsAsync = ref.watch(allSessionsProvider);
    final service = ref.watch(projectTrackingServiceProvider);

    if (targetsAsync.hasError) {
      return AsyncValue.error(
        targetsAsync.error!,
        targetsAsync.stackTrace ?? StackTrace.current,
      );
    }
    if (sessionsAsync.hasError) {
      return AsyncValue.error(
        sessionsAsync.error!,
        sessionsAsync.stackTrace ?? StackTrace.current,
      );
    }
    if (targetsAsync.isLoading || sessionsAsync.isLoading) {
      return const AsyncValue.loading();
    }

    return AsyncValue.data(
      service.summarize(
        targets: targetsAsync.value ?? const [],
        sessions: sessionsAsync.value ?? const [],
      ),
    );
  },
);
