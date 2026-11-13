import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'backend_provider.dart';
import '../services/centering_service.dart';

final centeringServiceProvider = Provider<CenteringService>((ref) {
  final backend = ref.watch(deviceBackendProvider);
  final service = CenteringService(
    ref,
    backend: backend,
    slewPollInterval: ref.watch(centeringSlewPollIntervalProvider),
    maxSlewPollTicks: ref.watch(centeringSlewMaxPollTicksProvider),
  );
  ref.onDispose(service.retire);
  return service;
});

/// Timing seams used by deterministic centering lifecycle tests.
final centeringSlewPollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(milliseconds: 500),
);

final centeringSlewMaxPollTicksProvider = Provider<int>((ref) => 120);

final centeringStatusProvider = StateProvider<CenteringStatus>((ref) {
  return CenteringStatus.idle();
});

final lastCenteringResultProvider = StateProvider<CenteringResult?>(
  (ref) => null,
);
