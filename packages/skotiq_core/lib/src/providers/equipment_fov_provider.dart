import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../models/equipment/equipment_models.dart';
import '../models/optical_config.dart';
import 'equipment/rotator_state_provider.dart';
import 'profiles_provider.dart';

/// Telescope description for the planetarium FOV overlay, derived from the
/// active profile's optical configuration.
///
/// Returns null when the rig's focal length is unknown — a box drawn from a
/// guessed focal length would be a plausible-looking lie about how much sky the
/// scope covers.
TelescopeSpecs? telescopeSpecsFromOpticalConfig(OpticalConfig? config) {
  final focalLength = config?.focalLength;
  if (config == null || focalLength == null || focalLength <= 0) return null;
  return TelescopeSpecs(
    name: config.telescopeName ?? 'Telescope',
    focalLengthMm: focalLength,
    apertureMm: config.aperture ?? 0,
  );
}

/// Camera sensor description for the planetarium FOV overlay, derived from the
/// active profile's optical configuration.
///
/// Sensor dimensions come from the *connected* camera's capabilities (see
/// [opticalConfigProvider]), so this returns null whenever no camera is
/// connected or it did not report a usable geometry. Callers must treat null as
/// "the sensor is unknown" and draw nothing rather than substituting a typical
/// sensor: the whole point of the overlay is to show the field this rig
/// actually covers.
CameraSensorSpecs? cameraSensorSpecsFromOpticalConfig(OpticalConfig? config) {
  if (config == null) return null;
  final pixelSize = config.pixelSize;
  final pixelsX = config.sensorWidth;
  final pixelsY = config.sensorHeight;
  if (pixelSize == null || pixelSize <= 0) return null;
  if (pixelsX == null || pixelsX <= 0) return null;
  if (pixelsY == null || pixelsY <= 0) return null;
  return CameraSensorSpecs(
    name: config.cameraName ?? 'Camera',
    widthMm: pixelsX * pixelSize / 1000.0,
    heightMm: pixelsY * pixelSize / 1000.0,
    pixelsX: pixelsX,
    pixelsY: pixelsY,
    pixelSizeMicrons: pixelSize,
  );
}

/// Binds the connected rig to the planetarium's FOV overlay.
///
/// The planetarium package does not depend on skotiq_core (the dependency
/// runs the other way), so its [equipmentFOVProvider] cannot subscribe to the
/// profile/equipment providers itself. Watch this once high in a screen that
/// shows the overlay and it keeps pushing.
///
///  * [opticalConfigProvider] → telescope + camera specs. An unknown slot
///    resolves to null, which makes `EquipmentFOVState.fov` null and the
///    overlay painter draw nothing rather than a fabricated box.
///  * [rotatorStateProvider] → the live mechanical angle. With no rotator
///    connected the rotation stays whatever the user last dialled in (framing
///    assistant slider / rotation handle).
///
/// Writes are deferred to a microtask because Riverpod forbids mutating another
/// provider while this one is initialising.
final equipmentFovBindingProvider = Provider<void>((ref) {
  var disposed = false;
  ref.onDispose(() => disposed = true);

  void applyOptics(OpticalConfig? config) {
    if (disposed) return;
    ref
        .read(equipmentFOVProvider.notifier)
        .setRig(
          telescope: telescopeSpecsFromOpticalConfig(config),
          camera: cameraSensorSpecsFromOpticalConfig(config),
        );
  }

  void applyRotator(RotatorState rotator) {
    if (disposed) return;
    final position = rotator.position;
    if (rotator.connectionState != DeviceConnectionState.connected ||
        position == null) {
      return;
    }
    ref.read(equipmentFOVProvider.notifier).setRotation(position);
  }

  ref.listen<OpticalConfig?>(opticalConfigProvider, (_, next) {
    Future.microtask(() => applyOptics(next));
  });
  ref.listen<RotatorState>(rotatorStateProvider, (_, next) {
    Future.microtask(() => applyRotator(next));
  });

  // Seed from the current state so the overlay is correct on the first frame
  // after the hosting screen mounts, not only after the next equipment change.
  Future.microtask(() {
    if (disposed) return;
    applyOptics(ref.read(opticalConfigProvider));
    applyRotator(ref.read(rotatorStateProvider));
  });
});
