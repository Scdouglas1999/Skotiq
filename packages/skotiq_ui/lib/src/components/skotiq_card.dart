import 'package:flutter/material.dart';
import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';

/// Card variant for different use cases
enum CardVariant {
  /// Standard card with surface background
  standard,

  /// Elevated card with stronger border contrast
  elevated,

  /// Subtle card with minimal styling
  subtle,
}

class SkotiqCard extends StatefulWidget {
  final Widget child;
  final EdgeInsets? padding;
  final Color? backgroundColor;
  final double borderRadius;
  final VoidCallback? onTap;
  final bool enableHover;
  final bool isSelected;
  final CardVariant variant;

  const SkotiqCard({
    super.key,
    required this.child,
    this.padding,
    this.backgroundColor,
    this.borderRadius = SkotiqTokens.radiusMd,
    this.onTap,
    this.enableHover = false,
    this.isSelected = false,
    this.variant = CardVariant.standard,
  });

  @override
  State<SkotiqCard> createState() => _SkotiqCardState();
}

class _SkotiqCardState extends State<SkotiqCard> {
  bool _isHovered = false;
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final shouldAnimate = widget.enableHover || widget.onTap != null;

    final baseBackground =
        widget.backgroundColor ??
        switch (widget.variant) {
          CardVariant.standard => colors.surfaceAlt,
          CardVariant.elevated => colors.surfaceElevated,
          CardVariant.subtle => colors.surface,
        };

    final backgroundColor = widget.isSelected
        ? Color.alphaBlend(
            colors.primary.withValues(alpha: 0.04),
            baseBackground,
          )
        : _isHovered && shouldAnimate
        ? colors.surfaceHover
        : baseBackground;

    final borderColor = widget.isSelected
        ? colors.primary.withValues(alpha: 0.45)
        : _isHovered && shouldAnimate
        ? colors.borderHighlight.withValues(alpha: 0.85)
        : colors.border.withValues(alpha: 0.55);

    Widget content = widget.child;
    if (widget.padding != null) {
      content = Padding(padding: widget.padding!, child: content);
    }

    final card = MouseRegion(
      onEnter: shouldAnimate ? (_) => setState(() => _isHovered = true) : null,
      onExit: shouldAnimate ? (_) => setState(() => _isHovered = false) : null,
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: SkotiqTokens.durationNormal,
          curve: SkotiqTokens.curveSnappy,
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(widget.borderRadius),
            border: Border.all(color: borderColor),
          ),
          clipBehavior: Clip.antiAlias,
          child: content,
        ),
      ),
    );

    // Most cards are layout containers. Only a card that was given an onTap is a
    // control, and only that one should take a tab stop or announce itself as a
    // button -- otherwise keyboard traversal would stop on every panel in the
    // app before reaching anything operable.
    if (widget.onTap == null) return card;

    return Semantics(
      // Semantics publishes isEnabled only when this field is given;
      // omitting it makes assistive tech announce a live control as
      // disabled. Measured on the running app 2026-08-09.
      enabled: true,
      button: true,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (focused) => setState(() => _isFocused = focused),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap!();
              return null;
            },
          ),
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius + 2),
            border: Border.all(
              color: _isFocused ? colors.primary : Colors.transparent,
              width: 2,
            ),
          ),
          child: card,
        ),
      ),
    );
  }
}
