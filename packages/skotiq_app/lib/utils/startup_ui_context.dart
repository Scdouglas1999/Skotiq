import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../router/app_router.dart';

/// Resolves a context below the app's root Navigator for startup launchers.
///
/// Some launchers intentionally wrap `MaterialApp.router`, so their own
/// [BuildContext] cannot find the Navigator or ScaffoldMessenger rendered in
/// their child. Tests and embedded uses may place a launcher inside an app, in
/// which case the fallback context is already valid.
BuildContext? resolveStartupUiContext(WidgetRef ref, BuildContext fallback) {
  if (Navigator.maybeOf(fallback) != null) return fallback;
  final navigatorKey = ref.read(appRouterProvider).routerDelegate.navigatorKey;
  return navigatorKey.currentState?.overlay?.context ??
      navigatorKey.currentContext;
}

/// Resolves the app overlay for launchers rendered above the root Navigator.
OverlayState? resolveStartupOverlay(WidgetRef ref, BuildContext fallback) {
  return Overlay.maybeOf(fallback) ??
      ref
          .read(appRouterProvider)
          .routerDelegate
          .navigatorKey
          .currentState
          ?.overlay;
}
