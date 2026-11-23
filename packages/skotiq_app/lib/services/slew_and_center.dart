import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../utils/snackbar_helper.dart';
import '../widgets/centering_dialog.dart';
import 'command_action_result.dart';
import 'mount_command_service.dart';
import 'rotate_after_centering.dart';

/// Why a Slew & center may not start, checked before the mount moves: it
/// needs a connected imaging camera, no centering already under way, and the
/// plate solver the operator chose. Null when it may start.
Future<CommandActionResult?> slewAndCenterRefusal(WidgetRef ref) async {
  final camera = ref.read(cameraStateProvider);
  if (camera.connectionState != DeviceConnectionState.connected) {
    return const CommandActionResult.failure(
      'Connect an imaging camera before using Slew & Center.',
      feedbackType: CommandFeedbackType.warning,
    );
  }
  if (ref.read(centeringServiceProvider).isRunning) {
    return const CommandActionResult.failure(
      'A centering operation is already running.',
      feedbackType: CommandFeedbackType.warning,
    );
  }
  try {
    await ref.read(plateSolveServiceProvider).ensureSolverAvailable();
    return null;
  } on SolverNotAvailableError catch (e) {
    return CommandActionResult.failure(
      e.message,
      feedbackType: CommandFeedbackType.warning,
    );
  } catch (e) {
    return CommandActionResult.failure(
      'Could not check the plate solver: ${userFacingError(e)}',
    );
  }
}

/// Slew & center from a menu: the checks of [slewAndCenterRefusal] before
/// anything moves, the GoTo through [MountCommandService.slewTo] (which asks
/// about a target below the horizon or the site's floor), then the centering
/// dialog on the target.
///
/// Completes with the first centering run's result once that run ends, or
/// null when a check refused, the slew failed, or the dialog closed without
/// a run. The dialog stays open on its result until the operator closes it.
///
/// [isCurrent] is false once the press no longer belongs to the screen that
/// made it; nothing is shown after that. With [sameMountAfterSlew] the slew's
/// answer is dropped when the mount service was replaced while it ran.
/// [beforeDialog] runs between a slew that arrived and the dialog.
Future<CenteringResult?> slewAndCenter(
  WidgetRef ref,
  BuildContext context, {
  required double ra,
  required double dec,
  required String? targetName,
  required String dialogTitle,
  required bool Function() isCurrent,
  bool sameMountAfterSlew = false,
  VoidCallback? beforeDialog,
}) async {
  final refused = await slewAndCenterRefusal(ref);
  if (!isCurrent()) return null;
  if (refused != null) {
    if (context.mounted) context.showCommandActionResult(refused);
    return null;
  }

  final mountService = ref.read(mountCommandServiceProvider);
  final slewed = await mountService.slewTo(
    ra,
    dec,
    showFeedback: false,
    targetName: targetName,
  );
  if (!isCurrent() || !context.mounted) return null;
  if (sameMountAfterSlew &&
      !identical(ref.read(mountCommandServiceProvider), mountService)) {
    return null;
  }
  if (!slewed.isSuccess) {
    context.showCommandActionResult(slewed);
    return null;
  }

  beforeDialog?.call();
  if (!context.mounted) return null;
  return showCenteringDialog(
    context: context,
    targetRa: ra,
    targetDec: dec,
    targetName: dialogTitle,
  );
}

/// Slew, center and rotate: [slewAndCenter], then the rotator turns to
/// [rotation] once centering succeeded.
///
/// A centering that failed skips the rotation and says so with
/// [rotationSkipped]. [rotation] is read after centering; null leaves the
/// rotator alone. [centeredWithoutRotator] is shown when there is no rotator
/// to turn.
Future<void> slewCenterAndRotate(
  WidgetRef ref,
  BuildContext context, {
  required double ra,
  required double dec,
  required String? targetName,
  required String dialogTitle,
  required bool Function() isCurrent,
  required double? Function() rotation,
  required String Function(CenteringResult failed) rotationSkipped,
  String? centeredWithoutRotator,
  bool sameMountAfterSlew = false,
  VoidCallback? beforeDialog,
}) async {
  final centered = await slewAndCenter(
    ref,
    context,
    ra: ra,
    dec: dec,
    targetName: targetName,
    dialogTitle: dialogTitle,
    isCurrent: isCurrent,
    sameMountAfterSlew: sameMountAfterSlew,
    beforeDialog: beforeDialog,
  );
  if (!isCurrent() || !context.mounted || centered == null) return;
  if (!centered.success) {
    context.showWarningSnackBar(rotationSkipped(centered));
    return;
  }

  final angle = rotation();
  if (angle == null) return;
  final rotated = await rotateAfterCentering(ref, angle);
  if (!isCurrent() || !context.mounted) return;
  if (rotated != null) {
    context.showCommandActionResult(rotated);
  } else if (centeredWithoutRotator != null) {
    context.showInfoSnackBar(centeredWithoutRotator);
  }
}

/// Slew & center without the dialog, as Tonight's Go to runs it: the
/// centering run makes the GoTo itself, so its altitude question
/// ([MountCommandService.confirmGoToAltitude]) is asked here first.
///
/// Completes with `refused` when the operator said no or the site could not
/// be read, else with the run's result (null when the run did not start).
Future<({CommandActionResult? refused, CenteringResult? result})>
    centerWithoutDialog(
  WidgetRef ref, {
  required double ra,
  required double dec,
}) async {
  final refused =
      await ref.read(mountCommandServiceProvider).confirmGoToAltitude(ra, dec);
  if (refused != null) return (refused: refused, result: null);
  final result = await ref.read(centeringRunProvider).center(
        raHours: ra,
        decDegrees: dec,
      );
  return (refused: null, result: result);
}
