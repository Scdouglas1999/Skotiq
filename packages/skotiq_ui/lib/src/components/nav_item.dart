import 'package:flutter/material.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_decorations.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';
import '../tokens/shell_chrome_metrics.dart';

/// One rail destination (04-shell §3.1).
///
/// 40 px tall in both states: a 40 x 40 square when the rail is collapsed, the
/// full rail width with a label when it is expanded. A short window passes
/// [height] ([ShellChromeMetrics.railItemSizeCompact]) so every item fits. Selection is tone, not a
/// left accent bar — the fill and the icon colour carry it, and a 2 px rule on
/// the leading edge is a line where the design language asks for tone.
class NavItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final bool isExpanded;
  final VoidCallback onTap;

  /// Draws the 7 px attention dot at the item's top-right corner.
  ///
  /// Equipment carries it while nothing is connected, Weather while conditions
  /// are unsafe. It is a marker, not a count: the number belongs on the screen
  /// the item leads to.
  final bool hasBadge;

  /// The item's height; the glyph keeps its size and stays centered.
  final double height;

  const NavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.isExpanded,
    required this.onTap,
    this.hasBadge = false,
    this.height = ShellChromeMetrics.railItemSize,
  });

  @override
  State<NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<NavItem> {
  bool _isHovered = false;

  static const double _iconSize = SkotiqTokens.iconRail;

  /// (40 - 18) / 2. Derived from the item and icon sizes so the glyph is
  /// optically centred in the collapsed rail; not a spacing token, and it
  /// stays correct if either size moves.
  static const double _iconInset =
      (ShellChromeMetrics.railItemSize - _iconSize) / 2;

  /// The badge's inset from the item's top-right corner.
  static const double _badgeInset = 8.0;
  static const double _badgeSize = 7.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;

    final foreground = widget.isSelected
        ? colors.primary
        : _isHovered
        ? colors.textPrimary
        : colors.textSecondary;

    return Semantics(
      // Semantics publishes isEnabled only when this field is given;
      // omitting it makes assistive tech announce a live control as
      // disabled. Measured on the running app 2026-08-09.
      enabled: true,
      button: true,
      selected: widget.isSelected,
      label: widget.label,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: widget.onTap,
            hoverColor: Colors.transparent,
            highlightColor: colors.primary.withValues(
              alpha: SkotiqTokens.opacityAccentTint,
            ),
            splashColor: colors.primary.withValues(
              alpha: SkotiqTokens.opacityAccentTint,
            ),
            borderRadius: SkotiqTokens.borderRadiusLg,
            child: AnimatedContainer(
              duration: SkotiqTokens.durationNormal,
              curve: SkotiqTokens.curveStandard,
              height: widget.height,
              decoration: widget.isSelected
                  ? SkotiqDecorations.railItemSelected(colors)
                  : BoxDecoration(
                      color: _isHovered
                          ? colors.surfaceHover
                          : Colors.transparent,
                      borderRadius: SkotiqTokens.borderRadiusLg,
                    ),
              // The Stack is the item's own box, so the badge's inset is
              // measured from the item's corner rather than from inside the
              // icon padding.
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  // Collapsed, the glyph is CENTRED rather than padded. The
                  // 11 px inset is a derivation of centring an 18 px glyph in
                  // a 40 px square, and stating it as padding makes the item
                  // demand exactly 40 px: the rail is 64 px INCLUDING its
                  // trailing hairline, so the row it lays out in is 63, and a
                  // padded item overflowed by exactly the 1 px the border
                  // takes. Centring lands the glyph in the same place and
                  // survives the shortfall.
                  if (!widget.isExpanded)
                    Center(
                      child: Icon(
                        widget.icon,
                        size: _iconSize,
                        color: foreground,
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: _iconInset,
                      ),
                      child: Row(
                        children: [
                          Icon(widget.icon, size: _iconSize, color: foreground),
                          const SizedBox(width: SkotiqTokens.spaceMd),
                          // The Semantics above already carries this word.
                          // Left to speak for itself the Text merges into
                          // that node and a screen reader says "Tonight
                          // Tonight"; excluded HERE rather than with
                          // `excludeSemantics` on the wrapper, which would
                          // also drop the InkWell's tap action and leave the
                          // destination visible but unactivatable.
                          Expanded(
                            child: ExcludeSemantics(
                              child: Text(
                                widget.label,
                                style: SkotiqTypography.button.copyWith(
                                  color: foreground,
                                ),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (widget.hasBadge)
                    Positioned(
                      top: _badgeInset,
                      right: _badgeInset,
                      child: Container(
                        width: _badgeSize,
                        height: _badgeSize,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: colors.warning,
                          // The ring is what stops the dot dissolving into a
                          // selected item's tinted fill.
                          border: Border.all(
                            color: colors.background,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
