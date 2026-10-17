import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'first_light_flow_dialog.dart';

/// Wraps the imaging screen body and opens the [FirstLightFlowDialog] when the
/// imaging route is reached with `?firstLight=1`.
///
/// ## Why a wrapper widget (and the ownership contract)
///
/// The first-light "wow moment" is launched by sending the user to
/// `/imaging?firstLight=1` (C9 routes here once equipment onboarding finishes).
/// We want the dialog to open exactly once on arrival and never re-trigger on
/// later rebuilds, so the launcher:
///
///   1. Reads the `firstLight` query parameter from [GoRouterState.of].
///   2. On the first post-frame callback after that query is seen (mounted-
///      guarded), opens [FirstLightFlowDialog.show].
///   3. Strips the query by calling `context.go('/imaging')` so a rebuild,
///      back-navigation, or hot reload cannot fire the dialog a second time.
///
/// This is provided as a wrapper widget so that the eventual imaging-screen /
/// router change is minimal. **This component deliberately does NOT edit
/// `imaging_screen.dart` or `app_router.dart`** — to preserve exclusive file
/// ownership, mounting the launcher is the job of the `/imaging` `pageBuilder`,
/// which is owned by C13. The integration contract C13 must honour:
///
/// ```dart
/// // in app_router.dart, the /imaging GoRoute pageBuilder:
/// pageBuilder: (context, state) => CustomTransitionPage(
///   child: const FirstLightQueryLauncher(child: ImagingScreen()),
///   transitionsBuilder: PageTransitions.slideFadeTransition,
///   transitionDuration: const Duration(milliseconds: 300),
/// ),
/// ```
///
/// The launcher is intentionally inert (renders [child] unchanged) unless the
/// `firstLight=1` query is present, so wrapping the imaging screen with it
/// unconditionally is safe.
class FirstLightQueryLauncher extends ConsumerStatefulWidget {
  const FirstLightQueryLauncher({super.key, required this.child});

  /// The imaging screen (or any body) this launcher guards.
  final Widget child;

  /// The query parameter name that triggers the flow.
  static const queryName = 'firstLight';

  /// The value of [queryName] that triggers the flow.
  static const triggerValue = '1';

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
    final goState = GoRouterState.of(context);
    final value =
        goState.uri.queryParameters[FirstLightQueryLauncher.queryName];
    if (value != FirstLightQueryLauncher.triggerValue) return;

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
      if (router.routerDelegate.currentConfiguration.uri.path == '/imaging') {
        router.go('/imaging');
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
