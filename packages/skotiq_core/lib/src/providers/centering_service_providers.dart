import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'notification_router_provider.dart' show notificationRouterProvider;
import '../services/centering_service.dart';
import 'host_role.dart';

/// Where this app's centering runs.
final centeringRunnerProvider = Provider<CenteringRunner>((ref) {
  final host = ref.watch(remoteHostProvider);
  return host == null
      ? const NativeCenteringRunner()
      : HostCenteringRunner(host.pointing);
});

final centeringServiceProvider = Provider<CenteringService>((ref) {
  final service = CenteringService(
    ref,
    runner: ref.watch(centeringRunnerProvider),
    notices: () => ref.read(notificationRouterProvider),
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
