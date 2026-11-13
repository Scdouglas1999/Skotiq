import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../backend_provider.dart';
import '../database_provider.dart';
import '../../backend/remote_host.dart';
import '../../services/planning/project_service.dart';
import '../scheduler/integration_goal_service_provider.dart';

final projectServiceProvider = Provider<ProjectService>((ref) {
  final backend = ref.watch(backendProvider);
  final service = ProjectService(
    ref.watch(databaseProvider),
    ref.watch(integrationGoalServiceProvider),
    remote: backend.remoteHost?.planning,
  );
  ref.onDispose(() => service.dispose());
  return service;
});
