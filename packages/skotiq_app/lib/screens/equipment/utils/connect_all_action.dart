import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../localization/skotiq_localizations.dart';
import '../../../utils/snackbar_helper.dart';
import 'connect_all_summary.dart';

/// Connects every device the active profile names, reporting progress into
/// [deviceConnectionProgressProvider] and the outcome as a snackbar.
///
/// Lives here rather than inside the Equipment screen because the command
/// palette invokes the same operation. A second implementation of "connect
/// the rig" is a second thing that can disagree with the first about which
/// device slots the sweep covers — and the slot list below is exactly the bug
/// this function's own comment records.
Future<void> runConnectAllForProfile(
  BuildContext context,
  WidgetRef ref,
  EquipmentProfileModel profile,
) async {
  final deviceService = ref.read(deviceServiceProvider);
  final discoveryNotifier = ref.read(unifiedDiscoveryProvider.notifier);
  final progressNotifier = ref.read(deviceConnectionProgressProvider.notifier);

  // Count how many devices we need to connect. Must list every slot the
  // sweep itself dispatches (see DeviceService.connectAllFromProfile),
  // otherwise a profile holding only a safety monitor and a power switch is
  // turned away as "no devices configured" and then connects nothing.
  final deviceIds = [
    profile.cameraId,
    profile.mountId,
    profile.focuserId,
    profile.filterWheelId,
    profile.guiderId,
    profile.rotatorId,
    profile.domeId,
    profile.weatherId,
    profile.safetyMonitorId,
    profile.switchId,
    profile.coverCalibratorId,
  ].where((id) => id != null && id.isNotEmpty).toList();

  if (deviceIds.isEmpty) {
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
  // The connect path uses the profile's persisted device ids and does not
  // depend on a fresh scan; startup discovery already populated
  // the "Available Devices" sidebar, and device topology rarely changes
  // mid-session. So refresh the sidebar in the background with a long
  // freshness window rather than blocking the connect on a redundant
  // rescan — the user clicked "Connect all", not "Scan". (Without the long
  // maxAge the default 30s window forces a full rescan every time the user
  // spends more than half a minute setting up before connecting.)
  unawaited(
    discoveryNotifier.discoverIfNeeded(maxAge: const Duration(minutes: 10)),
  );

  // Parallel connect with per-device progress. We push each
  // event into [deviceConnectionProgressProvider] so the per-device
  // chips can render live status, and we tally counts locally for the
  // post-sweep snackbar summary.
  progressNotifier.startSweep();

  int successCount = 0;
  int failCount = 0;
  final List<ConnectAllFailure> failures = [];

  try {
    await for (final event in deviceService.connectAllFromProfile(profile)) {
      progressNotifier.record(event);
      if (event.status == DeviceConnectProgressStatus.connected) {
        successCount++;
      } else if (event.status == DeviceConnectProgressStatus.failed) {
        failCount++;
        final failure = ConnectAllFailure.fromProgress(event);
        failures.add(failure);
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
    }
  } finally {
    progressNotifier.endSweep();
  }

  // NOTHING ELSE IS CONNECTED HERE. "Connect All" sits under the profile
  // card and means "connect this profile's devices" — the sweep above, which
  // already includes the profile's safety monitor and switch.
  //
  // Reaching past the profile — e.g. to the discovery cache's first safety
  // monitor — makes two identical presses connect different rigs, and leaves
  // a device the header counts that the profile does not, so it vanishes on
  // the next launch. A device that is not in the profile is assigned in
  // Discovery, deliberately, once.

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
