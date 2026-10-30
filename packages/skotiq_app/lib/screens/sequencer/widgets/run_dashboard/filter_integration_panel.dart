import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'run_dashboard_format.dart';
import 'run_dashboard_providers.dart';

/// Horizontal "L: 2h12m / 3h | R: 45m / 1h | ..." progress card showing
/// accumulated integration per filter for the active session compared to
/// the goal totals computed from the loaded sequence's exposure nodes.
///
/// Genuinely new: there is no existing per-filter session totals widget
/// elsewhere in the app, so this is built from scratch using the
/// `runDashboardFilterTotalsProvider` aggregator.
class RunDashboardFilterIntegration extends ConsumerWidget {
  const RunDashboardFilterIntegration({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final totals = ref.watch(runDashboardFilterTotalsProvider);
    final glance = ref.watch(glanceModeProvider);

    // Pick a stable filter ordering: a common L/R/G/B/Ha/OIII/SII first,
    // then any additional filters in alphabetic order.
    const preferred = ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII'];
    final filterNames = <String>{
      ...totals.goalSecs.keys,
      ...totals.integrationSecs.keys,
      ...totals.totalAcquiredSecs.keys,
      if (totals.inFlightFilter != null) totals.inFlightFilter!,
    }.toList();
    filterNames.sort((a, b) {
      final ia = preferred.indexOf(a);
      final ib = preferred.indexOf(b);
      if (ia == ib) return a.compareTo(b);
      if (ia == -1) return 1;
      if (ib == -1) return -1;
      return ia.compareTo(ib);
    });

    return SkotiqCard(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.barChart3, size: 14, color: colors.primary),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(
                child: Text(
                  'PER-FILTER INTEGRATION',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: colors.textMuted,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          if (filterNames.isEmpty)
            Padding(
              padding:
                  const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceMd),
              child: Text(
                'No exposures configured.',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize12,
                  color: colors.textMuted,
                ),
              ),
            )
          else ...[
            for (final f in filterNames) ...[
              _FilterRow(
                colors: colors,
                name: f,
                acquired: totals.integrationSecs[f] ?? 0.0,
                goal: totals.goalSecs[f] ?? 0.0,
                rejected: totals.rejectedSecsFor(f),
                inFlight: totals.inFlightFilter == f
                    ? totals.inFlightElapsedSecs
                    : 0.0,
                glance: glance,
              ),
              if (f != filterNames.last)
                const SizedBox(height: SkotiqTokens.spaceSm),
            ],
          ],
        ],
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  final SkotiqColors colors;
  final String name;

  /// Accepted (usable) integration seconds.
  final double acquired;
  final double goal;

  /// Rejected integration seconds (total acquired minus accepted).
  final double rejected;

  /// In-flight exposure elapsed seconds for this filter (0 if not current).
  final double inFlight;

  /// Glance mode: enlarge the integration tally readout for across-the-room
  /// reading (this is a secondary-status surface opted into the larger type).
  final bool glance;

  const _FilterRow({
    required this.colors,
    required this.name,
    required this.acquired,
    required this.goal,
    this.rejected = 0.0,
    this.inFlight = 0.0,
    required this.glance,
  });

  Color _bandColor(String f, SkotiqColors c) =>
      FilterColors.forName(f, colors: c);

  @override
  Widget build(BuildContext context) {
    final color = _bandColor(name, colors);
    // The accepted bar measures usable signal; the in-flight overlay extends
    // it by the current exposure's elapsed time so integration ticks up live
    // (the sub isn't accepted until written, so it's drawn as a lighter cap).
    final acceptedFraction = goal > 0 ? (acquired / goal).clamp(0.0, 1.0) : 0.0;
    final liveFraction =
        goal > 0 ? ((acquired + inFlight) / goal).clamp(0.0, 1.0) : 0.0;
    final acquiredStr = formatSeconds(acquired);
    final goalStr = goal > 0 ? formatSeconds(goal) : '—';

    // Narrow column? Render the goal/acquired pair on a second line so
    // the row doesn't overflow when the column is squeezed (the audit
    // flagged this rendering on a 280px-wide test viewport).
    return LayoutBuilder(builder: (context, constraints) {
      final stacked = constraints.maxWidth < 220;
      final amountText = Text(
        goal > 0 ? '$acquiredStr / $goalStr' : acquiredStr,
        textAlign: stacked ? TextAlign.left : TextAlign.right,
        style: SkotiqTypography.glanceStyle(
          SkotiqTypography.withTabular(
            SkotiqTypography.labelQuiet.copyWith(
              fontWeight: FontWeight.w600,
              color: colors.textSecondary,
            ),
          ),
          enabled: glance,
        ),
        overflow: TextOverflow.ellipsis,
      );

      // Secondary line: how much was rejected (spent-but-unusable). Only
      // shown when there's a non-trivial gap so a clean filter stays quiet.
      final hasRejected = rejected >= 1.0;
      final rejectedText = hasRejected
          ? Text(
              '−${formatSeconds(rejected)} rejected',
              textAlign: stacked ? TextAlign.left : TextAlign.right,
              style: SkotiqTypography.withTabular(
                SkotiqTypography.captionSm.copyWith(
                  color: colors.warning,
                ),
              ),
              overflow: TextOverflow.ellipsis,
            )
          : null;

      final swatch = Container(
        width: 18,
        height: 18,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Text(
          name.length > 3 ? name.substring(0, 3) : name,
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize9,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      );

      final bar = Stack(
        children: [
          Container(
            height: 12,
            decoration: BoxDecoration(
              color: colors.surfaceAlt,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
            ),
          ),
          // In-flight cap: the live extension beyond accepted, drawn lighter
          // so it reads as "in progress, not yet banked."
          if (liveFraction > acceptedFraction)
            FractionallySizedBox(
              widthFactor: liveFraction,
              child: Container(
                height: 12,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
                ),
              ),
            ),
          FractionallySizedBox(
            widthFactor: acceptedFraction,
            child: Container(
              height: 12,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
              ),
            ),
          ),
        ],
      );

      if (stacked) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                swatch,
                const SizedBox(width: SkotiqTokens.spaceSm),
                Expanded(child: amountText),
              ],
            ),
            const SizedBox(height: 4),
            bar,
            if (rejectedText != null) ...[
              const SizedBox(height: 2),
              rejectedText,
            ],
          ],
        );
      }

      final amountColumn = Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          amountText,
          if (rejectedText != null) rejectedText,
        ],
      );

      return Row(
        children: [
          swatch,
          const SizedBox(width: SkotiqTokens.spaceSm),
          Expanded(child: bar),
          const SizedBox(width: SkotiqTokens.spaceSm),
          // Flexible (not SizedBox) so a too-wide label can shrink
          // gracefully and not push the bar off-screen.
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 60, maxWidth: 110),
              child: amountColumn,
            ),
          ),
        ],
      );
    });
  }
}
