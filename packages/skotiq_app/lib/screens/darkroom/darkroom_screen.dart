/// The Darkroom: the Targets, Calibration, Edit and Activity tabs under the
/// standard page header.
///
/// The location says which tab is open and what it shows (see
/// [DarkroomRoute]). `/darkroom?tab=edit&master=<id>` or `&recipe=<id>` opens
/// the recipe editor inside the Edit tab, and `/darkroom?tab=activity&pass=`
/// opens a pass inside Activity.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../utils/darkroom_navigation.dart' show darkroomTabLocation;
import 'darkroom_controller.dart';
import 'darkroom_route.dart';
import 'activity/activity_tab.dart';
import 'calibration/calibration_tab.dart';
import 'edit/edit_tab.dart';
import 'targets/darkroom_status_chip.dart';
import 'targets/targets_tab.dart';

part 'darkroom_screen_parts/_landing.dart';

/// The Darkroom screen.
class DarkroomScreen extends ConsumerStatefulWidget {
  /// What the Edit tab or the pass view is scoped to; empty when no master,
  /// recipe or pass is named.
  final DarkroomScope scope;

  /// The parsed location, or null when the screen was built from a scope.
  final DarkroomRoute? route;

  const DarkroomScreen({super.key, required this.scope}) : route = null;

  /// The screen for a parsed `/darkroom` location.
  DarkroomScreen.route(DarkroomRoute this.route, {super.key})
      : scope = route.scope;

  @override
  ConsumerState<DarkroomScreen> createState() => _DarkroomScreenState();
}

class _DarkroomScreenState extends ConsumerState<DarkroomScreen> {
  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    if (ref.watch(isRemoteClientProvider)) {
      // Masters, calibration files and the recipe engine all live on the
      // imaging host, so a remote client has nothing here it could open. Gated
      // on the client role rather than the connection, as Delivery is.
      return _remoteGate(colors);
    }
    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        bottom: false,
        child: _DarkroomTabsView(
          route: widget.route ?? DarkroomRoute.forScope(widget.scope),
        ),
      ),
    );
  }

  Widget _remoteGate(SkotiqColors colors) {
    return Scaffold(
      backgroundColor: colors.background,
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _leave,
          const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
              _leave,
        },
        child: Focus(
          autofocus: true,
          // A published focus node here reads as a disabled button wrapping
          // the whole screen on AT-SPI.
          includeSemantics: false,
          child: SafeArea(
            bottom: false,
            child: Column(
              children: [
                PageHeader(
                  title: 'Darkroom',
                  icon: SkotiqIcons.aperture,
                  context: 'Host-only processing',
                  actions: [
                    Semantics(
                      container: true,
                      button: true,
                      enabled: true,
                      label: 'Back to where the Darkroom was opened from',
                      excludeSemantics: true,
                      onTap: _leave,
                      child: SkotiqButton(
                        label: 'Back',
                        icon: SkotiqIcons.arrowLeft,
                        variant: ButtonVariant.secondary,
                        size: ButtonSize.small,
                        onPressed: _leave,
                      ),
                    ),
                  ],
                ),
                Expanded(
                  child: EmptyState(
                    icon: SkotiqIcons.device,
                    title: 'Open the Darkroom on the imaging host',
                    body: 'Linear masters and the recipe engine that renders '
                        'them live on the imaging computer. Open Skotiq there '
                        'to build masters, adjust, reorder, or export a '
                        'recipe. Remote Darkroom editing is unavailable in '
                        'this release.',
                    action: SkotiqButton(
                      key: const ValueKey('darkroom_remote_gate_back'),
                      label: 'Go back',
                      icon: SkotiqIcons.arrowLeft,
                      variant: ButtonVariant.secondary,
                      size: ButtonSize.small,
                      onPressed: _leave,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Pops a pushed Darkroom; one reached by a deep link goes to the session
  /// history, since every Darkroom tab is gated the same way here.
  void _leave() {
    final router = GoRouter.of(context);
    if (router.canPop()) {
      router.pop();
      return;
    }
    context.go('/analytics?tab=history');
  }
}
