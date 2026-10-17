import 'package:flutter/material.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_decorations.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';
import '../utils/touch_target.dart';
import 'status_dot.dart';

/// The semantic tones a chip, dot or instrument pill can take.
///
/// Status colours mean status. A filter, a count or a name is
/// [ChipTone.neutral]; [ChipTone.primary] is selection, not a sixth status.
enum ChipTone {
  /// Solid `surfaceHover` fill, `textSecondary` text. Counts, names, filters.
  neutral,

  /// Connected, done, safe.
  success,

  /// Attention, unsaved, session-only.
  warning,

  /// Failed, disconnected, stopped.
  error,

  /// Selection and links — never a status.
  primary;

  /// The tone's colour on [colors]. Null for [neutral], which has no tone: it
  /// takes the solid `surfaceHover` fill instead of a tint.
  Color? resolve(SkotiqColors colors) => switch (this) {
    ChipTone.neutral => null,
    ChipTone.success => colors.success,
    ChipTone.warning => colors.warning,
    ChipTone.error => colors.error,
    ChipTone.primary => colors.primary,
  };
}

/// A chip: a status pill, a count, a filter tag.
///
/// 22px tall, `0 8` padding, `radiusXs`, 12px medium text. A neutral chip is a
/// solid `surfaceHover` fill with `textSecondary` text; every other [tone] is
/// that colour at [SkotiqTokens.opacityStatusFill] with the text, the icon
/// and the [dot] all in the tone at full strength. A chip has no border — the
/// fill is its boundary.
///
/// When [onTap] is non-null the chip is a toggle and reflects [selected]. For a
/// pill in the instrument bar use `InstrumentPill`; for a control that opens a
/// menu use [SkotiqFilterChip].
class SkotiqChip extends StatelessWidget {
  const SkotiqChip({
    super.key,
    required this.label,
    this.icon,
    this.tone = ChipTone.neutral,
    this.dot = false,
    this.selected = false,
    this.onTap,
    this.enabled = true,
  });

  /// The chip's text.
  final String label;

  /// An optional leading icon, drawn at 12px in the tone colour.
  final IconData? icon;

  /// The chip's semantic tone.
  final ChipTone tone;

  /// Draws a leading 7px dot in the tone colour — for a chip that reports a
  /// connection or a run state rather than a count.
  final bool dot;

  /// Toggled state for an interactive chip. A selected chip takes the
  /// [ChipTone.primary] face whatever its resting tone.
  final bool selected;

  /// Non-null makes the chip a toggle button.
  final VoidCallback? onTap;

  /// Whether an option chip can be chosen right now.
  ///
  /// This is NOT the same state as `onTap == null`, which means "this chip is a
  /// status label and was never an option". A disabled chip is an option that
  /// exists but is currently unavailable, and it has to READ that way: it is
  /// dimmed, announced as a disabled button, and shows the not-allowed cursor.
  /// Expressing it with a null [onTap] instead renders a chip pixel-identical
  /// to an unselected one and tells a screen reader nothing.
  final bool enabled;

  /// The chip's fixed height in logical pixels.
  static const double height = 22;

  /// Horizontal padding.
  static const double horizontalPadding = SkotiqTokens.spaceSm;

  /// Gap between the dot/icon and the label.
  static const double innerGap = 6;

  /// The chip's text style: 12px at medium weight, per `observatory.css`
  /// `.chip`.
  static TextStyle textStyle() =>
      SkotiqTypography.caption.copyWith(fontWeight: FontWeight.w500);

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final effectiveTone = selected ? ChipTone.primary : tone;
    final toneColor = effectiveTone.resolve(colors);

    Color foreground = toneColor ?? colors.textSecondary;
    if (!enabled) {
      foreground = foreground.withValues(
        alpha: SkotiqTokens.opacityDisabled,
      );
    }

    final decoration = SkotiqDecorations.chip(colors, tone: toneColor);

