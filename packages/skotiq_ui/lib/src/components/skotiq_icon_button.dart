import '../theme/skotiq_control_styles.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../utils/touch_target.dart';
import 'skotiq_tooltip.dart';

/// The three icon-button sizes.
enum IconButtonSize {
  /// 32 — top bar, page header, capture bar.
  md,

  /// 28 — toolbars.
  sm,

  /// 36 — the side-panel section strip.
  strip,
}

/// A square, ghost-styled icon button — the ONE icon control in the app.
///
/// [tooltip] is required, not optional. An icon with no words is only legible
/// to someone who already knows what it does; making the tooltip part of the
/// constructor is what stops the next 178 `IconButton(` migrations from
/// shipping unlabelled glyphs, and it doubles as the semantics label so the
/// control has a name in the accessibility tree as well as under the pointer.
class SkotiqIconButton extends StatefulWidget {
  const SkotiqIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.size = IconButtonSize.md,
    this.selected = false,
    this.color,
    this.tooltipPosition,
  });

  /// The glyph. Lucide only — never `Icons.*`.
  final IconData icon;

  /// What the button does, in sentence case. Shown on hover and published as
  /// the control's accessible name.
  final String tooltip;

  /// Null disables the button (40% opacity, no colour change).
  final VoidCallback? onPressed;

  /// Which of the three square sizes to draw.
  final IconButtonSize size;

  /// Selected: `primary` at [SkotiqTokens.opacityAccentTint] fill and a
  /// `primary` glyph.
  final bool selected;

  /// Overrides the resting glyph colour — a `destructive` action, a status
  /// tint. Hover and selection still apply on top.
  final Color? color;

  /// Where the hover label sits relative to the square.
  ///
  /// Strip buttons default to [SkotiqTooltipPosition.left]: they live on
  /// the right edge of a side panel, and a `top` label is clamped off that
  /// edge so it no longer points at the icon. Everything else defaults to
  /// [SkotiqTooltipPosition.top].
  final SkotiqTooltipPosition? tooltipPosition;

  /// The button's edge length in logical pixels.
  double get extent => switch (size) {
    IconButtonSize.md => SkotiqTokens.iconButtonSize,
    IconButtonSize.sm => SkotiqTokens.iconButtonSizeSm,
    IconButtonSize.strip => SkotiqTokens.iconButtonSizeStrip,
  };

  /// The glyph size in logical pixels.
  double get iconSize => switch (size) {
    IconButtonSize.md => _iconButtonGlyphMd,
    IconButtonSize.sm => _iconButtonGlyphSm,
    IconButtonSize.strip => _iconButtonGlyphStrip,
  };

  @override
  State<SkotiqIconButton> createState() => _SkotiqIconButtonState();
}

/// Glyph sizes inside an icon button, in logical pixels (`observatory.css`
/// `.iconbtn .i` 17, `.btn .i` 15, `.sidepanel .strip .item .i` 17).
const double _iconButtonGlyphMd = SkotiqTokens.iconGlyphMd;
const double _iconButtonGlyphSm = SkotiqTokens.iconGlyphSm;
const double _iconButtonGlyphStrip = SkotiqTokens.iconGlyphStrip;

class _SkotiqIconButtonState extends State<SkotiqIconButton> {
  bool _hovered = false;
  bool _focused = false;

