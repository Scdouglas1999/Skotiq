import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'database_provider.dart';
import '../services/smart_project_service.dart';
import 'scheduler/integration_goal_service_provider.dart';

/// Riverpod provider for [SmartProjectService].
final smartProjectServiceProvider = Provider<SmartProjectService>((ref) {
  return SmartProjectService(
    database: ref.watch(databaseProvider),
    goals: ref.watch(integrationGoalServiceProvider),
  );
});
