import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../backend_provider.dart';
import '../database_provider.dart';
import '../../backend/remote_host.dart';
import '../../services/scheduler/target_constraint_service.dart';

final targetConstraintServiceProvider = Provider<TargetConstraintService>((
  ref,
) {
  final backend = ref.watch(backendProvider);
  final svc = TargetConstraintService(
    ref.watch(databaseProvider),
    remote: backend.remoteHost?.planning,
  );
  ref.onDispose(() => svc.dispose());
  return svc;
});
