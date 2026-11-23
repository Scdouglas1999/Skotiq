import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import 'command_action_result.dart';

/// The rotate step of slew, center and rotate: turns the connected rotator to
/// [angleDeg] once centering succeeded.
///
/// Completes with null when no rotator is connected. A rotation that was sent
/// to a rotator or backend that has since been replaced succeeds with no
/// message, so the old move is not announced over the new device.
Future<CommandActionResult?> rotateAfterCentering(
  WidgetRef ref,
  double angleDeg,
) async {
  final rotatorState = ref.read(rotatorStateProvider);
  final rotatorId = rotatorState.deviceId;
  if (rotatorState.connectionState != DeviceConnectionState.connected ||
      rotatorId == null) {
    return null;
  }
  try {
    final deviceBackend = ref.read(deviceBackendProvider);
    await deviceBackend.rotatorMoveTo(rotatorId, angleDeg);
    if (!identical(ref.read(deviceBackendProvider), deviceBackend) ||
        ref.read(rotatorStateProvider).deviceId != rotatorId) {
      return CommandActionResult.ok;
    }
    return CommandActionResult.success(
      message: 'Rotating to ${angleDeg.toStringAsFixed(1)}°',
    );
  } catch (e) {
    return CommandActionResult.failure(
        'Rotation failed: ${userFacingError(e)}');
  }
}
