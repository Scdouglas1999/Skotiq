import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'run_dashboard_format.dart';
import 'run_dashboard_providers.dart';

/// Wide header at the top of the Run dashboard showing the active target
/// name, coordinates, current altitude, time-to-set, time-to-meridian, and
/// per-target execution progress.
///
/// Read-only by construction. Renders an informative null-state when no
/// target is bound (the dashboard's empty state replaces the whole tab
/// for the idle case; this panel handles the "running but no target node"
/// edge case).
///
/// The progress bar reads from [targetExecutionProgressProvider] — the
/// same provider that drives the in-tree `TargetHeaderCard` on the Builder
/// tab — so "12/24 frames on M31" appears identically in both places.
class RunDashboardTargetHeader extends ConsumerWidget {
  const RunDashboardTargetHeader({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final target = ref.watch(runDashboardActiveTargetProvider);
    final sky = ref.watch(runDashboardSkyStatsProvider);
    final settingsAsync = ref.watch(appSettingsProvider);
    final hasLocation = settingsAsync.valueOrNull?.hasObserverLocation ?? false;

    if (target == null) {
      return _HeaderShell(
        colors: colors,
        child: Row(
          children: [
            Icon(LucideIcons.target, size: 18, color: colors.textMuted),
            const SizedBox(width: SkotiqTokens.spaceMd),
            Text(
              'No target configured',
              style:
                  SkotiqTypography.h5.copyWith(color: colors.textSecondary),
            ),
          ],
        ),
      );
    }

    final isMobile = Responsive.isMobile(context);

    final altText = sky != null
        ? '${sky.altitudeDeg.toStringAsFixed(1)}°'
        : (hasLocation ? '—' : 'set location');
    final altColor = sky == null
        ? colors.textMuted
        : sky.altitudeDeg < 20
            ? colors.error
            : sky.altitudeDeg < 30
                ? colors.warning
                : colors.success;

    final meridianText = formatDuration(sky?.timeToTransit);
    final setText = formatDuration(sky?.timeToSet);
    // Label the "to set" stat with the actual horizon used so 20° and 0°
    // configurations are not visually confusing.
    final setLabel = sky == null
        ? 'To set'
        : sky.horizonDeg <= 0.01
            ? 'To set'
            : 'To ${sky.horizonDeg.toStringAsFixed(0)}°';

    final stats = <Widget>[
      _HeaderStat(
        colors: colors,
        icon: LucideIcons.mountain,
        label: 'Altitude',
        value: altText,
        valueColor: altColor,
      ),
      _HeaderStat(
        colors: colors,
        icon: LucideIcons.timer,
        label: 'To meridian',
        value: meridianText,
      ),
      _HeaderStat(
        colors: colors,
        icon: LucideIcons.sunset,
        label: setLabel,
        value: setText,
      ),
    ];

    final name = Text(
      target.displayName,
      style: TextStyle(
        fontSize: isMobile
            ? SkotiqTypography.fontSize18
            : SkotiqTypography.fontSize22,
        fontWeight: FontWeight.w700,
        color: colors.textPrimary,
      ),
      overflow: TextOverflow.ellipsis,
    );

    final coords = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(LucideIcons.compass, size: 12, color: colors.textMuted),
        const SizedBox(width: 4),
        Text(
          '${formatRA(target.raHours)}   ${formatDec(target.decDegrees)}',
          style: SkotiqTypography.withTabular(
            SkotiqTypography.labelSm.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ),
      ],
    );

    final identity = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        name,
        const SizedBox(height: 4),
        coords,
      ],
    );

    final progress = _TargetProgress(
      colors: colors,
      targetNodeId: target.id,
    );

    // Render the integration budget panel below the
    // frame-count progress when configured. Same target id so all
    // rows stay aligned visually.
    final budgetPanel = _BudgetProgressPanel(colors: colors);

    if (isMobile) {
      return _HeaderShell(
        colors: colors,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            identity,
            const SizedBox(height: SkotiqTokens.spaceMd),
            Wrap(
              spacing: SkotiqTokens.spaceLg,
              runSpacing: SkotiqTokens.spaceSm,
              children: stats,
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            progress,
            budgetPanel,
          ],
        ),
      );
    }

    return _HeaderShell(
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: identity),
              for (final s in stats) ...[
                const SizedBox(width: SkotiqTokens.space2xl),
                s,
              ],
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          progress,
          budgetPanel,
        ],
      ),
    );
  }
}

/// Per-target integration budget progress card. Renders
/// only when the active target has a budget configured. Pulls from
/// [runDashboardActiveBudgetProvider] so the math stays consistent with
/// the runtime.
class _BudgetProgressPanel extends ConsumerWidget {
  final SkotiqColors colors;

  const _BudgetProgressPanel({required this.colors});

