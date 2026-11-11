import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../router/app_routes.dart';
import 'first_light_flow_dialog.dart';

/// Wraps the imaging screen body and opens the [FirstLightFlowDialog] once
/// when Imaging is reached through [AppRoutes.imaging] with `firstLight`
/// (sent when equipment onboarding finishes).
///
/// After the dialog closes the query is stripped, so a rebuild,
/// back-navigation or hot reload cannot open it a second time. Without the
/// query the launcher renders [child] unchanged.
class FirstLightQueryLauncher extends ConsumerStatefulWidget {
  const FirstLightQueryLauncher({super.key, required this.child});

  /// The imaging screen (or any body) this launcher guards.
  final Widget child;

  @override
  ConsumerState<FirstLightQueryLauncher> createState() =>
      _FirstLightQueryLauncherState();
}

class _FirstLightQueryLauncherState
    extends ConsumerState<FirstLightQueryLauncher> {
  /// Latches once the flow has been triggered for this widget instance so a
  /// rebuild (e.g. from the dialog pushing/popping routes) cannot re-open it.
  bool _triggered = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeTrigger();
  }

  void _maybeTrigger() {
    if (_triggered) return;

    // GoRouterState is available because this widget is rendered inside the
    // /imaging route's page (below MaterialApp.router), unlike the top-level
    // EquipmentOnboardingLauncher which sits above it.
    if (!AppRoutes.asksForFirstLight(GoRouterState.of(context).uri)) return;

    // Latch immediately so concurrent dependency changes don't double-fire.
    _triggered = true;

    // Capture the router up-front: stripping the query happens after the
    // dialog closes, by which point this widget's BuildContext may be defunct,
    // so we route through the GoRouter instance directly rather than a stale
    // context.
    final router = GoRouter.of(context);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Open the flow over the current /imaging route. The in-widget `_triggered`
      // latch already prevents a re-open while this instance lives.
      await FirstLightFlowDialog.show(context);

      // Strip the query so a future arrival (back-navigation, deep link reuse,
      // a fresh launcher instance) does not re-trigger the flow. Guarded by
      // the captured router rather than `context`, which may be unmounted.
      final imaging = AppRoute.imaging.path;
      if (router.routerDelegate.currentConfiguration.uri.path == imaging) {
        router.go(imaging);
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
