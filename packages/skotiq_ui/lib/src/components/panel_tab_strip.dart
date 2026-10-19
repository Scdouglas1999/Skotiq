import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';
import '../utils/touch_target.dart';

/// The dot after a [PanelTabItem]'s label.
enum PanelTabBadge {
  none,

  /// Something is running on that tab (an autofocus, a solve).
  active,

  /// Something on that tab needs a look.
  alert,
}

/// One tab of a [PanelTabStrip].
@immutable
class PanelTabItem {
  const PanelTabItem(
    this.label, {
    this.badge = PanelTabBadge.none,
    this.semanticLabel,
  });

  final String label;
  final PanelTabBadge badge;

  /// What assistive technology reads instead of [label]. The badge is a
  /// colored dot with no words, so a caller that sets one should say here
  /// what it means, e.g. "Focus, autofocus running".
  final String? semanticLabel;

  @override
  bool operator ==(Object other) =>
      other is PanelTabItem &&
      other.label == label &&
      other.badge == badge &&
      other.semanticLabel == semanticLabel;

  @override
  int get hashCode => Object.hash(label, badge, semanticLabel);
}

/// The row of text tabs at the top of the Tonight side panel.
///
/// The strip is one stop in keyboard traversal, the way a tab list is: Tab
/// lands on it, Left and Right move the selection (wrapping at the ends),
/// Home and End jump to the first and last tab. Each tab is a button with its
/// selected state in semantics.
///
/// The tabs share the width. Each one gets its label's own width plus an
/// equal share of what is left, so a long label never ellipsizes while a
/// short one has room to spare; only when the labels together do not fit do
/// they shrink in proportion and ellipsize.
class PanelTabStrip extends StatelessWidget {
  const PanelTabStrip({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
    required this.semanticLabel,
  });

  final List<PanelTabItem> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  /// Names the strip, e.g. "Panel".
  final String semanticLabel;

  /// The strip's height with a pointer; on touch platforms the strip grows
  /// to the touch-target floor and the tabs stay centered in it.
  static const double height = 36;

  /// A tab's height, centered in the strip.
  static const double tabHeight = 26;

  /// The strip's horizontal padding.
  static const double horizontalPadding = SkotiqTokens.spaceSm;

  /// Gap between tabs.
  static const double gap = 2;

  /// A tab's horizontal padding around its label.
  static const double tabPadding = 4;

  /// The badge dot's diameter and its inset from the tab's bottom edge. The
  /// dot sits centered under the label rather than after it: six labels and
  /// two trailing dots did not fit a 300 px panel, and a dot below costs no
  /// width at all.
  static const double badgeSize = 4;
  static const double badgeInset = 2;

  /// Alpha of the selected tab's primary tint.
  static const double selectedAlpha = 0.18;

  /// The label style: [selected] in `textPrimary`, the rest `textMuted`.
  static TextStyle labelStyle(SkotiqColors colors, {required bool selected}) =>
      SkotiqTypography.labelStrongSm.copyWith(
        color: selected ? colors.textPrimary : colors.textMuted,
      );

  /// The selected tab's fill.
  static Color selectedFill(SkotiqColors colors) =>
      colors.primary.withValues(alpha: selectedAlpha);

