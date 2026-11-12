// The Overview tab (Tonight.dc.html): the last frame, the session, the
// equipment, the conditions and the log. Before a run "Before you start" and
// the next step take the place of the last frame and the session
// (TonightReady.dc.html).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/models.dart' show TargetHeaderNode;
import 'package:skotiq_core/providers.dart'
    show activeEquipmentProfileProvider, currentSequenceProvider, liveBroadcastProvider, weatherSafetyProvider;

import '../../../equipment/utils/connect_all_action.dart';

import '../../data/plan/night_plan_inputs.dart';
import '../../data/plan/night_run_phase_provider.dart';
import '../../data/plan/scheduler_provider.dart';
import '../../data/session/before_you_start_provider.dart';
import '../../data/session/conditions_provider.dart';
import '../../data/session/equipment_summary_provider.dart';
import '../../data/session/last_frame_metrics_provider.dart';
import '../../data/session/night_log_provider.dart';
import '../../data/session/run_grading_provider.dart';
import '../../data/session/session_stats_provider.dart';
import '../../night_control_contracts.dart';
import '../panel_ops.dart';
import '../panel_widgets.dart';
import 'after_run_section.dart';
import 'next_step_section.dart';
import 'overview_sections.dart';
import 'run_sections.dart';
import '../../../../router/app_routes.dart';

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
    final phase = ref.watch(nightRunPhaseProvider);
    final beforeRun = nightPanelBeforeRun(phase);
    return NightPanelBody(
      fill: NightLogSection(entries: ref.watch(nightLogProvider)),
      children: <Widget>[
        if (beforeRun) ...<Widget>[
          NightChecklistSection(
            items: ref.watch(nightBeforeYouStartProvider),
            onAction: (item) => _runChecklistAction(context, ref, item),
          ),
          const NightNextStepSection(),
        ] else ...<Widget>[
          NightLastFrameSection(frame: ref.watch(nightLastFrameProvider)),
          NightSessionSection(session: ref.watch(nightSessionStatsProvider)),
          if (phase == NightRunPhase.finished) const NightAfterRunSection(),
          ..._runSections(ref),
        ],
        if (ref.watch(liveBroadcastProvider) case final broadcast?)
          NightBroadcastSection(broadcast: broadcast),
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

  /// The blocks of the plan's optional parts, each only while the run uses
  /// it: the sky-brightness exposure once it has decided an exposure, the
  /// Target Scheduler while the plan has one, and its swap on the sky's
  /// conditions while that node swaps.
  static List<Widget> _runSections(WidgetRef ref) {
    final adaptive = ref.watch(nightAdaptiveExposureProvider);
    final scheduler = ref.watch(nightPlanSchedulerProvider);
    final swapBelow = scheduler?.swapOnConditionsBelow;
    return <Widget>[
      if (adaptive != null) NightAdaptiveExposureSection(decision: adaptive),
      if (scheduler != null)
        NightSchedulerSection(
          decision: ref.watch(latestSchedulerDecisionProvider),
          minScore: scheduler.minScoreToRun,
        ),
      if (swapBelow != null)
        NightConditionsSwapSection(
          snapshot: ref.watch(adaptiveSwapSnapshotProvider),
          swapBelow: swapBelow,
          targetName: (id) => _targetName(ref, id),
          now: ref.watch(nightNowProvider),
        ),
    ];
  }

  static String _targetName(WidgetRef ref, String id) {
    final node = ref.read(currentSequenceProvider)?.nodes[id];
    return node is TargetHeaderNode && node.targetName.isNotEmpty
        ? node.targetName
        : id;
  }

  /// A row's button: its route when it has one, otherwise the in-place
  /// action (the guider's Loop) or the tab that holds the device.
  static Future<void> _runChecklistAction(
    BuildContext context,
    WidgetRef ref,
    ChecklistItemVm item,
  ) async {
    if (item.connectsProfile) {
      final profile = ref.read(activeEquipmentProfileProvider);
      if (profile != null) {
        await runConnectAllForProfile(context, ref, profile);
        return;
      }
      // No profile to connect: Equipment is where one is made.
      GoRouter.maybeOf(context)?.go(AppRoute.equipment.path);
      return;
    }
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
