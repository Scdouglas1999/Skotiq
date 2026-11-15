import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart' show GuiderNotAnsweringException;

import '../router/app_router.dart';
import '../utils/confirm_dialog.dart';

/// Asks the operator whether a GoTo should go ahead although the guider is
/// not answering and cannot be stopped first. False when they decline or
/// when there is no screen to ask on.
final moveWithSilentGuiderAskProvider = Provider<Future<bool> Function()>((
  ref,
) {
  return () async {
    final navigator =
        ref.read(appRouterProvider).routerDelegate.navigatorKey.currentState;
    final context = navigator?.overlay?.context;
    if (context == null) return false;
    return ConfirmDialog.show(
      context: context,
      title: 'The guider is not answering',
      message: GuiderNotAnsweringException.question,
      confirmLabel: 'Move anyway',
      cancelLabel: 'Do not move',
      isDestructive: true,
    );
  };
});
