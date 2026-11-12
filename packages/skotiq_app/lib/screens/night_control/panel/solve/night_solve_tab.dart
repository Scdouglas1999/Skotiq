// The right panel's Solve tab (board TonightSolve): the last plate solve,
// Solve / Solve & sync / Center, the settings a solve uses, rotation advice
// against the target, and this session's solves.
//
// Solve, Solve & sync and Center go through the action controller. Solve &
// sync and Center pause a running run first and resume it after; Solve
// alone touches no device and solves the frame already on screen.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../../actions/manual_action_gating.dart';
import '../../actions/night_action_controller.dart';
import '../../data/plan/night_plan_inputs.dart';
import '../../night_control_contracts.dart';
import '../../../sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import '../mount/night_panel_parts.dart';
import 'recent_solves_provider.dart';
import 'solve_sections.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

class NightSolveTab extends ConsumerWidget {
  const NightSolveTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return const NightPanelScroll(
      children: [
        _LastSolveSection(),
        NightSolveSettingsSection(),
        NightSolveRotationSection(),
        NightRecentSolvesSection(),
      ],
    );
  }
}

/// A solver result field that is set: finite and, for sizes, positive.
double? _known(double value, {bool positive = false}) =>
    !value.isFinite || (positive && value <= 0) ? null : value;

class _LastSolveSection extends ConsumerWidget {
  const _LastSolveSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final colors = context.skotiqColors;
    final solveState = ref.watch(plateSolveStateProvider);
    final result = solveState.lastResult;
    final records = ref.watch(nightRecentSolvesProvider);
    final action = ref.watch(nightActionStateProvider);
    final inputs = ref.watch(nightActionInputsProvider);
    final target = ref.watch(nightCenterTargetProvider);
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final clock = ref.watch(clockProvider);

    // The operator's last solve pairs with the solver's result; a run's
    // centering solves arrive as records only.
    NightSolveRecord? lastRecord;
    NightSolveRecord? newestRunSolve;
    for (final record in records) {
      if (record.kind != NightSolveKind.solve) continue;
      if (record.byRun) {
        newestRunSolve ??= record;
      } else {
        lastRecord ??= record;
      }
    }
    final runSolve = newestRunSolve != null &&
            (result == null ||
                lastRecord == null ||
                newestRunSolve.at.isAfter(lastRecord.at))
        ? newestRunSolve
        : null;
    final solved = result != null && result.success;

    // The solver's own timing pairs with the result shown; the controller's
    // timing covers a Solve & sync whose solver did not report one.
    final reported = result == null ? null : _known(result.solveTimeSecs);
    final duration = reported != null && reported > 0
        ? Duration(milliseconds: (reported * 1000).round())
        : action.lastSolveDuration;

    final String status;
    final Color statusColor;
    bool inFlight(ManualActionId id) => action.isBusy && action.active == id;

    if (solveState.isSolving || inFlight(ManualActionId.solve)) {
      status = l10n.text('nightScopeSolveSolving');
      statusColor = colors.warning;
    } else if (runSolve != null) {
      status = [
        l10n.text('nightScopeSolveSolved'),
        ClockFormat.hm(clock.toNightClock(runSolve.at)),
      ].join(' · ');
      statusColor = colors.success;
    } else if (result == null) {
      status = l10n.text('nightScopeSolveNone');
      statusColor = colors.textMuted;
    } else {
      final parts = <String>[
        l10n.text(solved ? 'nightScopeSolveSolved' : 'nightScopeSolveFailed'),
        if (lastRecord != null)
          ClockFormat.hm(clock.toNightClock(lastRecord.at)),
        if (duration != null)
          '${(duration.inMilliseconds / 1000).toStringAsFixed(1)} s',
      ];
      status = parts.join(' · ');
      statusColor = solved ? colors.success : colors.error;
    }

    // A run's solve reports its position and its distance from the run's
    // target; the solver's other measurements stay with the operator's.
    final fromResult = solved && runSolve == null;
    final ra = runSolve != null
        ? runSolve.raDegrees
        : (fromResult ? _known(result.ra) : null);
    final dec = runSolve != null
        ? runSolve.decDegrees
        : (fromResult ? _known(result.dec) : null);
    final scale = fromResult ? _known(result.pixelScale, positive: true) : null;
    final fieldW =
        fromResult ? _known(result.fieldWidth, positive: true) : null;
    final fieldH =
        fromResult ? _known(result.fieldHeight, positive: true) : null;
    final rotation = fromResult ? _known(result.rotation) : null;
    final offTarget = runSolve?.offsetArcsec ??
        (ra == null || dec == null || target == null
            ? null
            : AstronomyCalculations.angularSeparation(
                  ra1Deg: ra,
                  dec1Deg: dec,
                  ra2Deg: target.raHours * 15,
                  dec2Deg: target.decDegrees,
                ) *
                3600);

