import 'dart:async';

import 'package:flutter/material.dart';

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
