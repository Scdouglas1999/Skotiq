// The Solve tab's lower sections: the settings a solve uses, rotation
// against the target, and this session's solves.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../../actions/night_action_controller.dart';
import '../../actions/solve_and_sync.dart' show solveFrameSettings;
import '../../data/plan/night_plan_inputs.dart';
import '../../data/plan/plan_steps_provider.dart' show nightActiveStepProvider;
import '../../night_control_contracts.dart';
import '../panel_widgets.dart';
import 'night_solve_tab.dart';
import 'recent_solves_provider.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import '../../../../router/settings_sections.dart';
import '../../../../router/app_routes.dart';

/// Where the solver settings live.
final String kNightSolveSettingsRoute =
    AppRoutes.settings(SettingsSectionId.plateSolving);

/// Rotation within this many degrees of the target needs no correction.
const double kNightRotationToleranceDeg = 0.5;

/// The plan's Center step the Solve tab quotes: the one running, else the
/// first in the loaded plan; null when the plan has none.
///
/// The Center button and a plan's Center step center to different
/// tolerances, so the tab names each rather than quoting the button's for a
/// run whose step uses its own.
final nightPlanCenterNodeProvider = Provider<CenterNode?>((ref) {
  final active = ref.watch(nightActiveStepProvider)?.node;
  if (active is CenterNode) return active;
  final tree = ref.watch(nightPlanTreeProvider);
  if (tree == null) return null;
  for (final step in tree.steps) {
    final node = step.node;
    if (node is CenterNode) return node;
  }
  return null;
});

/// The frame a solve takes and how centering decides it is done.
class NightSolveSettingsSection extends ConsumerWidget {
  const NightSolveSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final frame = solveFrameSettings(
      manual: ref.watch(exposureSettingsProvider),
      profile: ref.watch(activeEquipmentProfileProvider),
    );
    final filter = ref.watch(filterWheelStateProvider).currentFilterName;
    final planCenter = ref.watch(nightPlanCenterNodeProvider);
    final exposure = frame.exposureTime;
    return NightPanelSection(
      title: l10n.text('nightScopeSolveSettings'),
      trailing: settings?.plateSolver,
      children: [
        NightPanelValues(
          items: [
            MetricGridItem(
              label: l10n.text('nightScopeSolveExposure'),
              value: '${_number(exposure)} s',
            ),
            MetricGridItem(
              label: l10n.text('nightScopeSolveBinning'),
              value: '${frame.binningX}×${frame.binningY}',
            ),
            MetricGridItem(
              label: l10n.text('nightScopeSolveFilter'),
              value: filter == null || filter.isEmpty ? null : filter,
            ),
          ],
        ),
        if (planCenter != null)
          NightPanelNote(
            l10n.text(
              'nightScopeSolvePlanCenterRule',
              params: {
                'arcsec': _number(planCenter.accuracyArcsec),
                'attempts': '${planCenter.maxAttempts}',
              },
            ),
          ),
        NightPanelNote(
          l10n.text(
            settings?.blindSolve == true
                ? 'nightScopeSolveCenterRuleBlind'
                : 'nightScopeSolveCenterRule',
            params: {
              'arcsec': _number(ManualCentering.toleranceArcsec),
              'attempts': '${ManualCentering.maxIterations}',
            },
          ),
        ),
        NightPanelButtonGrid(
          columns: 1,
          buttons: [
            NightPanelButtonSpec(
              key: const ValueKey<String>('nightSolve.settings'),
              label: l10n.text('nightScopeSolveEditSettings'),
              onPressed: () => context.go(kNightSolveSettingsRoute),
            ),
          ],
        ),
      ],
    );
  }
}

/// The camera angle the last solve measured, against the target's.
class NightSolveRotationSection extends ConsumerWidget {
  const NightSolveRotationSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final result = ref.watch(plateSolveStateProvider).lastResult;
    final targetRotation = ref.watch(nightSolveTargetRotationProvider);
    final rotator = ref.watch(rotatorStateProvider);
    final hasRotator =
        rotator.connectionState == DeviceConnectionState.connected;
    final measured =
        result != null && result.success && result.rotation.isFinite
            ? result.rotation
            : null;

