import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart' show GuiderNotAnsweringException;

import '../router/app_router.dart';
import '../services/move_with_silent_guider.dart';
import '../utils/confirm_dialog.dart';

/// The "move anyway?" question shown on the app's own navigator. False when
/// the operator declines or the process has no window.
Override moveWithSilentGuiderAskOverride() =>
    moveWithSilentGuiderAskProvider.overrideWith((ref) {
      return () async {
        final navigator = ref
            .read(appRouterProvider)
            .routerDelegate
            .navigatorKey
            .currentState;
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
