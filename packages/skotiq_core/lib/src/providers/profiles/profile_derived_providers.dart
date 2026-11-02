part of '../profiles_provider.dart';

/// Provider for watching just the active profile (convenience)
final activeEquipmentProfileProvider = Provider<EquipmentProfileModel?>((ref) {
  final state = ref.watch(equipmentProfilesProvider);
  return state.valueOrNull?.activeProfile;
});

/// Which kind of guider the active profile guides with, so a surface offers
/// only the actions that apply to it.
enum ProfileGuiderKind {
  /// The profile names no guider.
  none,

  /// PHD2, which Skotiq starts and connects over its socket.
  phd2,

  /// A guider Skotiq connects as a device: the built-in guider or a driver.
  device,
}

/// The active profile's guider: its kind, id and the guide camera it uses.
class ProfileGuider {
  const ProfileGuider({required this.kind, this.guiderId, this.guideCameraId});

  final ProfileGuiderKind kind;
  final String? guiderId;
  final String? guideCameraId;

  /// Without an active profile nothing says which guider the rig uses, so
  /// PHD2, the guider Skotiq has always offered, is assumed.
  static ProfileGuider of(EquipmentProfileModel? profile) {
    if (profile == null) {
      return const ProfileGuider(kind: ProfileGuiderKind.phd2);
    }
    final id = profile.guiderId?.trim();
    if (id == null || id.isEmpty) {
      return const ProfileGuider(kind: ProfileGuiderKind.none);
    }
    final camera = profile.guideCameraId?.trim();
    return ProfileGuider(
      kind: isPhd2DeviceId(id)
          ? ProfileGuiderKind.phd2
          : ProfileGuiderKind.device,
      guiderId: id,
      guideCameraId: camera == null || camera.isEmpty ? null : camera,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ProfileGuider &&
      other.kind == kind &&
      other.guiderId == guiderId &&
      other.guideCameraId == guideCameraId;

  @override
  int get hashCode => Object.hash(kind, guiderId, guideCameraId);
}

/// The active profile's guider (see [ProfileGuider]).
final profileGuiderProvider = Provider<ProfileGuider>(
  (ref) => ProfileGuider.of(ref.watch(activeEquipmentProfileProvider)),
);

/// Provider for watching just the profile list (convenience)
final equipmentProfileListProvider = Provider<List<EquipmentProfileModel>>((
  ref,
) {
  final state = ref.watch(equipmentProfilesProvider);
  return state.valueOrNull?.profiles ?? [];
});

// Optical configuration provider

/// Provider that computes optical configuration from the active profile and
/// connected camera capabilities.
///
/// This combines:
/// - Telescope focal length and aperture from the active profile
/// - Camera sensor dimensions and pixel size from camera capabilities
///
/// Returns null if no profile is active or required data is missing.
final opticalConfigProvider = Provider<OpticalConfig?>((ref) {
  final profile = ref.watch(activeEquipmentProfileProvider);
  if (profile == null) return null;

  // Get effective focal length - prefer profile focalLength, fall back to telescope
  final effectiveFocalLength = profile.focalLength > 0
      ? profile.focalLength
      : (profile.telescopeFocalLength ?? 0);
  final effectiveAperture = profile.aperture > 0
      ? profile.aperture
      : (profile.telescopeAperture ?? 0);

  // Try to get camera capabilities if camera is connected
  final cameraState = ref.watch(cameraStateProvider);
  int? sensorWidth;
  int? sensorHeight;
  double? pixelSize;

  if (cameraState.deviceId != null &&
      cameraState.connectionState == DeviceConnectionState.connected) {
    // Watch camera capabilities for the connected camera
    final capabilitiesAsync = ref.watch(
      cameraCapabilitiesProvider(cameraState.deviceId!),
    );
    final CameraCapabilities? capabilities = capabilitiesAsync.valueOrNull;

    if (capabilities != null) {
      sensorWidth = capabilities.maxWidth;
      sensorHeight = capabilities.maxHeight;
      final px = capabilities.pixelSizeX;
      final py = capabilities.pixelSizeY;
      if (px != null && px > 0 && py != null && py > 0) {
        // OpticalConfig currently stores a scalar pixel size; use the mean of
        // axis-specific values to avoid assuming perfectly square pixels.
        pixelSize = (px + py) / 2.0;
      } else if (px != null && px > 0) {
        pixelSize = px;
      } else if (py != null && py > 0) {
        pixelSize = py;
      }
    }
  }

  return OpticalConfig(
    telescopeName: profile.telescopeName,
    focalLength: effectiveFocalLength > 0 ? effectiveFocalLength : null,
    aperture: effectiveAperture > 0 ? effectiveAperture : null,
    focalRatio: profile.focalRatio,
    cameraName: profile.cameraName ?? cameraState.deviceName,
    sensorWidth: sensorWidth,
    sensorHeight: sensorHeight,
    pixelSize: pixelSize,
  );
});

// Profile filters provider

/// Provider that returns the filter names from the active profile.
///
/// Returns an empty list if no profile is active or no filters are configured.
final profileFiltersProvider = Provider<List<String>>((ref) {
  final profile = ref.watch(activeEquipmentProfileProvider);
  if (profile == null) return [];
  return profile.filterNames;
});

// Sorted profiles provider

/// Provider that returns all profiles sorted by sortOrder field.
///
/// Profiles with lower sortOrder values appear first.
/// Profiles with the same sortOrder are sorted by name alphabetically.
final sortedProfilesProvider = Provider<List<EquipmentProfileModel>>((ref) {
  final profiles = ref.watch(equipmentProfileListProvider);
  final sorted = List<EquipmentProfileModel>.from(profiles);
  sorted.sort((a, b) {
    final orderCompare = a.sortOrder.compareTo(b.sortOrder);
    if (orderCompare != 0) return orderCompare;
    return a.name.compareTo(b.name);
  });
  return sorted;
});