    final String advice;
    MetricTone? tone;
    if (measured == null) {
      advice = l10n.text('nightScopeRotationNoSolve');
    } else if (targetRotation == null) {
      advice = l10n.text(
        'nightScopeRotationNoTarget',
        params: {'camera': measured.toStringAsFixed(1)},
      );
    } else {
      // The shortest turn from the measured angle to the target's.
      final diff = ((targetRotation - measured + 540) % 360) - 180;
      final params = {
        'camera': measured.toStringAsFixed(1),
        'target': targetRotation.toStringAsFixed(1),
        'diff': diff.abs().toStringAsFixed(1),
      };
      if (diff.abs() <= kNightRotationToleranceDeg) {
        advice = l10n.text('nightScopeRotationOk', params: params);
        tone = MetricTone.good;
      } else {
        // Which way to turn depends on the optical train, so the advice
        // gives the size of the turn and leaves the direction to a re-solve.
        advice = l10n.text(
          hasRotator
              ? 'nightScopeRotationTurnRotator'
              : 'nightScopeRotationTurnByHand',
          params: params,
        );
        tone = MetricTone.warning;
      }
    }

    return NightPanelSection(
      title: l10n.text('nightScopeRotation'),
      trailing: hasRotator
          ? (rotator.deviceName ?? l10n.text('nightScopeRotator'))
          : l10n.text('nightScopeNoRotator'),
      children: [NightPanelNote(advice, tone: tone, maxLines: null)],
    );
  }
}

/// This session's solves and centerings, newest first.
class NightRecentSolvesSection extends ConsumerWidget {
  const NightRecentSolvesSection({super.key});

  static const int rows = 6;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final colors = context.skotiqColors;
    final records = ref.watch(nightRecentSolvesProvider);
    final target = ref.watch(nightCenterTargetProvider);
    final clock = ref.watch(clockProvider);

    final children = <Widget>[];
    if (records.isEmpty) {
      children.add(NightPanelNote(l10n.text('nightScopeSolveRecentNone')));
    }
    for (final record in records.take(rows)) {
      final String what;
      String? value;
      if (record.kind == NightSolveKind.center) {
        final tries = record.iterations;
        what = tries == null
            ? l10n.text('nightScopeSolveRecentCenter')
            : l10n.text(
                'nightScopeSolveRecentCenterTries',
                params: {'count': '$tries'},
              );
        final offset = record.offsetArcsec;
        value = offset == null ? null : AngleFormat.arcsec(offset);
      } else {
        what = l10n.text('nightScopeSolveRecentSolve');
        final ra = record.raDegrees;
        final dec = record.decDegrees;
        value = record.offsetArcsec == null
            ? null
            : AngleFormat.arcsec(record.offsetArcsec!);
        if (value == null && ra != null && dec != null && target != null) {
          value = AngleFormat.arcsec(AstronomyCalculations.angularSeparation(
                ra1Deg: ra,
                dec1Deg: dec,
                ra2Deg: target.raHours * 15,
                dec2Deg: target.decDegrees,
              ) *
              3600);
        }
      }
      if (!record.success) value = l10n.text('nightScopeSolveRecentFailed');
      children.add(
        _RecentRow(
          time: ClockFormat.hm(clock.toNightClock(record.at)),
          what: what,
          value: value,
          valueColor: record.success ? null : colors.error,
        ),
      );
    }

    return NightPanelSection(
      title: l10n.text('nightScopeSolveRecent'),
      trailing: l10n.text('nightScopeThisSession'),
      children: children,
    );
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({
    required this.time,
    required this.what,
    required this.value,
    this.valueColor,
  });

  final String time;
  final String what;
  final String? value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final mono = SkotiqTypography.monoSm.copyWith(color: colors.textMuted);
    return MergeSemantics(
      child: Row(
        children: [
          Text(time, style: mono),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Expanded(
            child: Text(
              what,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textSecondary),
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Text(
            value ?? kReadoutUnknown,
            style: mono.copyWith(color: valueColor ?? colors.textPrimary),
          ),
        ],
      ),
    );
  }
}

String _number(double value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toStringAsFixed(1);
