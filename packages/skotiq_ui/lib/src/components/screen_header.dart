import 'package:flutter/material.dart';
import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';
import '../utils/responsive_utils.dart';

/// Typography-led screen header with a crisp bottom divider.
///
/// Superseded by `PageHeader` (04-shell §4), which is a fixed 56 px, carries
/// the underline tab strip, and has no `subtitle` — the sentence under the
/// title is the thing the overhaul is removing. Screens migrate one at a time
/// in wave 3; this is deleted in wave 4.
@Deprecated('Use PageHeader (04-shell §4). Removed in wave 4.')
class ScreenHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final EdgeInsets? padding;

  const ScreenHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.trailing,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return Container(
      padding: padding ?? Responsive.adaptivePadding(context),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: colors.border.withValues(alpha: 0.75)),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              size: SkotiqTokens.iconMd,
              color: colors.textSecondary,
            ),
            const SizedBox(width: SkotiqTokens.spaceMd),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: SkotiqTypography.h3.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: SkotiqTokens.spaceXs),
                  Text(
                    subtitle!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: SkotiqTypography.bodySm.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          // A Row hands non-flexed children unbounded width, so a Wrap of
          // actions placed here can never wrap — it overflows. Flexible
          // bounds the slot; a wide action cluster reflows onto extra rows.
          if (trailing != null)
            Flexible(
              child: Align(alignment: Alignment.topRight, child: trailing!),
            ),
        ],
      ),
    );
  }
}

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
