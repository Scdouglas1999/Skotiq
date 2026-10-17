import 'package:flutter/material.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';

/// A single readout in a [ResponsiveStatStrip].
@immutable
class ResponsiveStat {
  /// Short caption (e.g. `RMS`, `HFR`, `FRAMES`).
  final String label;

  /// The value text (e.g. `0.62"`, `2.1px`, `34/120`).
  final String value;

  /// Optional leading icon.
  final IconData? icon;

  /// Optional explicit value color (defaults to the theme's primary text).
  final Color? valueColor;

  /// Optional accent shown as a small leading dot — handy for status (good /
  /// warn / error) without adding a second column.
  final Color? accent;

  const ResponsiveStat({
    required this.label,
    required this.value,
    this.icon,
    this.valueColor,
    this.accent,
  });
}

/// A dense row of label/value readouts that reflows instead of overflowing.
///
/// Models the stat strips in the dashboard cockpit, the sequencer
/// equipment-telemetry row, and the guiding RMS readout: a tight horizontal
/// run of `LABEL  value` cells. As width shrinks it wraps to multiple rows,
/// then (on a compact phone) to a two-column / single-column grid. Values never
/// shrink below ~13sp and long text ellipsizes rather than clipping.
///
/// ```dart
/// ResponsiveStatStrip(
///   stats: [
///     ResponsiveStat(label: 'RMS', value: '0.62"', accent: colors.success),
///     ResponsiveStat(label: 'HFR', value: '2.1px'),
///     ResponsiveStat(label: 'FRAMES', value: '34/120'),
///   ],
/// )
/// ```
class ResponsiveStatStrip extends StatelessWidget {
  /// The readouts, in display order.
  final List<ResponsiveStat> stats;

  /// Minimum width a single stat cell needs to read comfortably. Drives the
  /// column count when the strip reflows. Defaults to 132.
  final double minCellWidth;

  /// Spacing between cells (both axes when wrapped).
  final double spacing;

  /// When true (default), stretches each cell to fill its grid column so the
  /// labels/values align. When false the cells size to content (good when the
  /// strip is centered).
  final bool stretch;

  const ResponsiveStatStrip({
    super.key,
    required this.stats,
    this.minCellWidth = 132,
    this.spacing = SkotiqTokens.spaceLg,
    this.stretch = true,
  });

  @override
  Widget build(BuildContext context) {
    if (stats.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;
        // How many cells fit in one row at the minimum comfortable width?
        final fitColumns = available.isFinite
            ? ((available + spacing) / (minCellWidth + spacing)).floor()
            : stats.length;
        final columns = fitColumns.clamp(1, stats.length);

        if (columns >= stats.length && available.isFinite) {
          // Everything fits on one row: lay out side-by-side with flexible
          // cells so nothing overflows even at the tight end of the fit.
          return Row(
            children: [
              for (var i = 0; i < stats.length; i++) ...[
                if (i > 0) SizedBox(width: spacing),
                Flexible(child: _StatCell(stat: stats[i])),
              ],
            ],
          );
        }

        // Reflow into a wrapping grid of `columns` cells per row.
        if (!available.isFinite) {
          return Wrap(
            spacing: spacing,
            runSpacing: spacing,
            children: [for (final s in stats) _StatCell(stat: s)],
          );
        }

        final cellWidth = (available - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final s in stats)
              SizedBox(
                width: cellWidth,
                child: _StatCell(stat: s, alignStart: stretch),
              ),
          ],
        );
      },
    );
  }
}

class _StatCell extends StatelessWidget {
  final ResponsiveStat stat;
  final bool alignStart;

  const _StatCell({required this.stat, this.alignStart = true});

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;

    final label = Text(
      stat.label.toUpperCase(),
      style: SkotiqTypography.overline.copyWith(color: colors.textMuted),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );

    // Values stay legible: monoSm is 12sp tabular; bump to 13 floor via body.
    final value = Text(
      stat.value,
      style: SkotiqTypography.withTabular(SkotiqTypography.bodySm)
          .copyWith(
            color: stat.valueColor ?? colors.textPrimary,
            fontWeight: FontWeight.w600,
            fontFamily: SkotiqTypography.fontFamilyMono,
          ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );

    final valueRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (stat.accent != null) ...[
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: stat.accent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
        ] else if (stat.icon != null) ...[
          Icon(stat.icon, size: 13, color: colors.textSecondary),
          const SizedBox(width: SkotiqTokens.spaceXs + 2),
        ],
        Flexible(child: value),
      ],
    );

    return Column(
      crossAxisAlignment: alignStart
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [label, const SizedBox(height: 2), valueRow],
    );
  }
}
