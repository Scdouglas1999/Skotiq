import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../darkroom_route.dart' show DarkroomRouteScope;
import '../pass_view/darkroom_pass_page.dart';
import 'automation_settings_panel.dart';
import 'night_end_history.dart';
import 'running_build_panel.dart';
import 'waiting_panel.dart';

/// Width from which the automation settings sit beside the activity.
const double _sideBySideWidth = 1080;

/// Width of the automation column when it sits beside the activity.
const double _settingsWidth = 400;

/// The Darkroom's Activity tab: the running build, the builds waiting at the
/// framing check, the night-end history with the integration passes, and the
/// night-end automation settings. `pass=<runId>` in the route (or
/// [passRunId]) opens that pass's view here instead of the lists.
class DarkroomActivityTab extends ConsumerStatefulWidget {
  const DarkroomActivityTab({super.key, this.passRunId});

  /// The pass to show; read from the route when null.
  final String? passRunId;

  @override
  ConsumerState<DarkroomActivityTab> createState() =>
      _DarkroomActivityTabState();
}

class _DarkroomActivityTabState extends ConsumerState<DarkroomActivityTab> {
  @override
  void initState() {
    super.initState();
    // Reading back the saved builds and runs is idempotent; the night-end
    // coordinator normally did it at launch.
    ref.read(nightEndRunnerProvider).start();
  }

  String? _passFromRoute(BuildContext context) {
    final route = DarkroomRouteScope.maybeOf(context);
    if (route != null) return route.passRunId;
    try {
      final pass = GoRouterState.of(context).uri.queryParameters['pass'];
      return pass == null || pass.isEmpty ? null : pass;
    } on Object {
      // Not under a route (a test or an embedding): no pass to show.
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final pass = widget.passRunId ?? _passFromRoute(context);
    if (pass != null) return _PassView(runId: pass);
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _sideBySideWidth;
        const gap = SizedBox(height: SkotiqTokens.spaceLg);
        final activity = [
          const RunningBuildPanel(),
          gap,
          const WaitingPanel(),
          gap,
          const NightEndHistoryPanel(),
          const _Spaced(RecentBuildsPanel()),
          const _Spaced(PassesPanel()),
        ];
        const padding = EdgeInsets.symmetric(
          horizontal: SkotiqTokens.space2xl,
          vertical: SkotiqTokens.spaceXl,
        );
        if (!wide) {
          return ListView(
            key: const ValueKey('darkroom_activity_list'),
            padding: padding,
            children: [
              ...activity.take(4),
              const AutomationSettingsPanel(),
              gap,
              ...activity.skip(4),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ListView(
                key: const ValueKey('darkroom_activity_list'),
                padding: padding.copyWith(right: SkotiqTokens.spaceLg),
                children: activity,
              ),
            ),
            SizedBox(
              width: _settingsWidth,
              child: ListView(
                padding: padding.copyWith(left: 0),
                children: const [AutomationSettingsPanel()],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A panel below the history, spaced from it.
class _Spaced extends StatelessWidget {
  const _Spaced(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: SkotiqTokens.spaceLg),
        child: child,
      );
}

/// One integration pass, live while it runs, inside the Activity tab.
class _PassView extends StatelessWidget {
  const _PassView({required this.runId});

  final String runId;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: SkotiqTokens.space2xl,
            vertical: SkotiqTokens.spaceSm,
          ),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: colors.border)),
          ),
          child: Row(
            children: [
              SkotiqButton(
                key: const ValueKey('darkroom_activity_pass_back'),
                label: 'All activity',
                icon: SkotiqIcons.arrowLeft,
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: () => context.go(darkroomActivityRoute),
              ),
              const SizedBox(width: SkotiqTokens.spaceMd),
              Expanded(
                child: Text(
                  'Integration pass',
                  style: SkotiqTypography.sectionTitle.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(child: DarkroomPassPage(runId: runId)),
      ],
    );
  }
}