  void _setHovered(bool value) {
    if (!mounted || _hovered == value) return;
    setState(() => _hovered = value);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final disabled = widget.onPressed == null;

    final states = <WidgetState>{
      if (disabled) WidgetState.disabled,
      if (_hovered) WidgetState.hovered,
      if (widget.selected) WidgetState.selected,
    };
    final foreground = SkotiqControlStyles.iconForeground(
      colors,
      states,
      override: widget.color,
    );
    final fill = SkotiqControlStyles.iconFill(colors, states);

    // The BOX is a SizedBox and the FILL is the animated part. Animating the
    // width and height instead would make a size change tween — and a size is
    // not a state, it is what this button is.
    final Widget square = SizedBox(
      width: widget.extent,
      height: widget.extent,
      child: AnimatedContainer(
        duration: SkotiqTokens.durationFast,
        curve: SkotiqTokens.curveStandard,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: SkotiqTokens.borderRadiusSm,
          border: Border.all(
            color: _focused && !disabled ? colors.primary : Colors.transparent,
          ),
        ),
        alignment: Alignment.center,
        child: Icon(widget.icon, size: widget.iconSize, color: foreground),
      ),
    );

    // 32 / 28 / 36 are desktop pointer sizes (03 §3.3). On a touch platform a
    // finger needs 48, so the INTERACTIVE box grows to it while the painted
    // square — the fill, the hover, the focus ring — stays the size the sheet
    // specifies. `SkotiqButton` already does exactly this; this control
    // was the one that did not, and it failed the Android tap-target
    // guideline on every screen that adopted it.
    final double box = math.max(
      widget.extent,
      SkotiqTouchTarget.minExtent(context),
    );
    final Widget button = box == widget.extent
        ? square
        : SizedBox(
            width: box,
            height: box,
            child: Center(child: square),
          );

    return Semantics(
      // Own node: without `container` the name and flags merge into the
      // neighbouring semantics node (a dialog title swallowed its close
      // button's label), which un-names every icon button for a screen reader.
      container: true,
      button: true,
      enabled: !disabled,
      label: widget.tooltip,
      // `find.byTooltip` is the finder every Flutter test reaches for, and it
      // matches a Material `Tooltip` — not this control's own
      // `SkotiqTooltip`, which is an OverlayPortal that exists only while
      // the pointer is over the button. So the 178 icon controls wave 3
      // migrated went invisible to it, and each screen grew a local
      // `findByTooltip` helper that knew about both.
      //
      // The `Tooltip` below is a LABEL, not a second tooltip: `TooltipVisibility`
      // stops it building any overlay of its own, and `excludeFromSemantics`
      // keeps it out of the accessibility tree, where the `Semantics` above
      // already publishes the same string as this button's name. What it does
      // carry is the message, on the widget the standard finder looks for. It
      // sits INSIDE the `Semantics` so that node stays this button's outermost
      // one, which is what `tester.getSemantics` walks to.
      child: TooltipVisibility(
        visible: false,
        child: Tooltip(
          message: widget.tooltip,
          excludeFromSemantics: true,
          child: SkotiqTooltip(
            message: widget.tooltip,
            position:
                widget.tooltipPosition ??
                (widget.size == IconButtonSize.strip
                    ? SkotiqTooltipPosition.left
                    : SkotiqTooltipPosition.top),
            child: MouseRegion(
              onEnter: (_) => _setHovered(true),
              onExit: (_) => _setHovered(false),
              cursor: disabled
                  ? SystemMouseCursors.basic
                  : SystemMouseCursors.click,
              child: FocusableActionDetector(
                enabled: !disabled,
                onShowFocusHighlight: (value) {
                  if (!mounted || _focused == value) return;
                  setState(() => _focused = value);
                },
                actions: <Type, Action<Intent>>{
                  ActivateIntent: CallbackAction<ActivateIntent>(
                    onInvoke: (_) {
                      widget.onPressed?.call();
                      return null;
                    },
                  ),
                  ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
                    onInvoke: (_) {
                      widget.onPressed?.call();
                      return null;
                    },
                  ),
                },
                // Every tap callback is dropped when disabled, not just onTap: a
                // GestureDetector that keeps one wired publishes a live tap action
                // beside a correct isEnabled=false flag, which the Linux AT-SPI
                // bridge reports as an enabled button.
                child: GestureDetector(
                  onTap: disabled ? null : widget.onPressed,
                  child: ExcludeSemantics(child: button),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
