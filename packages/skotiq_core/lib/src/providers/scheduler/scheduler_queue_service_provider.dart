import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../linked_host.dart';
import '../database_provider.dart';
import '../../services/scheduler/scheduler_queue_service.dart';

final schedulerQueueServiceProvider = Provider<SchedulerQueueService>((ref) {
  return SchedulerQueueService(
    ref.watch(databaseProvider),
    remote: ref.watch(linkedHostPlanningProvider),
  );
});
