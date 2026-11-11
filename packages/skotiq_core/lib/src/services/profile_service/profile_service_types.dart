part of '../profile_service.dart';

typedef _BackendAuthority = ({BackendNotifier owner, SkotiqBackend backend});

/// Raised when startup auto-connect finishes activating a profile but one or
/// more of its devices failed to connect. Startup deliberately attempts EVERY
/// configured device (a single offline focuser must not strand the mount and
/// camera) and then aggregates the failures here so the wiring layer can log
/// loudly / surface a non-blocking notification. The profile is already active
/// by the time this throws.
class ProfileAutoConnectException implements Exception {
  final String profileName;
  final List<String> failures;

  const ProfileAutoConnectException({
    required this.profileName,
    required this.failures,
  });

  @override
  String toString() =>
      'ProfileAutoConnectException: ${failures.length} '
      'device${failures.length == 1 ? '' : 's'} failed to '
      'connect for profile "$profileName": ${failures.join('; ')}';
}
