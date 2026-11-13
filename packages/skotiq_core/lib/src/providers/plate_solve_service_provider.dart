import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'backend_provider.dart';
import '../services/plate_solve_service.dart';

final plateSolveServiceProvider = Provider<PlateSolveService>((ref) {
  ref.watch(backendProvider);
  final service = PlateSolveService(ref);
  ref.onDispose(service.retire);
  return service;
});
