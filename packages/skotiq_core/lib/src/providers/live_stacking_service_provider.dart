import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'backend_provider.dart';
import '../services/live_stacking_service.dart';

final liveStackingServiceProvider = Provider<LiveStackingService>((ref) {
  final backend = ref.watch(backendProvider);
  return LiveStackingService(ref, backend: backend);
});
