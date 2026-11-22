import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

/// Per-device failure surfaced to snackbars / logs.
class ConnectAllFailure {
  final String deviceType;

  /// The reason, cut to fit a snackbar.
  final String message;

  /// The whole reason, for a surface with room to wrap it.
  final String detail;

  const ConnectAllFailure({
    required this.deviceType,
    required this.message,
    String? detail,
  }) : detail = detail ?? message;

  /// The failed device in the device card's words: the troubleshooter's
  /// headline for the message, with the driver's own text after it in
  /// [detail].
  factory ConnectAllFailure.fromProgress(DeviceConnectProgress event) {
    final raw =
        event.errorMessage ?? event.error?.toString() ?? 'Connection failed';
    final diagnosis = diagnoseConnectionFailure(
      deviceType: _deviceTypeOf(event.deviceType),
      driverType: driverTypeFromDeviceId(event.deviceId) ?? DriverType.native,
      rawError: raw,
    );
    return ConnectAllFailure(
      deviceType: event.deviceType,
      message: diagnosis.headline,
      detail: '${diagnosis.headline}: $raw',
    );
  }

  /// The device a sweep label names; the guide camera is a camera.
  static DeviceType _deviceTypeOf(String label) => label == guideCameraLabel
      ? DeviceType.camera
      : deviceSlots
              .where((slot) => slot.noun == label)
              .map((slot) => slot.type)
              .firstOrNull ??
          DeviceType.camera;

  @override
  String toString() => '$deviceType: $message';
}

/// Builds user-visible connect-all result text (includes first failure cause).
String formatConnectAllSnackBar({
  required int successCount,
  required int failCount,
  required List<ConnectAllFailure> failures,
}) {
  if (successCount > 0 && failCount == 0) {
    return 'Connected $successCount device${successCount > 1 ? 's' : ''}';
  }

  if (successCount > 0 && failCount > 0) {
    final detail = failures.isNotEmpty ? failures.first.toString() : '';
    final suffix = detail.isNotEmpty ? '. First failure: $detail' : '';
    return 'Connected $successCount device${successCount > 1 ? 's' : ''}, '
        '$failCount failed$suffix';
  }

  if (failCount > 0) {
    if (failures.isEmpty) {
      return 'Failed to connect devices. Ensure they are powered on and available.';
    }
    if (failures.length == 1) {
      return 'Failed to connect ${failures.first.deviceType}: '
          '${failures.first.message}';
    }
    final listed =
        failures.map((f) => '${f.deviceType} (${f.message})').join('; ');
    return 'Failed to connect: $listed';
  }

  return 'No devices were connected';
}
