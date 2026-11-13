import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../backend_provider.dart';
import '../database_provider.dart';
import '../../backend/remote_host.dart';
import '../../services/scheduler/scheduler_queue_service.dart';

final schedulerQueueServiceProvider = Provider<SchedulerQueueService>((ref) {
  final backend = ref.watch(backendProvider);
  return SchedulerQueueService(
    ref.watch(databaseProvider),
    remote: backend.remoteHost?.planning,
  );
});
