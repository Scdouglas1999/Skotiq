import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Compact toggle chip for annotation quick settings (compass, scale, labels, etc.)
class AnnotationQuickSettingChip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final SkotiqColors colors;
  final VoidCallback onTap;

  const AnnotationQuickSettingChip({
    super.key,
    required this.label,
    required this.isSelected,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: isSelected
            ? SkotiqDecorations.selectedSurface(
                colors.primary,
                borderRadius:
                    BorderRadius.circular(SkotiqTokens.radiusInline4),
                fillAlpha: 0.18,
              )
            : BoxDecoration(
                color: colors.surfaceAlt,
                borderRadius:
                    BorderRadius.circular(SkotiqTokens.radiusInline4),
                border: Border.all(color: colors.border),
              ),
        child: Text(
          label,
          style: SkotiqTypography.caption.copyWith(
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
              color: isSelected ? colors.primary : colors.textSecondary),
        ),
      ),
    );
  }
}
