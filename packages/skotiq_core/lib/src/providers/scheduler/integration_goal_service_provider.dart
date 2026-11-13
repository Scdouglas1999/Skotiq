import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../backend_provider.dart';
import '../database_provider.dart';
import '../../backend/remote_host.dart';
import '../../services/scheduler/integration_goal_service.dart';

final integrationGoalServiceProvider = Provider<IntegrationGoalService>((ref) {
  final backend = ref.watch(backendProvider);
  final service = IntegrationGoalService(
    ref.watch(databaseProvider),
    remote: backend.remoteHost?.planning,
  );
  ref.onDispose(() => service.dispose());
  return service;
});
