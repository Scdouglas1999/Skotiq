import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/models.dart';

/// Small overlay card on the canvas showing the target's name, catalog id,
/// coordinates, and optional magnitude / size.
class FramingTargetInfoOverlay extends StatelessWidget {
  final SkotiqColors colors;
  final FramingTarget target;

  const FramingTargetInfoOverlay({
    super.key,
    required this.colors,
    required this.target,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.9),
        borderRadius: SkotiqTokens.borderRadiusInline8,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            target.name,
            style: SkotiqTypography.labelStrong
                .copyWith(color: colors.textPrimary),
          ),
          if (target.catalogId != null && target.catalogId != target.name)
            Text(
              target.catalogId!,
              style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
            ),
          const SizedBox(height: 4),
          Text(
            '${CoordinateFormat.raReadout(target.raHours)}  '
            '${CoordinateFormat.decReadout(target.decDegrees)}',
            style: SkotiqTypography.caption.copyWith(
                color: colors.textSecondary,
                fontFeatures: const [FontFeature.tabularFigures()]),
          ),
          if (target.magnitude != null || target.sizeArcmin != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                [
                  if (target.magnitude != null)
                    'Mag ${target.magnitude!.toStringAsFixed(1)}',
                  if (target.sizeArcmin != null)
                    "${target.sizeArcmin!.toStringAsFixed(0)}'",
                ].join('  '),
                style:
                    SkotiqTypography.caption.copyWith(color: colors.textMuted),
              ),
            ),
        ],
      ),
    );
  }
}

