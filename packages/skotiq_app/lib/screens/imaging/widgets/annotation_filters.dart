import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Maps an [ObjectType] to its corresponding set of [AnnotationObjectFilter]s.
Set<AnnotationObjectFilter> filtersForObjectType(ObjectType type) {
  switch (type) {
    case ObjectType.galaxy:
      return {AnnotationObjectFilter.galaxies};
    case ObjectType.nebula:
      return {AnnotationObjectFilter.nebulae};
    case ObjectType.planetaryNebula:
      return {AnnotationObjectFilter.planetaryNebulae};
    case ObjectType.starCluster:
      return {AnnotationObjectFilter.starClusters};
    case ObjectType.star:
    case ObjectType.doubleStar:
      return {AnnotationObjectFilter.stars};
    case ObjectType.asterism:
    case ObjectType.unknown:
      return {AnnotationObjectFilter.other};
  }
}

/// Returns true if the given [ObjectType] is visible given the current
/// set of active [AnnotationObjectFilter]s.
bool isTypeVisibleFromSettings(
  ObjectType type,
  Set<AnnotationObjectFilter> filters,
) {
  return filtersForObjectType(type).any(filters.contains);
}

/// Filter chip for object type filtering
class AnnotationFilterChip extends StatelessWidget {
  final String label;
  final int count;
  final bool isSelected;
  final SkotiqColors colors;
  final VoidCallback onTap;

  const AnnotationFilterChip({
    super.key,
    required this.label,
    required this.count,
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
              )
            : BoxDecoration(
                color: colors.surfaceAlt,
                borderRadius:
                    BorderRadius.circular(SkotiqTokens.radiusInline4),
                border: Border.all(color: colors.border),
              ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: SkotiqTypography.caption.copyWith(
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  color: isSelected ? colors.primary : colors.textSecondary),
            ),
            if (count > 0) ...[
              const SizedBox(width: 4),
              Text(
                '($count)',
                style: SkotiqTypography.caption.copyWith(
                    color: isSelected
                        ? colors.primary.withValues(alpha: 0.7)
                        : colors.textMuted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
