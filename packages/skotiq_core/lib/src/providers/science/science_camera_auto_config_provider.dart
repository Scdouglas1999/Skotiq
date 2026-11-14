import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../models/equipment/equipment_models.dart';
import '../backend_provider.dart';
import '../equipment/camera_state_provider.dart';
import '../profiles_provider.dart';
import '../../services/science/science_camera_auto_config.dart';

/// Watch this provider once at app startup (see `app.dart`) to activate the
/// sync. Listens only to the camera fields that matter — connection state,
/// identity, and gain — so per-exposure state churn does not re-trigger it.
final scienceCameraAutoConfigProvider = Provider<ScienceCameraAutoConfig>((
  ref,
) {
  final backend = ref.watch(backendProvider);
  final service = ScienceCameraAutoConfig(
    ref,
    backend,
    cameraIsHere: !ref.watch(isRemoteModeProvider),
  );
  ref.onDispose(service.retire);
  ref.listen<(DeviceConnectionState, String?, String?, int?)>(
    cameraStateProvider.select(
      (s) => (s.connectionState, s.deviceName, s.deviceId, s.gain),
    ),
    (_, __) => service.maybeSync(reason: 'camera state changed'),
  );
  ref.listen(activeEquipmentProfileProvider, (_, __) {
    service.maybeSync(reason: 'active profile changed');
  });
  // Initial pass once the provider graph is up.
  Future.microtask(() => service.maybeSync(reason: 'startup'));
  return service;
});
