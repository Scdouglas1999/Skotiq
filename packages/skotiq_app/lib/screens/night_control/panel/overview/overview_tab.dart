// The Overview tab (Tonight.dc.html): the last frame, the session, the
// equipment, the conditions and the log. Before a run "Before you start"
// takes the place of the last frame and the session
// (TonightReady.dc.html).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart' show weatherSafetyProvider;

import '../../data/plan/night_run_phase_provider.dart';
import '../../data/session/before_you_start_provider.dart';
import '../../data/session/conditions_provider.dart';
import '../../data/session/equipment_summary_provider.dart';
import '../../data/session/last_frame_metrics_provider.dart';
import '../../data/session/night_log_provider.dart';
import '../../data/session/session_stats_provider.dart';
import '../../night_control_contracts.dart';
import '../panel_ops.dart';
import '../panel_widgets.dart';
import 'overview_sections.dart';

/// Whether [phase] comes before tonight's run, when "Before you start"
/// replaces the frame and session blocks.
bool nightPanelBeforeRun(NightRunPhase phase) => switch (phase) {
      NightRunPhase.notSetUp ||
      NightRunPhase.ready ||
      NightRunPhase.armed =>
        true,
      NightRunPhase.running ||
      NightRunPhase.pausedByUser ||
      NightRunPhase.pausedForAction ||
      NightRunPhase.stopping ||
      NightRunPhase.finished =>
        false,
    };

class NightOverviewTab extends ConsumerWidget {
  const NightOverviewTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final beforeRun = nightPanelBeforeRun(ref.watch(nightRunPhaseProvider));
    return NightPanelBody(
      fill: NightLogSection(entries: ref.watch(nightLogProvider)),
      children: <Widget>[
        if (beforeRun)
          NightChecklistSection(
            items: ref.watch(nightBeforeYouStartProvider),
            onAction: (item) => _runChecklistAction(context, ref, item),
          )
        else ...<Widget>[
          NightLastFrameSection(frame: ref.watch(nightLastFrameProvider)),
          NightSessionSection(session: ref.watch(nightSessionStatsProvider)),
        ],
        NightEquipmentSection(rows: ref.watch(nightEquipmentProvider)),
        NightConditionsSection(
          conditions: ref.watch(nightConditionsProvider),
          onSkyClear: () => ref.read(weatherSafetyProvider.notifier).snooze(
                nightSkyClearOverride,
                reason: 'Operator on Tonight: the sky is clear',
              ),
          onEndOverride: () =>
              ref.read(weatherSafetyProvider.notifier).cancelSnooze(),
        ),
      ],
    );
  }

  /// A row's button: its route when it has one, otherwise the in-place
  /// action (the guider's Loop) or the tab that holds the device.
  static Future<void> _runChecklistAction(
    BuildContext context,
    WidgetRef ref,
    ChecklistItemVm item,
  ) async {
    final route = item.route;
    if (route != null) {
      GoRouter.maybeOf(context)?.go(route);
      return;
    }
    final tab = switch (item.id) {
      ChecklistItemId.camera ||
      ChecklistItemId.filterWheel =>
        NightPanelTab.camera,
      ChecklistItemId.focuser => NightPanelTab.focus,
      ChecklistItemId.mount => NightPanelTab.mount,
      ChecklistItemId.guider => NightPanelTab.guide,
      ChecklistItemId.solver => NightPanelTab.solve,
      ChecklistItemId.disk ||
      ChecklistItemId.weather ||
      ChecklistItemId.dawn ||
      ChecklistItemId.site =>
        null,
    };
    if (item.id == ChecklistItemId.guider) {
      var looping = false;
      await nightPanelAttempt(context, 'nightPanelErrGuiderLoop', () async {
        await ref.read(nightPanelOpsProvider).startGuiderLoop();
        looping = true;
      });
      if (!looping || !context.mounted) return;
    }
    if (tab != null) ref.read(nightPanelTabProvider.notifier).state = tab;
  }
}
