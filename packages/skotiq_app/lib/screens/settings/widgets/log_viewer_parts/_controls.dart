// Level filter button and action toggle controls.
part of '../log_viewer.dart';

class _LevelFilterButton extends StatelessWidget {
  final String label;
  final bool isSelected;
  final Color? color;
  final VoidCallback onTap;

  const _LevelFilterButton({
    required this.label,
    required this.isSelected,
    this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final effectiveColor = color ?? colors.primary;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: isSelected
            ? SkotiqDecorations.chip(colors, tone: effectiveColor)
            : BoxDecoration(
                color: colors.well,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                border: Border.all(color: colors.border),
              ),
        child: Text(
          label,
          style: SkotiqTypography.caption.copyWith(
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
            color: isSelected ? effectiveColor : colors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _ActionToggle extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _ActionToggle({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: isActive
            ? SkotiqDecorations.chip(colors, tone: colors.primary)
            : BoxDecoration(
                color: colors.well,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                border: Border.all(color: colors.border),
              ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: isActive ? colors.primary : colors.textMuted,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: SkotiqTypography.caption.copyWith(
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                color: isActive ? colors.primary : colors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
