// Summary chips, quality-filter chips, science badges and detail rows.
part of '../image_thumbnail_strip.dart';

class _SummaryChip extends StatelessWidget {
  final String label;
  final int value;
  final Color color;

  const _SummaryChip({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: SkotiqDecorations.chip(colors, tone: color),
      child: Text(
        '$label: $value',
        style: SkotiqTypography.labelStrongSm.copyWith(
          color: color,
        ),
      ),
    );
  }
}

class _QualityFilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _QualityFilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return ChoiceChip(
      label: Text(
        label,
        style: SkotiqTypography.labelStrongSm.copyWith(
          color: selected ? colors.textPrimary : colors.textSecondary,
        ),
      ),
      selected: selected,
      selectedColor: colors.primary.withValues(alpha: 0.2),
      backgroundColor: colors.surfaceHover,
      side: BorderSide(color: selected ? colors.primary : colors.border),
      onSelected: (_) => onTap(),
      visualDensity: VisualDensity.compact,
    );
  }
}

enum _FrameMenuAction { accept, reject, info }

class _ScienceBadge extends StatelessWidget {
  final String tooltip;
  final Color color;
  final String? label;
  final IconData? icon;

  const _ScienceBadge({
    required this.tooltip,
    required this.color,
    this.label,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: label == null ? 3 : 4,
          vertical: 2,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
        ),
        child: icon != null
            ? Icon(icon,
                size: SkotiqTokens.iconXs, color: SkotiqColors.dark.textPrimary)
            : Text(
                label ?? '',
                style: SkotiqTypography.caption.copyWith(
                  color: SkotiqColors.dark.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final SkotiqColors colors;

  const _DetailRow(this.label, this.value, this.colors);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textSecondary),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: SkotiqTypography.bodyStrong.copyWith(
                color: colors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
