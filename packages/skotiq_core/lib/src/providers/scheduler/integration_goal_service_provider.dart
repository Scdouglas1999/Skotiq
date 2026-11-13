import '../linked_host.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database_provider.dart';
import '../../services/scheduler/integration_goal_service.dart';

final integrationGoalServiceProvider = Provider<IntegrationGoalService>((ref) {
  final service = IntegrationGoalService(
    ref.watch(databaseProvider),
    remote: ref.watch(linkedHostPlanningProvider),
  );
  ref.onDispose(() => service.dispose());
  return service;
});
