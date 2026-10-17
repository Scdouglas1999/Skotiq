import 'package:skotiq_core/skotiq_core.dart';

import 'driver_error_pretty.dart';

/// Per-device failure surfaced to snackbars / logs.
class ConnectAllFailure {
  final String deviceType;
  final String message;

  const ConnectAllFailure({
    required this.deviceType,
    required this.message,
  });

  factory ConnectAllFailure.fromProgress(DeviceConnectProgress event) {
    final raw =
        event.errorMessage ?? event.error?.toString() ?? 'Connection failed';
    final pretty = PrettyError.format(raw);
    return ConnectAllFailure(
      deviceType: event.deviceType,
      message: pretty.short,
    );
  }

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
