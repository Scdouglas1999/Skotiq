part of '../profile_service.dart';

typedef _BackendAuthority = AsyncScope<SkotiqBackend>;

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
