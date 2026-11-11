import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'snackbar_helper.dart';

/// Closes the dialog route owning [context] after its backing authority
/// changes.
///
/// Removing the owning route (instead of blindly popping the top route) also
/// works when a child confirmation dialog is currently above it. In that case
/// the child is dismissed as well, leaving the underlying application page in
/// place.
void closeAuthorityBoundDialog(BuildContext context) {
  final navigator = Navigator.of(context);
  final route = ModalRoute.of(context);
  if (route == null) {
    unawaited(navigator.maybePop());
    return;
  }

  final hadChildRoute = !route.isCurrent;
  navigator.removeRoute(route);
  if (hadChildRoute && navigator.canPop()) {
    unawaited(navigator.maybePop());
  }
}

/// State of a dialog whose contents belong to one imaging host.
///
/// The dialog captures the host it was opened under as [host]. If the app
/// links to a different host while the dialog is open, the ids and values on
/// screen no longer mean anything, so the dialog says so with
/// [hostChangedMessage] and closes. Actions use `host.isStale` to drop work
/// that finished after that happened (or after the dialog was dismissed).
mixin HostBoundDialogState<W extends ConsumerStatefulWidget>
    on ConsumerState<W> {
  /// The sentence shown when the host changes under the open dialog, or null
  /// when the dialog closes without one.
  String? get hostChangedMessage;

  /// True when closing loses something the user typed or chose; the notice
  /// is then shown in the warning style.
  bool get hostChangeDiscardsInput => false;

  /// Scopes over the dialog's host, for loads where only the newest may apply
  /// (`hostScopes.beginLatest()`). Every scope from here, [host] included,
  /// stays stale once the host has changed, even if the app later links back
  /// to the same host.
  late final AsyncScopes<SkotiqBackend> hostScopes;
  late final AsyncScope<SkotiqBackend> host;
  bool _hostChanged = false;
  ProviderSubscription<SkotiqBackend>? _hostSubscription;

  @override
  void initState() {
    super.initState();
    hostScopes = ref.backendScopes(alive: () => mounted && !_hostChanged);
    host = hostScopes.begin();
    _hostSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (previous == null ||
            identical(previous, next) ||
            !mounted ||
            _hostChanged) {
          return;
        }
        _hostChanged = true;
        onHostChanged();
      },
    );
  }

  /// Runs once, when the host changes under the open dialog. The default
  /// shows [hostChangedMessage] and closes the dialog.
  @protected
  void onHostChanged() {
    _announceHostChange(
      context,
      hostChangedMessage,
      discardsInput: hostChangeDiscardsInput,
    );
    closeAuthorityBoundDialog(context);
  }

  @override
  void dispose() {
    _hostSubscription?.close();
    super.dispose();
  }
}

void _announceHostChange(
  BuildContext context,
  String? message, {
  required bool discardsInput,
}) {
  if (message == null) return;
  if (discardsInput) {
    context.showWarningSnackBar(message);
  } else {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}
