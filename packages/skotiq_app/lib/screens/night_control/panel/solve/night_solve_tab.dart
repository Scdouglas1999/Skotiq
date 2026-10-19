// The right panel's Solve tab (board TonightSolve): the last plate solve,
// Solve / Solve & sync / Center, the settings a solve uses, rotation advice
// against the target, and this session's solves.
//
// Solve, Solve & sync and Center go through the action controller. Solve &
// sync and Center pause a running run first and resume it after; Solve
// alone touches no device and solves the frame already on screen.
import 'dart:async';
import 'dart:math' as math;

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

/// Angular distance in arcseconds between two J2000 positions.
double separationArcsec(
  double raDeg1,
  double decDeg1,
  double raDeg2,
  double decDeg2,
) {
  const rad = math.pi / 180;
  final d1 = decDeg1 * rad, d2 = decDeg2 * rad;
  final dRa = (raDeg1 - raDeg2) * rad;
  final sinDDec = math.sin((d2 - d1) / 2);
  final sinDRa = math.sin(dRa / 2);
  final h = sinDDec * sinDDec + math.cos(d1) * math.cos(d2) * sinDRa * sinDRa;
  return 2 * math.asin(math.sqrt(h.clamp(0.0, 1.0))) / rad * 3600;
}

/// `0.8"`, `4.2'`, `2.2°`: an angle in arcseconds at a readable unit.
/// Plain ASCII marks: the mono face has no double prime.
String formatArcsec(double arcsec) {
  if (arcsec < 60) return '${arcsec.toStringAsFixed(1)}"';
  if (arcsec < 3600) return "${(arcsec / 60).toStringAsFixed(1)}'";
  return '${(arcsec / 3600).toStringAsFixed(1)}°';
}

/// `23:49`.
String formatClockTime(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

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

    NightSolveRecord? lastRecord;
    for (final record in records) {
      if (record.kind == NightSolveKind.solve) {
        lastRecord = record;
        break;
      }
    }
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
    } else if (result == null) {
      status = l10n.text('nightScopeSolveNone');
      statusColor = colors.textMuted;
    } else {
      final parts = <String>[
        l10n.text(solved ? 'nightScopeSolveSolved' : 'nightScopeSolveFailed'),
        if (lastRecord != null)
          formatClockTime(clock.toNightClock(lastRecord.at)),
        if (duration != null)
          '${(duration.inMilliseconds / 1000).toStringAsFixed(1)} s',
      ];
      status = parts.join(' · ');
      statusColor = solved ? colors.success : colors.error;
    }

    final ra = solved ? _known(result.ra) : null;
    final dec = solved ? _known(result.dec) : null;
    final scale = solved ? _known(result.pixelScale, positive: true) : null;
    final fieldW = solved ? _known(result.fieldWidth, positive: true) : null;
    final fieldH = solved ? _known(result.fieldHeight, positive: true) : null;
    final rotation = solved ? _known(result.rotation) : null;
    final offTarget = ra == null || dec == null || target == null
        ? null
        : separationArcsec(ra, dec, target.raHours * 15, target.decDegrees);

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
              value: ra == null
                  ? null
                  : CoordinateFormat.raFromDegrees(
                      ra,
                      style: SexagesimalStyle.compactLetters,
                      seconds: SecondsPrecision.integerRounded,
                    ),
            ),
            MetricGridItem(
              label: l10n.text('nightScopeDec'),
              value: dec == null
                  ? null
                  : CoordinateFormat.dec(
                      dec,
                      style: SexagesimalStyle.compactLetters,
                      seconds: SecondsPrecision.integerRounded,
                    ),
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
              value: offTarget == null ? null : formatArcsec(offTarget),
            ),
          ],
        ),
        if (result != null && !result.success && result.error != null)
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
          value: settings?.centeringSyncMount ?? false,
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
