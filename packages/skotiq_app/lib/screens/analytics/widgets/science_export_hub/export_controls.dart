part of '../science_export_hub.dart';

class _ExportTypeCard extends StatelessWidget {
  final SkotiqColors colors;
  final String title;
  final String description;
  final IconData icon;
  final bool isExporting;
  final VoidCallback onExport;
  final bool highlight;
  final bool enabled;
  final String actionLabel;
  final IconData actionIcon;

  const _ExportTypeCard({
    super.key,
    required this.colors,
    required this.title,
    required this.description,
    required this.icon,
    required this.isExporting,
    required this.onExport,
    this.highlight = false,
    this.enabled = true,
    this.actionLabel = 'CSV',
    this.actionIcon = LucideIcons.download,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor =
        highlight ? colors.primary.withValues(alpha: 0.7) : colors.border;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(
          color: borderColor,
          width: highlight ? 1.5 : 1.0,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: colors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: SkotiqTypography.labelStrong.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SkotiqButton(
            label: actionLabel,
            icon: actionIcon,
            size: ButtonSize.small,
            variant: ButtonVariant.secondary,
            onPressed: (isExporting || !enabled) ? null : onExport,
          ),
        ],
      ),
    );
  }
}

class _DateButton extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final VoidCallback onTap;

  const _DateButton({
    required this.colors,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
        button: true,
        enabled: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            decoration: BoxDecoration(
              color: colors.well,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
              border: Border.all(color: colors.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.calendar, size: 14, color: colors.textMuted),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textSecondary),
                ),
              ],
            ),
          ),
        ));
  }
}
