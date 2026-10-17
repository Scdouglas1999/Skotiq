import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'snackbar_helper.dart';

/// Strip Dart exception-type wrappers from user-facing PHD2 failures. Native
/// details remain in application logs; snackbars should present the actionable
/// message once, without `Bad state:` / `Exception:` implementation noise.
String phd2FailureMessage(Object error) {
  var message = error.toString().trim();
  for (final prefix in const [
    'Bad state: ',
    'StateError: ',
    'Exception: ',
  ]) {
    if (message.startsWith(prefix)) {
      message = message.substring(prefix.length).trim();
      break;
    }
  }
  return message;
}

/// Connects to PHD2 using saved settings.
///
/// This eliminates duplicate PHD2 connection code across screens.
/// All PHD2 connect buttons should use this helper instead of implementing
/// their own async settings lookup and connect logic.
///
/// [ref] - The WidgetRef for provider access
/// [context] - Optional BuildContext for error snackbars
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
          'PHD2 connection failed: ${phd2FailureMessage(e)}');
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
///
/// [ref] - The WidgetRef for provider access
/// [context] - Optional BuildContext for error snackbars
Future<void> disconnectPhd2(WidgetRef ref, {BuildContext? context}) async {
  try {
    await ref.read(phd2ControllerProvider).disconnect();
  } catch (e) {
    if (context != null && context.mounted) {
      context.showErrorSnackBar(
        'PHD2 disconnect failed: ${phd2FailureMessage(e)}',
      );
    }
  }
}