  String _formatDuration(double secs) => DurationFormat.seconds(
        secs,
        style: DurationStyle.compactTrimmed,
        roundToMinute: true,
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final budget = ref.watch(runDashboardActiveBudgetProvider);
    if (budget == null) return const SizedBox.shrink();

    // Sort filters by canonical photometric order, then alphabetic.
    const preferred = ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII'];
    final filters = budget.resolvedCapSecs.keys.toList()
      ..sort((a, b) {
        final ia = preferred.indexOf(a);
        final ib = preferred.indexOf(b);
        if (ia == ib) return a.compareTo(b);
        if (ia == -1) return 1;
        if (ib == -1) return -1;
        return ia.compareTo(ib);
      });

    final rows = <Widget>[];
    for (final f in filters) {
      final cap = budget.resolvedCapSecs[f]!;
      final done = budget.completedSecs[f] ?? 0;
      final fraction = cap > 0 ? (done / cap).clamp(0.0, 1.5) : 0.0;
      final isMet = done >= cap && cap > 0;
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              SizedBox(
                width: 40,
                child: Text(
                  f,
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize11,
                    fontWeight: FontWeight.w700,
                    color: isMet ? colors.success : colors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusXs),
                  child: LinearProgressIndicator(
                    value: fraction.clamp(0.0, 1.0),
                    minHeight: 6,
                    backgroundColor: colors.surfaceAlt,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      isMet ? colors.success : colors.primary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${_formatDuration(done)} / ${_formatDuration(cap)}',
                style: SkotiqTypography.withTabular(
                  SkotiqTypography.captionSm.copyWith(
                    color: isMet ? colors.success : colors.textMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final title = budget.budgetMet ? 'BUDGET MET' : 'BUDGET';
    final titleColor = budget.budgetMet ? colors.success : colors.textMuted;
    final overallText = budget.totalSecs > 0
        ? '${_formatDuration(budget.completedTotalSecs)} / ${_formatDuration(budget.totalSecs)}'
        : _formatDuration(budget.completedTotalSecs);

    return Padding(
      padding: const EdgeInsets.only(top: SkotiqTokens.spaceMd),
      child: Container(
        padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
        decoration: BoxDecoration(
          color: colors.surfaceAlt,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
          border: Border.all(
              color: budget.budgetMet ? colors.success : colors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(LucideIcons.target, size: 12, color: titleColor),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize10,
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.w700,
                    color: titleColor,
                  ),
                ),
                const Spacer(),
                Text(
                  overallText,
                  style: SkotiqTypography.withTabular(
                    SkotiqTypography.labelQuiet.copyWith(
                      color: titleColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ...rows,
          ],
        ),
      ),
    );
  }
}

/// Per-target frame-count + progress bar. Mirrors the visual treatment
/// rendered by [TargetHeaderCard] on the Builder tab — same provider,
/// same numbers, same colour ramp.
class _TargetProgress extends ConsumerWidget {
  final SkotiqColors colors;
  final String targetNodeId;

  const _TargetProgress({
    required this.colors,
    required this.targetNodeId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final executionState = ref.watch(sequenceExecutionStateProvider);
    final isActive = executionState == SequenceExecutionState.running ||
        executionState == SequenceExecutionState.paused ||
        executionState == SequenceExecutionState.stopping;
    if (!isActive) return const SizedBox.shrink();

    final stats = ref.watch(targetExecutionProgressProvider(targetNodeId));
    if (!stats.hasPlannedFrames) return const SizedBox.shrink();

    final completedMins = (stats.completedIntegrationSecs / 60).round();
    final totalMins = (stats.totalIntegrationSecs / 60).round();
    final progressState = executionState == SequenceExecutionState.paused
        ? SkotiqProgressState.paused
        : SkotiqProgressState.normal;

    if (stats.completionUnknown) {
      // The target's exposures repeat, and node statuses only describe the
      // current pass — so quote the plan, which is true, and leave completion
      // to the run-level counters rather than inventing a per-target percent.
      return Text(
        '${stats.totalFrames} frames planned • ${totalMins}m',
        style: SkotiqTypography.labelStrongSm
            .copyWith(color: colors.textSecondary),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            children: [
              Text(
                '${stats.completedFrames}/${stats.totalFrames} frames',
                style: SkotiqTypography.labelStrongSm
                    .copyWith(color: colors.textSecondary),
              ),
              const SizedBox(width: 6),
              Text(
                '•',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: colors.textMuted,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${completedMins}m / ${totalMins}m',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: colors.textMuted,
                ),
              ),
              const Spacer(),
              Text(
                '${(stats.fraction * 100).round()}%',
                style: SkotiqTypography.labelStrongSm
                    .copyWith(color: colors.textSecondary),
              ),
            ],
          ),
        ),
        SkotiqProgressBar(
          value: stats.fraction,
          style: SkotiqProgressStyle.thin,
          state: progressState,
        ),
      ],
    );
  }
}

class _HeaderShell extends StatelessWidget {
  final SkotiqColors colors;
  final Widget child;

  const _HeaderShell({required this.colors, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.space2xl,
        vertical: SkotiqTokens.spaceLg,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: child,
    );
  }
}

class _HeaderStat extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _HeaderStat({
    required this.colors,
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 11, color: colors.textMuted),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize10,
                color: colors.textMuted,
                letterSpacing: 0.4,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: SkotiqTypography.withTabular(
            SkotiqTypography.h4.copyWith(
              fontWeight: FontWeight.w700,
              color: valueColor ?? colors.textPrimary,
            ),
          ),
        ),
      ],
    );
  }
}