    final chip = Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: horizontalPadding),
      decoration: enabled
          ? decoration
          : decoration.copyWith(
              color: decoration.color?.withValues(
                alpha: SkotiqTokens.opacityDisabled,
              ),
            ),
      // NO `alignment:` — a Container with an alignment EXPANDS to its
      // parent's constraints, which turned every chip in a Wrap into a
      // full-width bar. The fixed height plus a min-size Row is what centres
      // the content, and it leaves the chip its own width.
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (dot) ...<Widget>[
            StatusDot(color: foreground),
            const SizedBox(width: innerGap),
          ],
          if (icon != null) ...<Widget>[
            Icon(icon, size: _chipIconSize, color: foreground),
            const SizedBox(width: innerGap),
          ],
          Flexible(
            child: Text(
              label,
              style: textStyle().copyWith(color: foreground),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );

    if (onTap == null && enabled) {
      // A non-interactive chip is a status label; expose its text, but not a
      // button/selected role it cannot honour.
      return chip;
    }

    if (!enabled) {
      // Still announced as a button so assistive tech reports the option and
      // that it is unavailable, rather than reading a bare word with no role.
      return Semantics(
        button: true,
        enabled: false,
        selected: selected,
        label: label,
        child: SkotiqTouchTarget.hitBox(
          context,
          MouseRegion(
            cursor: SystemMouseCursors.forbidden,
            child: ExcludeSemantics(child: chip),
          ),
        ),
      );
    }

    // Announce the interactive chip as a toggle button and carry its
    // selected-state so a screen reader says e.g. "Confirmed, selected, button"
    // on the active filter — the `selected` flag drove only color before.
    return Semantics(
      button: true,
      // The disabled branch above passes `enabled: false`; this one has to
      // pass `enabled: true` explicitly, because `Semantics` publishes the
      // isEnabled flag only when the field is given. Omitting it made a live
      // chip announce exactly like the disabled one.
      enabled: true,
      selected: selected,
      label: label,
      // 22px is a POINTER size. A finger needs 48, so the interactive box
      // grows while the painted chip stays the height the sheet specifies —
      // the planner's "More" chip measured 112x28 in the Android tap-target
      // audit.
      child: SkotiqTouchTarget.hitBox(
        context,
        InkWell(
          onTap: onTap,
          borderRadius: SkotiqTokens.borderRadiusXs,
          child: ExcludeSemantics(child: chip),
        ),
      ),
    );
  }
}

/// Icon size inside a chip, in logical pixels (`observatory.css` `.chip .i`).
const double _chipIconSize = SkotiqTokens.iconChipGlyph;

/// Icon size inside a filter chip's trailing chevron.
const double _filterChipIconSize = SkotiqTokens.iconPillGlyph;

/// A filter chip: a CONTROL that opens a menu, not a readout.
///
/// 28px tall with the [SkotiqDecorations.filterChip] outline — an outline
/// is how an unselected control says it can be pressed, which is the one thing
/// a filled [SkotiqChip] cannot say.
class SkotiqFilterChip extends StatefulWidget {
  const SkotiqFilterChip({
    super.key,
    required this.label,
    this.onTap,
    this.icon,
    this.trailingIcon,
  });

  /// The chip's text, usually `Field: value`.
  final String label;

  /// Opens the menu. Null disables the chip.
  final VoidCallback? onTap;

  /// An optional leading icon at 13px.
  final IconData? icon;

  /// The trailing affordance. Defaults to a chevron supplied by the caller so
  /// this package does not depend on an icon set at the API boundary.
  final IconData? trailingIcon;

  /// The chip's fixed height in logical pixels.
  static const double height = 28;

  /// Horizontal padding.
  static const double horizontalPadding = 10;

  @override
  State<SkotiqFilterChip> createState() => _SkotiqFilterChipState();
}

class _SkotiqFilterChipState extends State<SkotiqFilterChip> {
  bool _hovered = false;

  void _setHovered(bool value) {
    if (!mounted || _hovered == value) return;
    setState(() => _hovered = value);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final disabled = widget.onTap == null;
    final foreground = disabled
        ? colors.textMuted.withValues(alpha: SkotiqTokens.opacityDisabled)
        : (_hovered ? colors.textPrimary : colors.textSecondary);

    final chip = Container(
      height: SkotiqFilterChip.height,
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqFilterChip.horizontalPadding,
      ),
      decoration: SkotiqDecorations.filterChip(
        colors,
      ).copyWith(color: _hovered && !disabled ? colors.surfaceHover : null),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (widget.icon != null) ...<Widget>[
            Icon(widget.icon, size: _filterChipIconSize, color: foreground),
            const SizedBox(width: SkotiqChip.innerGap),
          ],
          Flexible(
            child: Text(
              widget.label,
              style: SkotiqTypography.bodySm.copyWith(color: foreground),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (widget.trailingIcon != null) ...<Widget>[
            const SizedBox(width: SkotiqChip.innerGap),
            Icon(
              widget.trailingIcon,
              size: _filterChipIconSize,
              color: foreground,
            ),
          ],
        ],
      ),
    );

    return Semantics(
      button: true,
      enabled: !disabled,
      label: widget.label,
      child: SkotiqTouchTarget.hitBox(
        context,
        MouseRegion(
          onEnter: (_) => _setHovered(true),
          onExit: (_) => _setHovered(false),
          cursor: disabled
              ? SystemMouseCursors.forbidden
              : SystemMouseCursors.click,
          child: GestureDetector(
            onTap: widget.onTap,
            child: ExcludeSemantics(child: chip),
          ),
        ),
      ),
    );
  }
}
