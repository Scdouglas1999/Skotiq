import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../localization/skotiq_localizations.dart';
import '../../../utils/snackbar_helper.dart';
import 'connect_all_summary.dart';

/// Connects every device [profile] names and reports the outcome as a
/// snackbar. The sweep itself is [DeviceService.connectProfile]; this is the
/// one place the app starts it from a button.
Future<void> runConnectAllForProfile(
  BuildContext context,
  WidgetRef ref,
  EquipmentProfileModel profile,
) async {
  final deviceService = ref.read(deviceServiceProvider);
  final discoveryNotifier = ref.read(unifiedDiscoveryProvider.notifier);

  if (!profile.hasAssignedDevices) {
    if (context.mounted) {
      context.showWarningSnackBar(
        context.l10n.text('equipmentNoDevicesConfigured'),
      );
    }
    return;
  }

  if (context.mounted) {
    context.showInfoSnackBar('Connecting devices...');
  }
  // Connect uses the profile's saved device ids and does not need a fresh
  // scan, so the device list is refreshed in the background with a long
  // freshness window instead of holding the connect behind a rescan.
  unawaited(
    discoveryNotifier.discoverIfNeeded(maxAge: const Duration(minutes: 10)),
  );

  // Only the profile's devices are connected here. A device that is not in
  // the profile is assigned in Discovery, once, on purpose; reaching past the
  // profile would make two identical presses connect different rigs.
  final sweep = await deviceService.connectProfile(profile);
  final successCount = sweep.connected;
  final failCount = sweep.failures.length;
  final failures = [
    for (final event in sweep.failures) ConnectAllFailure.fromProgress(event),
  ];
  for (final event in sweep.failures) {
    ref.read(loggingServiceProvider).warning(
      'Connect All failed for ${event.deviceType} (${event.deviceId}): '
      '${event.errorMessage ?? event.error}',
      source: 'EquipmentScreen',
      fields: {
        'deviceType': event.deviceType,
        'deviceId': event.deviceId,
        if (event.error != null) 'error': event.error.toString(),
      },
    );
  }

  if (!context.mounted) return;

  final message = formatConnectAllSnackBar(
    successCount: successCount,
    failCount: failCount,
    failures: failures,
  );
  if (successCount > 0 && failCount == 0) {
    context.showSuccessSnackBar(message);
  } else if (successCount > 0 && failCount > 0) {
    context.showWarningSnackBar(message);
  } else if (failCount > 0) {
    context.showErrorSnackBar(message);
  }
}
