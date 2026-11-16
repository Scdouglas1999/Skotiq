import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/centering_service.dart';
import 'host_role.dart';

/// Where this app's centering runs.
final centeringRunnerProvider = Provider<CenteringRunner>((ref) {
  final host = ref.watch(remoteHostProvider);
  return host == null
      ? const NativeCenteringRunner()
      : HostCenteringRunner(host);
});

final centeringServiceProvider = Provider<CenteringService>((ref) {
  final service = CenteringService(
    ref,
    runner: ref.watch(centeringRunnerProvider),
  );
  ref.onDispose(service.retire);
  return service;
});

final centeringStatusProvider = StateProvider<CenteringStatus>((ref) {
  return CenteringStatus.idle();
});

final lastCenteringResultProvider = StateProvider<CenteringResult?>(
  (ref) => null,
);