    // The controller's gating, so the action bar and this tab never
    // disagree. A solve started elsewhere (the Imaging screen) holds the solver too.
    final solveReason = manualActionDisabledReason(inputs, ManualActionId.solve)
            ?.resolve(l10n) ??
        (solveState.isSolving && !inFlight(ManualActionId.solve)
            ? l10n.text('nightScopeWhySolving')
            : null);
    final syncReason =
        manualActionDisabledReason(inputs, ManualActionId.solveSync)
            ?.resolve(l10n);
    final centerReason =
        manualActionDisabledReason(inputs, ManualActionId.center)
            ?.resolve(l10n);

    return NightPanelSection(
      title: l10n.text('nightScopeSolveLast'),
      trailing: status,
      trailingColor: statusColor,
      children: [
        NightPanelValues(
          columns: 2,
          items: [
            MetricGridItem(
              label: l10n.text('nightScopeRa'),
              value:
                  ra == null ? null : CoordinateFormat.raDenseFromDegrees(ra),
            ),
            MetricGridItem(
              label: l10n.text('nightScopeDec'),
              value: dec == null ? null : CoordinateFormat.decDense(dec),
            ),
            MetricGridItem(
              label: l10n.text('nightScopeSolveRotation'),
              value:
                  rotation == null ? null : '${rotation.toStringAsFixed(1)}°',
            ),
            MetricGridItem(
              label: l10n.text('nightScopeSolveScale'),
              value: scale == null ? null : '${scale.toStringAsFixed(2)}"/px',
            ),
            MetricGridItem(
              label: l10n.text('nightScopeSolveField'),
              value: fieldW == null || fieldH == null
                  ? null
                  : "${(fieldW * 60).toStringAsFixed(0)}'×"
                      "${(fieldH * 60).toStringAsFixed(0)}'",
            ),
            MetricGridItem(
              label: l10n.text('nightScopeSolveOffTarget'),
              value: offTarget == null ? null : AngleFormat.arcsec(offTarget),
            ),
          ],
        ),
        if (runSolve == null &&
            result != null &&
            !result.success &&
            result.error != null)
          NightPanelNote(result.error!, color: colors.error),
        // Solve & sync on its own row: its label does not fit a third of
        // the panel.
        NightPanelButtonGrid(
          columns: 1,
          buttons: [
            NightPanelButtonSpec(
              key: const ValueKey<String>('nightSolve.solveSync'),
              label: l10n.text('nightActSolveSync'),
              emphasized: true,
              busy: inFlight(ManualActionId.solveSync),
              disabledReason: syncReason,
              onPressed: syncReason == null
                  ? () => unawaited(
                        ref.read(nightActionApiProvider).solveAndSync(),
                      )
                  : null,
            ),
          ],
        ),
        NightPanelButtonGrid(
          columns: 2,
          buttons: [
            NightPanelButtonSpec(
              key: const ValueKey<String>('nightSolve.solve'),
              label: l10n.text('nightScopeSolveSolve'),
              busy: inFlight(ManualActionId.solve),
              disabledReason: solveReason,
              onPressed: solveReason == null
                  ? () => unawaited(ref.read(nightActionApiProvider).solve())
                  : null,
            ),
            NightPanelButtonSpec(
              key: const ValueKey<String>('nightSolve.center'),
              label: l10n.text('nightActCenter'),
              busy: inFlight(ManualActionId.center),
              disabledReason: centerReason,
              onPressed: centerReason == null
                  ? () => unawaited(ref.read(nightActionApiProvider).center())
                  : null,
            ),
          ],
        ),
        SkotiqSwitchRow(
          key: const ValueKey<String>('nightSolve.syncWhenCentering'),
          label: l10n.text('nightScopeSolveSyncCentering'),
          tooltip: l10n.text('nightScopeSolveSyncCenteringHint'),
          compact: true,
          // Off and disabled until the settings load.
          value: settings?.centeringSyncMount == true,
          enabled: settings != null,
          onChanged: settings == null
              ? null
              : (value) => unawaited(
                    ref
                        .read(appSettingsProvider.notifier)
                        .setCenteringSyncMount(value),
                  ),
        ),
      ],
    );
  }
}

/// The target rotation the run asks for; null when none is set.
final nightSolveTargetRotationProvider = Provider<double?>((ref) {
  final rotation = ref.watch(runDashboardActiveTargetProvider)?.rotation;
  return rotation == null || !rotation.isFinite ? null : rotation;
});
