import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'backend_provider.dart';
import 'linked_host.dart';
import '../services/live_stacking_service.dart';

final liveStackingServiceProvider = Provider<LiveStackingService>((ref) {
  ref.watch(backendProvider);
  return LiveStackingService(ref, host: ref.watch(linkedHostLiveStackProvider));
});
