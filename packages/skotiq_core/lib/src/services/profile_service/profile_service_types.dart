part of '../profile_service.dart';

typedef _BackendAuthority = ({
  BackendNotifier owner,
  SkotiqBackend backend,
});

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

/// Result of validating a profile's devices against discovered devices
class ProfileValidationResult {
  /// Whether all devices in the profile are available
  final bool isValid;

  /// List of device types that are configured in profile but not found
  final List<String> missingDevices;

  /// List of device types that are configured and available
  final List<String> availableDevices;

  /// Map of device type to device ID for devices that are missing
  final Map<String, String> missingDeviceIds;

  const ProfileValidationResult({
    required this.isValid,
    required this.missingDevices,
    required this.availableDevices,
    this.missingDeviceIds = const {},
  });

  /// Create a result indicating all devices are valid
  const ProfileValidationResult.valid({required this.availableDevices})
    : isValid = true,
      missingDevices = const [],
      missingDeviceIds = const {};
}
