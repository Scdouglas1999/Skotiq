import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../linked_host.dart';
import '../database_provider.dart';
import '../../services/planning/project_service.dart';
import '../scheduler/integration_goal_service_provider.dart';

final projectServiceProvider = Provider<ProjectService>((ref) {
  final service = ProjectService(
    ref.watch(databaseProvider),
    ref.watch(integrationGoalServiceProvider),
    remote: ref.watch(linkedHostPlanningProvider),
  );
  ref.onDispose(() => service.dispose());
  return service;
});
