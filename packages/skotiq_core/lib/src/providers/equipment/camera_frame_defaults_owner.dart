import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/backend/device_capabilities.dart';
import '../../models/equipment/equipment_models.dart';
import '../capability_provider.dart';
import '../profiles_provider.dart';
import 'camera_state_provider.dart';

/// What the imaging camera takes a frame at when the frame does not name it.
/// Null is a value the profile does not state or a control the camera does
/// not have; the camera keeps its own for it.
typedef CameraFrameDefaults = ({int? gain, int? offset, String? readoutMode});

/// Tells the device layer what the camera [deviceId] takes its frames at
/// when a frame does not name it.
typedef StateCameraFrameDefaults =
    void Function(String deviceId, CameraFrameDefaults defaults);

/// A camera and its frame defaults.
typedef StatedFrameDefaults = ({String deviceId, CameraFrameDefaults defaults});

/// The connected imaging camera and its frame defaults: the active equipment
/// profile's gain and offset for the controls the camera has, and its read
/// mode by the name the camera lists. A DSLR or mirrorless body keeps the ISO
/// it is set to and has no offset. Until the camera's capabilities are known
/// neither gain nor offset is stated. Null with no camera connected.
final cameraFrameDefaultsProvider = Provider<StatedFrameDefaults?>((ref) {
  final camera = ref.watch(
    cameraStateProvider.select(
      (camera) => camera.connectionState == DeviceConnectionState.connected
          ? camera.deviceId
          : null,
    ),
  );
  if (camera == null || camera.isEmpty) return null;
  final profile = ref.watch(activeEquipmentProfileProvider);
  final sensitivity = ref
      .watch(cameraCapabilitiesProvider(camera))
      .valueOrNull
      ?.sensitivity;
  final takesGain = sensitivity is GainSensitivity && sensitivity.hasGain;
  final takesOffset = sensitivity?.hasOffset ?? false;
  return (
    deviceId: camera,
    defaults: (
      gain: takesGain ? profile?.defaultGain : null,
      offset: takesOffset ? profile?.defaultOffset : null,
      readoutMode: profile?.defaultReadoutMode,
    ),
  );
});

/// Keeps the device layer told of the imaging camera's frame defaults.
///
/// Gain, offset and read mode have one owner. Nothing here writes to the
/// camera: each frame is taken at what it names, else at these, whoever
/// asked for it (a capture from the panel, a run's exposures, centering,
/// autofocus, the flat wizard). So a run's centering frame never takes the
/// gain a manual frame left on the camera.
class CameraFrameDefaultsOwner {
  CameraFrameDefaultsOwner({
    required Ref ref,
    required StateCameraFrameDefaults state,
  }) {
    _subscription = ref.listen<StatedFrameDefaults?>(
      cameraFrameDefaultsProvider,
      (_, stated) {
        if (stated != null) state(stated.deviceId, stated.defaults);
      },
      fireImmediately: true,
    );
  }

  late final ProviderSubscription<StatedFrameDefaults?> _subscription;

  void dispose() => _subscription.close();
}
