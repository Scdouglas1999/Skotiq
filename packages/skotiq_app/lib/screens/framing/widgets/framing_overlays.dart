import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';

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
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textMuted),
            ),
          const SizedBox(height: 4),
          Text(
            '${target.raFormatted}  ${target.decFormatted}',
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
                style: SkotiqTypography.caption
                    .copyWith(color: colors.textMuted),
              ),
            ),
        ],
      ),
    );
  }
}

/// Warning card used in the equipment section when the active profile is
/// incomplete (no profile / no focal length / no camera specs). Includes an
/// optional call-to-action button.
class FramingEquipmentWarningCard extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const FramingEquipmentWarningCard({
    super.key,
    required this.colors,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: SkotiqDecorations.chip(colors, tone: colors.warning),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colors.warning.withValues(alpha: 0.2),
                  borderRadius: SkotiqTokens.borderRadiusInline8,
                ),
                child: Icon(icon, size: 16, color: colors.warning),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: SkotiqTypography.eyebrow
                      .copyWith(color: colors.warning),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            message,
            style: SkotiqTypography.caption
                .copyWith(color: colors.textSecondary),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 12),
            // This navigates to Equipment exactly like Plan Tonight →
            // Recommendation's "Open Settings", so it must announce the same
            // way. A bare GestureDetector publishes an action with no role, so
            // assistive tech reads the sibling as `button: Open Settings` and
            // this one as `panel: Edit Profile` — the same kind of control, one
            // focusable and one not. Semantics + InkWell give it the button
            // role, keyboard focus and the ink the sibling has.
            Semantics(
              button: true,
              enabled: true,
              label: actionLabel,
              excludeSemantics: true,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onAction,
                  borderRadius: SkotiqTokens.borderRadiusMd,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: colors.warning.withValues(alpha: 0.15),
                      borderRadius: SkotiqTokens.borderRadiusMd,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          actionLabel!,
                          style: SkotiqTypography.labelQuiet
                              .copyWith(color: colors.warning),
                        ),
                        const SizedBox(width: 4),
                        Icon(SkotiqIcons.arrowRight,
                            size: 12, color: colors.warning),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Label/value row used in the equipment summary and similar info blocks.
class FramingInfoRow extends StatelessWidget {
  final String label;
  final String value;
  final SkotiqColors colors;
  final bool highlight;

  const FramingInfoRow({
    super.key,
    required this.label,
    required this.value,
    required this.colors,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: SkotiqTypography.caption
                .copyWith(color: colors.textSecondary),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: SkotiqTypography.bodySm.copyWith(
              fontWeight: highlight ? FontWeight.w600 : FontWeight.w500,
              color: highlight ? colors.primary : colors.textPrimary,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// Coordinate row used in the coordinates panel; supports tinted value text
/// for "good" (high altitude) or "bad" (low / below horizon) state.
class FramingCoordRow extends StatelessWidget {
  final String label;
  final String value;
  final SkotiqColors colors;
  final bool isGood;
  final bool isBad;

  const FramingCoordRow({
    super.key,
    required this.label,
    required this.value,
    required this.colors,
    this.isGood = false,
    this.isBad = false,
  });

  @override
  Widget build(BuildContext context) {
    Color valueColor = colors.textPrimary;
    if (isGood) valueColor = colors.success;
    if (isBad) valueColor = colors.error;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: SkotiqTypography.caption
              .copyWith(color: colors.textSecondary),
        ),
        Text(
          value,
          style: SkotiqTypography.caption.copyWith(
              color: valueColor,
              fontFeatures: const [FontFeature.tabularFigures()],
              fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}