  /// The badge dot's color, or null for [PanelTabBadge.none].
  static Color? badgeColor(PanelTabBadge badge, SkotiqColors colors) =>
      switch (badge) {
        PanelTabBadge.none => null,
        PanelTabBadge.active => colors.success,
        PanelTabBadge.alert => colors.warning,
      };

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (tabs.isEmpty) return KeyEventResult.ignored;
    final last = tabs.length - 1;
    final current = selectedIndex.clamp(0, last);
    final int next;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight) {
      next = current == last ? 0 : current + 1;
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      next = current == 0 ? last : current - 1;
    } else if (key == LogicalKeyboardKey.home) {
      next = 0;
    } else if (key == LogicalKeyboardKey.end) {
      next = last;
    } else {
      return KeyEventResult.ignored;
    }
    if (next != selectedIndex) onSelected(next);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: semanticLabel,
      child: Focus(
        onKeyEvent: _onKey,
        child: Builder(
          builder: (context) {
            final focused = Focus.of(context).hasPrimaryFocus;
            return SizedBox(
              height: SkotiqTouchTarget.minExtent(
                context,
                desktopExtent: height,
              ).clamp(height, double.infinity),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: horizontalPadding,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) => Row(
                    children: _buildTabs(
                      context,
                      colors,
                      constraints.maxWidth,
                      focused,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  List<Widget> _buildTabs(
    BuildContext context,
    SkotiqColors colors,
    double available,
    bool focused,
  ) {
    final scaler = MediaQuery.textScalerOf(context);
    final natural = <double>[
      for (var i = 0; i < tabs.length; i++)
        _naturalWidth(tabs[i], colors, scaler, selected: i == selectedIndex),
    ];
    final gaps = gap * (tabs.length - 1).clamp(0, tabs.length);
    final total = natural.fold<double>(0, (a, b) => a + b);
    final room = available - gaps;
    final widths = <double>[
      for (final w in natural)
        !room.isFinite
            ? w
            : room >= total
            ? w + (room - total) / tabs.length
            : w * (room / total).clamp(0.0, 1.0),
    ];

    return <Widget>[
      for (var i = 0; i < tabs.length; i++) ...<Widget>[
        if (i > 0) const SizedBox(width: gap),
        SizedBox(
          width: widths[i],
          child: _PanelTab(
            item: tabs[i],
            selected: i == selectedIndex,
            showFocus: focused && i == selectedIndex,
            colors: colors,
            onTap: () => onSelected(i),
          ),
        ),
      ],
    ];
  }

  static double _naturalWidth(
    PanelTabItem item,
    SkotiqColors colors,
    TextScaler scaler, {
    required bool selected,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: item.label,
        style: labelStyle(colors, selected: selected),
      ),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final label = painter.width;
    painter.dispose();
    // Rounded up: a width a fraction under the text's own ellipsizes it.
    return (label + 2 * tabPadding).ceilToDouble();
  }
}

class _PanelTab extends StatefulWidget {
  const _PanelTab({
    required this.item,
    required this.selected,
    required this.showFocus,
    required this.colors,
    required this.onTap,
  });

  final PanelTabItem item;
  final bool selected;
  final bool showFocus;
  final SkotiqColors colors;
  final VoidCallback onTap;

  @override
  State<_PanelTab> createState() => _PanelTabState();
}

class _PanelTabState extends State<_PanelTab> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final selected = widget.selected;
    final badge = PanelTabStrip.badgeColor(widget.item.badge, colors);
    final fill = selected
        ? PanelTabStrip.selectedFill(colors)
        : (_hovered ? colors.surfaceHover : null);

    return Semantics(
      button: true,
      // Semantics publishes isEnabled only when `enabled` is given; without it
      // AT-SPI announces a live tab as disabled (see AdaptiveTabBar).
      enabled: true,
      selected: selected,
      label: widget.item.semanticLabel ?? widget.item.label,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Center(
            child: Container(
              width: double.infinity,
              height: PanelTabStrip.tabHeight,
              padding: const EdgeInsets.symmetric(
                horizontal: PanelTabStrip.tabPadding,
              ),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: SkotiqTokens.borderRadiusLg,
              ),
              // A foreground ring, so showing focus never takes width from
              // the label.
              foregroundDecoration: widget.showFocus
                  ? BoxDecoration(
                      borderRadius: SkotiqTokens.borderRadiusLg,
                      border: Border.all(color: colors.primary),
                    )
                  : null,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  Text(
                    widget.item.label,
                    style: PanelTabStrip.labelStyle(
                      colors,
                      selected: selected || _hovered,
                    ),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (badge != null)
                    Positioned(
                      bottom: PanelTabStrip.badgeInset,
                      child: Container(
                        width: PanelTabStrip.badgeSize,
                        height: PanelTabStrip.badgeSize,
                        decoration: BoxDecoration(
                          color: badge,
                          shape: BoxShape.circle,
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
