import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';
import 'skotiq_icon_button.dart';

/// The four banner tones.
enum BannerTone {
  /// Something the operator should know. Painted in `primary`.
  info,

  /// Something finished. Rare on a banner — success is usually silent.
  success,

  /// Something needs attention before the night can proceed.
  warning,

  /// Something failed.
  error,
}

/// An inline banner: ONE per problem, across the whole app.
///
/// `8 / 12` padding, `radiusSm`, a fill of the tone at
/// [SkotiqTokens.opacityHairline], a 16px icon in the tone, the [title] in
/// `bodySm` 600 `textPrimary` followed ON THE SAME LINE by [message] in
/// `bodySm` `textSecondary`, and at most one action plus an optional dismiss.
///
/// Never floating, never stacked, never a toast. A setup problem gets a banner
/// on the ONE surface that depends on it and a step in the Tonight checklist —
/// not a banner on every screen that could mention it.
class SkotiqBanner extends StatelessWidget {
  const SkotiqBanner({
    super.key,
    required this.title,
    this.message,
    this.tone = BannerTone.info,
    this.icon,
    this.action,
    this.onDismiss,
  });

  /// The problem, in one short sentence, in sentence case.
  final String title;

  /// One more sentence of detail, on the same line as [title].
  final String? message;

  /// The banner's tone.
  final BannerTone tone;

  /// Overrides the tone's default glyph.
  final IconData? icon;

  /// At most ONE action — a `secondary sm` or `primary sm` button.
  final Widget? action;

  /// Shows the dismiss `x` when non-null.
  final VoidCallback? onDismiss;

  /// Vertical padding.
  static const double verticalPadding = SkotiqTokens.spaceSm;

  /// Horizontal padding.
  static const double horizontalPadding = SkotiqTokens.spaceMd;

  /// The tone icon's size.
  static const double iconSize = SkotiqTokens.iconSm;

  /// Gap between the icon, the text and the actions.
  static const double gap = SkotiqTokens.spaceSm;

  /// The width below which the action drops onto its own line.
  ///
  /// A banner is a sentence with a button after it. Left in the same row on a
  /// phone the sentence is squeezed into a one-glyph-per-line column — measured
  /// at 430px on the Darkroom's branch-delete refusal, whose title laid out
  /// down a 6,395px column and took the editor off screen.
  static const double stackBelow = SkotiqTokens.breakpointMobile;

  IconData get _defaultIcon => switch (tone) {
    BannerTone.info => LucideIcons.info,
    BannerTone.success => LucideIcons.checkCircle2,
    BannerTone.warning => LucideIcons.alertTriangle,
    BannerTone.error => LucideIcons.xCircle,
  };

  Color _toneColor(SkotiqColors colors) => switch (tone) {
    BannerTone.info => colors.primary,
    BannerTone.success => colors.success,
    BannerTone.warning => colors.warning,
    BannerTone.error => colors.error,
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final toneColor = _toneColor(colors);

    final text = Text.rich(
      TextSpan(
        text: title,
        style: SkotiqTypography.bodySm.copyWith(
          color: colors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
        children: <InlineSpan>[
          if (message != null)
            TextSpan(
              text: ' $message',
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textSecondary,
                fontWeight: FontWeight.w400,
              ),
            ),
        ],
      ),
    );

    final actions = <Widget>[
      if (action != null) action!,
      if (onDismiss != null)
        SkotiqIconButton(
          icon: LucideIcons.x,
          tooltip: 'Dismiss',
          size: IconButtonSize.sm,
          onPressed: onDismiss,
        ),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(
        vertical: verticalPadding,
        horizontal: horizontalPadding,
      ),
      decoration: BoxDecoration(
        color: toneColor.withValues(alpha: SkotiqTokens.opacityHairline),
        borderRadius: SkotiqTokens.borderRadiusSm,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stacked =
              actions.isNotEmpty &&
              constraints.hasBoundedWidth &&
              constraints.maxWidth < stackBelow;

          final leading = Padding(
            // The glyph is taller than one line of 13px text, so it is nudged
            // down to sit on the first line rather than above it.
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon ?? _defaultIcon, size: iconSize, color: toneColor),
          );

          if (stacked) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                leading,
                const SizedBox(width: gap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      text,
                      const SizedBox(height: gap),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: <Widget>[
                          for (var i = 0; i < actions.length; i++) ...<Widget>[
                            if (i > 0) const SizedBox(width: gap - 2),
                            actions[i],
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              leading,
              const SizedBox(width: gap),
              Expanded(child: text),
              for (final widget in actions) ...<Widget>[
                const SizedBox(width: gap - 2),
                widget,
              ],
            ],
          );
        },
      ),
    );
  }
}
