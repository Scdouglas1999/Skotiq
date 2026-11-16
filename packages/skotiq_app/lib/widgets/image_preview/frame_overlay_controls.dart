// The pills and buttons drawn over a frame: what the frame is and what is
// happening, and the view toggles. Tonight's stage and the saved-frame viewer
// share them so the two read the same.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../localization/skotiq_localizations.dart';

/// The tone of a pill's dot or status.
enum FramePillTone { neutral, good, bad, muted, active }

/// One line of pill copy.
class FramePillText {
  const FramePillText({
    required this.title,
    this.time,
    this.status,
    this.statusTone = FramePillTone.neutral,
    this.dot = FramePillTone.muted,
    this.mono,
  });

  final String title;
  final String? time;
  final String? status;
  final FramePillTone statusTone;
  final FramePillTone dot;

  /// A trailing value in the mono face ("HFR 2.08", "72 / 180 s").
  final String? mono;
}

/// What the star overlay found on a frame: still looking, failed, none, or
/// the count and median HFR.
FramePillText starOverlayPill(
  SkotiqLocalizations l10n,
  AsyncValue<StarDetectionResult?> stars,
) {
  return stars.when(
    loading: () => FramePillText(
      title: l10n.text('nightCtrStarsFinding'),
      dot: FramePillTone.active,
    ),
    error: (_, __) => FramePillText(
      title: l10n.text('nightCtrStarsFailed'),
      dot: FramePillTone.bad,
    ),
    data: (result) {
      if (result == null) {
        return FramePillText(title: l10n.text('nightCtrStarsNoFile'));
      }
      if (result.stars.isEmpty) {
        return FramePillText(title: l10n.text('nightCtrStarsNone'));
      }
      final hfr = result.medianHfr;
      return FramePillText(
        title: result.stars.length == 1
            ? l10n.text('nightCtrStarsFoundOne')
            : l10n.text(
                'nightCtrStarsFound',
                params: <String, String>{'count': '${result.stars.length}'},
              ),
        dot: FramePillTone.good,
        mono: hfr > 0 && hfr.isFinite
            ? l10n.text(
                'nightCtrHfrValue',
                params: <String, String>{'hfr': hfr.toStringAsFixed(2)},
              )
            : null,
      );
    },
  );
}

class FramePill extends StatelessWidget {
  const FramePill({super.key, required this.text, this.liveRegion = false});

  final FramePillText text;
  final bool liveRegion;

  Color _tone(SkotiqColors colors, FramePillTone tone) => switch (tone) {
        FramePillTone.neutral => colors.textSecondary,
        FramePillTone.good => colors.success,
        FramePillTone.bad => colors.error,
        FramePillTone.muted => colors.textMuted,
        FramePillTone.active => colors.warning,
      };

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final spans = <InlineSpan>[
      TextSpan(
        text: text.title,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: colors.textPrimary,
        ),
      ),
      if (text.time != null)
        TextSpan(
          text: '   ${text.time}',
          style: TextStyle(color: colors.textMuted),
        ),
      if (text.mono != null)
        TextSpan(
          text: '   ${text.mono}',
          style: SkotiqTypography.withTabular(
            SkotiqTypography.monoSm.copyWith(color: colors.textPrimary),
          ),
        ),
      if (text.status != null)
        TextSpan(
          text: '   ${text.status}',
          style: TextStyle(color: _tone(colors, text.statusTone)),
        ),
    ];
    return Semantics(
      liveRegion: liveRegion,
      container: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: colors.surface.withValues(alpha: 0.86),
          borderRadius: SkotiqTokens.borderRadiusFull,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: _tone(colors, text.dot),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Flexible(
              child: Text.rich(
                TextSpan(children: spans),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class FrameViewButton extends StatelessWidget {
  const FrameViewButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.tooltip,
    this.icon,
    this.selected,
  });

  final String label;
  final String? tooltip;
  final IconData? icon;

  /// Null shows the button dimmed and inert.
  final VoidCallback? onPressed;

  /// A toggle's state; null for a plain button.
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final on = selected == true;
    final enabled = onPressed != null;
    final button = Semantics(
      button: true,
      enabled: enabled,
      toggled: selected,
      label: label,
      hint: tooltip,
      excludeSemantics: true,
      child: Material(
        color: on
            ? colors.primary.withValues(alpha: SkotiqTokens.opacityStrong)
            : colors.surface.withValues(alpha: 0.86),
        // An on toggle keeps its outline under the pointer: the hover wash
        // alone read as off right after the click that turned it on.
        shape: RoundedRectangleBorder(
          borderRadius: SkotiqTokens.borderRadiusLg,
          side: on
              ? BorderSide(
                  color: colors.primary.withValues(
                    alpha: SkotiqTokens.opacitySelectedRing,
                  ),
                )
              : BorderSide.none,
        ),
        child: InkWell(
          onTap: onPressed,
          borderRadius: SkotiqTokens.borderRadiusLg,
          hoverColor: colors.textPrimary.withValues(
            alpha: SkotiqTokens.opacitySubtle,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 26),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              child: Opacity(
                opacity: enabled ? 1 : SkotiqTokens.opacityDisabled,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      label,
                      style: SkotiqTypography.captionSm.copyWith(
                        color: on ? colors.textPrimary : colors.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (icon != null) ...<Widget>[
                      const SizedBox(width: SkotiqTokens.spaceXs),
                      Icon(icon, size: 12, color: colors.textSecondary),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final tip = tooltip;
    if (tip == null) return button;
    return Tooltip(message: tip, excludeFromSemantics: true, child: button);
  }
}
