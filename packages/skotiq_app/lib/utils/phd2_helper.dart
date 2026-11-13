import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/providers.dart';
import 'snackbar_helper.dart';

/// Connects to PHD2 using saved settings.
///
/// This eliminates duplicate PHD2 connection code across screens.
/// All PHD2 connect buttons should use this helper instead of implementing
/// their own async settings lookup and connect logic.
Future<void> connectPhd2(WidgetRef ref, {BuildContext? context}) async {
  try {
    final settings = await ref.read(appSettingsProvider.future);
    await ref.read(phd2ControllerProvider).connect(
          settings.phd2Host,
          settings.phd2Port,
        );
  } catch (e) {
    if (context != null && context.mounted) {
      context.showErrorSnackBar(
          'PHD2 connection failed: ${userFacingError(e)}');
    }
  }
}

/// Disconnects from PHD2.
///
/// Awaited with error handling so a failing teardown surfaces to the user
/// instead of escaping as an unhandled Future. The controller's `disconnect()`
/// runs its authoritative steps (latch the user-disconnect intent, cancel the
/// relaunch backoff, mark the disconnect user-initiated) SYNCHRONOUSLY before
/// its first await, so the auto-relaunch path is already suppressed regardless
/// of how this Future settles.
Future<void> disconnectPhd2(WidgetRef ref, {BuildContext? context}) async {
  try {
    await ref.read(phd2ControllerProvider).disconnect();
  } catch (e) {
    if (context != null && context.mounted) {
      context.showErrorSnackBar(
        'PHD2 disconnect failed: ${userFacingError(e)}',
      );
    }
  }
}
