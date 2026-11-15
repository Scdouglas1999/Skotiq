import 'package:flutter/material.dart';
import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';

/// Section header using typography hierarchy instead of decorative accents.
class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final double accentBarWidth;

  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.accentBarWidth = 2,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: SkotiqTypography.h5.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: SkotiqTokens.spaceXs),
                  Text(
                    subtitle!,
                    style: SkotiqTypography.caption.copyWith(
                      color: colors.textMuted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// A container for grouped controls with tonal separation.
class SectionWell extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final BorderRadius? borderRadius;

  const SectionWell({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(SkotiqTokens.spaceLg),
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final effectiveRadius = borderRadius ?? SkotiqTokens.borderRadiusMd;

    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: effectiveRadius,
        border: Border.all(color: colors.border.withValues(alpha: 0.65)),
      ),
      child: child,
    );
  }
}
