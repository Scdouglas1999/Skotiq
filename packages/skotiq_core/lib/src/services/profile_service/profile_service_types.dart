part of '../profile_service.dart';

typedef _BackendAuthority = AsyncScope<SkotiqBackend>;

/// The one writer of equipment profiles and of which one is active and
/// default. [ProfileService] activates, saves, copies and deletes through it,
/// so it never becomes a second, unsynchronized writer.
abstract interface class ProfileWriter {
  Future<int> saveProfile(EquipmentProfileModel profile);

  Future<void> deleteProfile(int profileId);

  Future<void> setActiveProfile(int profileId);

  Future<void> setActiveProfileStrict(int profileId);

  Future<void> setDefaultProfile(int? profileId, {bool makeActive = true});

  Future<int> duplicateProfile(int sourceId, String newName);
}

/// Raised when startup auto-connect finishes activating a profile but one or
/// more of its devices failed to connect. Startup deliberately attempts EVERY
/// configured device (a single offline focuser must not strand the mount and
/// camera) and then aggregates the failures here so the wiring layer can log
/// loudly / surface a non-blocking notification. The profile is already active
/// by the time this throws.
class ProfileAutoConnectException implements Exception {
  final String profileName;

  /// One per device that did not connect: [device] is what a person calls
  /// it ("Focuser (ZWO EAF)"), [deviceId] the id it was connected by.
  final List<({String device, String deviceId, String reason})> failures;

  const ProfileAutoConnectException({
    required this.profileName,
    required this.failures,
  });

  /// "Focuser (ZWO EAF): unplugged", one line per device, for people.
  List<String> get described => [
    for (final failure in failures) '${failure.device}: ${failure.reason}',
  ];

  @override
  String toString() =>
      'ProfileAutoConnectException: ${failures.length} '
      'device${failures.length == 1 ? '' : 's'} failed to '
      'connect for profile "$profileName": '
      '${[for (final f in failures) '${f.device} [${f.deviceId}]: ${f.reason}'].join('; ')}';
}
