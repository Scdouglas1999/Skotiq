import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../linked_host.dart';
import '../database_provider.dart';
import '../../services/scheduler/target_constraint_service.dart';

final targetConstraintServiceProvider = Provider<TargetConstraintService>((
  ref,
) {
  final svc = TargetConstraintService(
    ref.watch(databaseProvider),
    remote: ref.watch(linkedHostPlanningProvider),
  );
  ref.onDispose(() => svc.dispose());
  return svc;
});
