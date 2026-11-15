import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/equipment/equipment_models.dart';
import '../profiles_provider.dart';
import 'camera_state_provider.dart';

/// Tells the device layer which read mode the imaging camera is stated to
/// take its frames in.
typedef StateCameraReadMode = void Function(String deviceId, String? mode);

/// Keeps the device layer told of the imaging camera's read mode: the active
/// equipment profile's default, by the name the camera lists.
///
/// The read mode has one owner. Nothing here writes to the camera: the
/// device layer puts the camera in the stated mode when a frame is about to
/// be taken and the camera is in another, whoever asked for the frame (a
/// capture from the panel, a run, the flat wizard, autofocus). An exposure
/// step may name another mode for its own frames. A profile that states none
/// leaves the camera in the mode it is in.
class CameraReadModeOwner {
  CameraReadModeOwner({required Ref ref, required StateCameraReadMode state})
    : _ref = ref,
      _state = state {
    _subscriptions = [
      _ref.listen(
        activeEquipmentProfileProvider.select((p) => p?.defaultReadoutMode),
        (_, _) => _tell(),
      ),
      _ref.listen(
        cameraStateProvider.select(
          (camera) => (camera.connectionState, camera.deviceId),
        ),
        (_, _) => _tell(),
        fireImmediately: true,
      ),
    ];
  }

  final Ref _ref;
  final StateCameraReadMode _state;
  late final List<ProviderSubscription<Object?>> _subscriptions;

  void _tell() {
    final camera = _ref.read(cameraStateProvider);
    final deviceId = camera.deviceId;
    if (deviceId == null ||
        camera.connectionState != DeviceConnectionState.connected) {
      return;
    }
    _state(deviceId, _ref.read(activeEquipmentProfileProvider)?.defaultReadoutMode);
  }

  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.close();
    }
  }
}
