import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'confirm_dialog.dart';

/// Confirm gate for disconnect actions that would cut power to an active
/// camera cooler.
///
/// Most drivers drop the TEC the moment the connection closes, so
/// disconnecting a camera holding −10°C (or mid-warm-up ramp) thermal-shocks
/// the sensor. Every disconnect surface (per-device card, Disconnect All on
/// the equipment screen, Disconnect All in the status-bar menu) routes
/// through this ONE gate so the warning copy and the conditions stay
/// identical.
///
/// Returns true when it is safe to proceed: the camera is not connected, the
/// cooler is idle, or the user explicitly confirmed the abrupt cut.
Future<bool> confirmDisconnectCooledCamera(
  BuildContext context,
  WidgetRef ref,
) async {
  final cam = ref.read(cameraStateProvider);
  final connected = cam.connectionState == DeviceConnectionState.connected;
  if (!connected || (!cam.isCooling && !cam.isWarming)) return true;

  final temp = cam.temperature;
  final tempNote =
      temp != null ? ' (sensor at ${temp.toStringAsFixed(1)}°C)' : '';
  return ConfirmDialog.show(
    context: context,
    title: 'Disconnect cooled camera?',
    message: cam.isWarming
        ? 'The camera is still warming up$tempNote. Disconnecting now cuts '
            'cooler power before the ramp finishes.'
        : 'The camera cooler is still running$tempNote. Disconnecting cuts '
            'cooler power abruptly — use Warm Up first for a gentle ramp '
            'to ambient.',
    confirmLabel: 'Disconnect anyway',
    isDestructive: true,
  );
}

/// What to tell the operator after a Warm up press, or null when there is
/// nothing to add.
String? warmupOutcomeMessage(CameraWarmupOutcome outcome) => switch (outcome) {
      CameraWarmupOutcome.started => 'Gradually warming camera (2°C/min)',
      CameraWarmupOutcome.coolerAlreadyOff =>
        'The cooler is already off; there is nothing to warm.',
      CameraWarmupOutcome.idleCoolerSwitchedOff =>
        'The cooler was doing no work, so it was switched off.',
      CameraWarmupOutcome.canceled => null,
    };
