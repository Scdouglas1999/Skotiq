import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/backend/fits_header.dart';
import '../models/equipment/equipment_models.dart';
import '../providers/equipment_provider.dart';
import '../providers/profiles_provider.dart';
import '../models/equipment_profile_model.dart';
import '../providers/settings_provider.dart';
import 'logging_service.dart';
import '../settings/app_settings_state.g.dart';

/// Who and what a saved frame's header names: the observer, the site and the
/// optics, from app settings and the active equipment profile.
///
/// A sequence run is seeded with this and a manual capture is saved with it,
/// so the two write the same OBSERVER, SITE*, TELESCOP, FOCALLEN, APTDIA and
/// INSTRUME. A value that is not configured is null and its card is left out.
class FrameIdentity {
  final String? observerName;

  /// Degrees. Both null until an observing site is set.
  final double? siteLatitude;
  final double? siteLongitude;

  /// Meters. Null at 0, which is also what an elevation never entered reads.
  final double? siteElevationM;

  /// The profile's camera label, e.g. "ZWO ASI2600MM Pro".
  final String? cameraName;
  final String? telescopeName;
  final double? focalLengthMm;
  final double? apertureMm;

  const FrameIdentity({
    this.observerName,
    this.siteLatitude,
    this.siteLongitude,
    this.siteElevationM,
    this.cameraName,
    this.telescopeName,
    this.focalLengthMm,
    this.apertureMm,
  });

  factory FrameIdentity.of(
    AppSettingsState? settings,
    EquipmentProfileModel? profile,
  ) {
    String? text(String? value) {
      final trimmed = value?.trim();
      return trimmed == null || trimmed.isEmpty ? null : trimmed;
    }

    // The dedicated telescope fields first, then the generic optics fields a
    // profile built through them carries; 0 means not configured.
    double? firstPositive(double? preferred, double? fallback) {
      if (preferred != null && preferred > 0) return preferred;
      if (fallback != null && fallback > 0) return fallback;
      return null;
    }

    final hasSite = settings?.hasObserverLocation ?? false;
    return FrameIdentity(
      observerName: text(settings?.observerName),
      siteLatitude: hasSite ? settings!.latitude : null,
      siteLongitude: hasSite ? settings!.longitude : null,
      siteElevationM: (settings != null && settings.elevation > 0)
          ? settings.elevation
          : null,
      cameraName: text(profile?.cameraName),
      telescopeName: text(profile?.telescopeName),
      focalLengthMm: firstPositive(
        profile?.telescopeFocalLength,
        profile?.focalLength,
      ),
      apertureMm: firstPositive(profile?.telescopeAperture, profile?.aperture),
    );
  }

  factory FrameIdentity.read(Ref ref) => FrameIdentity.of(
    ref.read(appSettingsProvider).valueOrNull,
    ref.read(activeEquipmentProfileProvider),
  );

  /// [cameraName] as the executor takes it: make is the first word, model
  /// the rest; one word is a model alone.
  (String? make, String? model) get cameraMakeAndModel {
    final name = cameraName;
    if (name == null) return (null, null);
    final space = name.indexOf(' ');
    if (space <= 0) return (null, name);
    return (name.substring(0, space).trim(), name.substring(space + 1).trim());
  }
}

/// The header facts of a manual capture: what was commanded, plus the
/// identity and the connected devices of the rig a sequence run would be
/// given. The host reads the devices when it saves the frame.
///
/// Waits for the equipment profiles to load, so the first capture after
/// start-up still names the optics. Profiles that fail to load leave the
/// optics and camera-name cards out; they never cost the frame.
Future<FitsWriteHeader> manualFrameHeader(
  Ref ref, {
  String? objectName,
  required double exposureTime,
  required DateTime startedAtUtc,
  required String frameType,
  String? filter,
  int? gain,
  int? offset,
  int? binX,
  int? binY,
}) async {
  // Everything is read from [ref] before the wait: a host switch while the
  // profiles load retires [ref], and the caller checks for that afterwards.
  final settings = ref.read(appSettingsProvider).valueOrNull;
  final logger = ref.read(loggingServiceProvider);
  String? connectedId(DeviceSlotState<dynamic> slot) =>
      slot.connectionState == DeviceConnectionState.connected
      ? slot.deviceId
      : null;
  final mountId = connectedId(ref.read(mountStateProvider));
  final focuserId = connectedId(ref.read(focuserStateProvider));
  final filterWheelId = connectedId(ref.read(filterWheelStateProvider));
  final rotatorId = connectedId(ref.read(rotatorStateProvider));
  final profiles = ref.read(equipmentProfilesProvider.future);

  EquipmentProfileModel? profile;
  try {
    profile = (await profiles).activeProfile;
  } on Object catch (e) {
    logger.warning(
      'The equipment profiles did not load ($e); the frame is saved '
      'without TELESCOP, FOCALLEN, APTDIA and the profile camera name',
      source: 'FrameIdentity',
    );
  }
  final identity = FrameIdentity.of(settings, profile);
  return FitsWriteHeader(
    objectName: objectName,
    exposureTime: exposureTime,
    captureTimestamp: startedAtUtc.toUtc().toIso8601String(),
    frameType: frameType,
    filter: filter,
    gain: gain,
    offset: offset,
    binX: binX,
    binY: binY,
    telescope: identity.telescopeName,
    instrument: identity.cameraName,
    observer: identity.observerName,
    focalLength: identity.focalLengthMm,
    aperture: identity.apertureMm,
    siteLatitude: identity.siteLatitude,
    siteLongitude: identity.siteLongitude,
    siteElevation: identity.siteElevationM,
    mountId: mountId,
    focuserId: focuserId,
    filterWheelId: filterWheelId,
    rotatorId: rotatorId,
  );
}
