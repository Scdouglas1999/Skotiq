import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_decorations.dart';
import '../theme/skotiq_icons.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';
import '../utils/touch_target.dart';
import 'skotiq_chip.dart';

/// One tab in an [AdaptiveTabBar].
@immutable
class AdaptiveTab {
  /// Visible label. On very narrow viewports it may be hidden in favour of the
  /// [icon] (see [AdaptiveTabBar.collapseLabelsWhenTight]).
  final String label;

  /// Optional leading icon. Recommended so the tab stays meaningful when the
  /// label collapses on a compact phone.
  final IconData? icon;

  /// Optional accessibility / tooltip override. Falls back to [label].
  final String? semanticLabel;

  /// Optional key forwarded to the rendered tab button (e.g. tutorial keys).
  final Key? buttonKey;

  /// An optional count shown after the label in an 18px chip — "History 3".
  final String? count;

  const AdaptiveTab({
    required this.label,
    this.icon,
    this.semanticLabel,
    this.buttonKey,
    this.count,
  });
}

/// A horizontal tab control that never overflows — the ONE tab style.
///
/// Tabs lay out left-to-right with a 24px gap and no fill, no border and no
/// pill: the selected tab is marked by a 2px `primary` bar under it and by its
/// ink stepping up to `textPrimary`. When they do not fit the available width
/// the bar becomes **horizontally scrollable** instead of throwing a
/// `RenderFlex` overflow; the selected tab is kept on screen.
///
/// ```dart
/// AdaptiveTabBar(
///   tabs: const [
///     AdaptiveTab(label: 'Session', icon: LucideIcons.activity),
///     AdaptiveTab(label: 'History', icon: LucideIcons.history),
///   ],
///   selectedIndex: _tab,
///   onSelected: (i) => setState(() => _tab = i),
/// )
/// ```
class AdaptiveTabBar extends StatefulWidget {
  /// The tabs, in display order.
  final List<AdaptiveTab> tabs;

  /// Index of the currently selected tab.
  final int selectedIndex;

  /// Called with the tapped tab's index.
  final ValueChanged<int> onSelected;

  /// When true (default) and the viewport is a compact phone, tabs that have an
  /// [AdaptiveTab.icon] drop their text label to save width (the label remains
  /// available as a tooltip / semantics). Tabs without an icon keep their text.
  final bool collapseLabelsWhenTight;

  /// Optional trailing widgets pinned after the tabs (e.g. an overflow action).
  /// They scroll with the tabs.
  final List<Widget> trailing;

  /// Horizontal inset before the first tab and after the last trailing widget.
  final double horizontalPadding;

  const AdaptiveTabBar({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
    this.collapseLabelsWhenTight = true,
    this.trailing = const [],
    this.horizontalPadding = SkotiqTokens.spaceLg,
  });

  /// Gap between tabs (05 §4: `space2xl`).
  static const double tabGap = SkotiqTokens.space2xl;

  /// Horizontal padding INSIDE a tab. The selected indicator spans the label
  /// plus this much on each side, so a label-only tab's underline measures
  /// `labelWidth + 2 * tabPadding`.
  static const double tabPadding = 2;

  /// Thickness of the selected indicator.
  static const double indicatorThickness = 2;

  @override
  State<AdaptiveTabBar> createState() => _AdaptiveTabBarState();
}

class _AdaptiveTabBarState extends State<AdaptiveTabBar> {
  final ScrollController _scrollController = ScrollController();
  final List<GlobalKey> _tabKeys = [];

  /// Whether there are tabs hidden past each edge. Drives the fade + chevron
  /// affordance: without it, a strip that clips (e.g. six labelled planner tabs
  /// at a 900px window) looked exactly like a strip that fits, so two tabs were
  /// effectively invisible to a desktop user.
  bool _canScrollLeft = false;
  bool _canScrollRight = false;

  @override
  void initState() {
    super.initState();
    _syncKeys();
    _scrollController.addListener(_updateEdgeAffordances);
  }

  void _updateEdgeAffordances() {
    if (!mounted || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    // A hair of tolerance: sub-pixel layout leaves ~0.001px of extent that
    // would otherwise flicker the affordance on and off.
    final left = position.pixels > position.minScrollExtent + 0.5;
    final right = position.pixels < position.maxScrollExtent - 0.5;
    if (left == _canScrollLeft && right == _canScrollRight) return;
    setState(() {
      _canScrollLeft = left;
      _canScrollRight = right;
    });
  }

  /// Scroll by roughly one tab-group so a click on the chevron makes visible
  /// progress without skipping past a tab.
  void _nudge(double direction) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final target = (position.pixels + direction * 160.0).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    _scrollController.animateTo(
      target,
      duration: SkotiqTokens.durationQuick,
      curve: SkotiqTokens.curveSnappy,
    );
  }

  /// A plain vertical mouse wheel over a horizontal strip does nothing in
  /// Flutter by default, and mouse DRAG is excluded from `dragDevices`, so on
  /// desktop the only way to reach a clipped tab was shift+scroll — which
  /// nothing on screen advertised. Translate vertical wheel deltas into
  /// horizontal scrolling. Horizontal deltas are left alone: the Scrollable
  /// already consumes those, and handling them here would double-scroll.
  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (event.scrollDelta.dx != 0 || event.scrollDelta.dy == 0) return;
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.maxScrollExtent <= 0) return;
    final target = (position.pixels + event.scrollDelta.dy).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target == position.pixels) return;
    _scrollController.jumpTo(target);
  }

  @override
  void didUpdateWidget(AdaptiveTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncKeys();
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _ensureSelectedVisible(),
      );
    }
  }

  void _syncKeys() {
    if (_tabKeys.length == widget.tabs.length) return;
    _tabKeys
      ..clear()
      ..addAll(List.generate(widget.tabs.length, (_) => GlobalKey()));
  }

  /// Bring the selected tab into view WITHOUT disturbing anything the bar is
  /// sitting inside.
  ///
  /// `Scrollable.ensureVisible` walks every ancestor `Scrollable` and scrolls
  /// each one, which is wrong for a strip that is hosted inside other
  /// scrollables. In the sequencer the inspector's Settings/Activity/Notes bar
  /// lives inside the screen's `TabBarView` pager: selecting Activity scrolled
  /// that pager ~29 px toward the next (lazily empty) page and its page physics
  /// sprang it back, so the whole screen bounced left and revealed blank space
  /// on the right. Scrolling this bar's OWN position leaves the hosts alone —
  /// `ScrollPosition.ensureVisible` resolves the nearest enclosing viewport,
  /// which is this strip's, and applies the offset to this position only.
  void _ensureSelectedVisible() {
    if (!mounted || !_scrollController.hasClients) return;
    final index = widget.selectedIndex;
    if (index < 0 || index >= _tabKeys.length) return;
    final keyContext = _tabKeys[index].currentContext;
    if (keyContext == null) return;
    final target = keyContext.findRenderObject();
    if (target == null || !target.attached) return;
    _scrollController.position.ensureVisible(
      target,
      alignment: 0.5,
      duration: SkotiqTokens.durationQuick,
      curve: SkotiqTokens.curveSnappy,
    );
  }

  @override
  void dispose() {
    _scrollController.removeListener(_updateEdgeAffordances);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // This bar frequently lives inside a split pane. MediaQuery reports
        // the whole window, which made a 320px side panel render the wide
        // labelled variant on a landscape phone and pushed later tabs
        // offscreen. Respond to the space the bar actually receives.
        final availableWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final collapseLabels =
            widget.collapseLabelsWhenTight && availableWidth < 480.0;

        // Recheck after layout so the affordance is right on the very first
        // frame (the controller has no clients until then).
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _updateEdgeAffordances(),
        );

        final strip = Listener(
          onPointerSignal: _handlePointerSignal,
          child: SingleChildScrollView(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: widget.horizontalPadding,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                // The underline sits at the BOTTOM of the row that hosts the
                // bar (the 56px page header), so the tabs stretch to it when
                // the height is known. Where it is not — a bar dropped into a
                // Column with no height of its own — stretching would throw,
                // so the tabs fall back to their own intrinsic height and the
                // underline sits directly under the label.
                crossAxisAlignment: constraints.hasBoundedHeight
                    ? CrossAxisAlignment.stretch
                    : CrossAxisAlignment.center,
                children: [
                  for (var i = 0; i < widget.tabs.length; i++) ...[
                    if (i > 0) const SizedBox(width: AdaptiveTabBar.tabGap),
                    _AdaptiveTabButton(
                      key: _tabKeys.length > i ? _tabKeys[i] : null,
                      buttonKey: widget.tabs[i].buttonKey,
                      tab: widget.tabs[i],
                      isSelected: i == widget.selectedIndex,
                      hideLabel: collapseLabels && widget.tabs[i].icon != null,
                      onTap: () => widget.onSelected(i),
                    ),
                  ],
                  ...widget.trailing,
                ],
              ),
            ),
          ),
        );

        if (!_canScrollLeft && !_canScrollRight) return strip;

        // The chevrons are laid out BESIDE the strip, not `Positioned` over
        // it: over the strip they reserve no width and paint on top of the tab
        // labels they are hinting about, clipping them mid-word.
        //
        // Stable by construction: showing a chevron narrows the viewport,
        // which can only make the strip MORE scrollable; hiding one at an end
        // widens it and clamps the offset to the (smaller) new extent, which
        // leaves that edge still at its stop.
        return Row(
          children: [
            if (_canScrollLeft)
              _EdgeAffordance(onTap: () => _nudge(-1), isLeading: true),
            Expanded(child: strip),
            if (_canScrollRight)
              _EdgeAffordance(onTap: () => _nudge(1), isLeading: false),
          ],
        );
      },
    );
  }
}

/// Android's minimum touch-target edge, in logical pixels.
///
/// Named rather than inlined so the reason survives: this is the number
/// `mobile_tap_target_test` enforces, and the edge affordance failed it.
const double _kMinTapTarget = 48.0;

/// Chevron button shown over an edge that has more tabs behind it.
///
/// A tinted chip rather than a gradient fade on purpose: hosts put this bar on
/// `surface` (sequencer, flat wizard, guiding) *and* on `surfaceAlt` (planner,
/// analytics, science), so any fade colour hard-coded here would show as a band
/// of the wrong shade on half of them. A bordered chip reads as a control on
/// either background.
class _EdgeAffordance extends StatelessWidget {
  final VoidCallback onTap;
  final bool isLeading;

  const _EdgeAffordance({required this.onTap, required this.isLeading});

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    // Laid out beside the strip (not positioned over it) — see the Row in
    // `_AdaptiveTabBarState.build`. The tap target keeps its full width so the
    // 48 dp minimum still holds.
    // The TAP TARGET and the CHIP are deliberately different sizes.
    //
    // The chip stays 24x30 — it is a hint beside the strip, and growing it
    // visually would waste width the tabs need. But the interactive area was
    // the same 24x30, which is well under the 48 dp Android minimum and failed
    // `mobile_tap_target_test` on a 360x640 phone ("analytics @ small 360x640
    // has 1 tap target(s) under 48.0dp: 24.0x30.0"). Undersized targets are a
    // real touch failure, not a lint: this one sits at the very edge of the
    // screen, where thumbs are least accurate.
    //
    // So the InkWell fills [_kMinTapTarget] of width with the chip centred
    // inside it as pure decoration.
    return ConstrainedBox(
      // Width AND height: laid out in a Row the affordance does not inherit the
      // strip's height, and a 48x30 target fails the Android 48 dp rule
      // (`mobile_tap_target_test`).
      constraints: const BoxConstraints(
        minWidth: _kMinTapTarget,
        maxWidth: _kMinTapTarget,
        minHeight: _kMinTapTarget,
      ),
      child: Semantics(
        button: true,
        // `Semantics` only publishes SemanticsFlag.isEnabled when `enabled` is
        // given. A button declared without it carries no enabled flag at all,
        // and AT-SPI reads the absence as "not sensitive", so assistive tech
        // announces a live control as disabled.
        enabled: true,
        label: isLeading ? 'Scroll tabs left' : 'Scroll tabs right',
        child: Tooltip(
          message: 'More tabs',
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: _kMinTapTarget,
              // Height is unconstrained on purpose: the Row stretches this to
              // the strip's full height, so the target grows with the bar
              // instead of being pinned to 30.
              child: Center(
                child: Material(
                  color: colors.surfaceHover,
                  shape: RoundedRectangleBorder(
                    borderRadius: SkotiqTokens.borderRadiusMd,
                    side: BorderSide(color: colors.border),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: SizedBox(
                    width: 24,
                    height: 30,
                    child: Center(
                      child: Icon(
                        isLeading
                            ? SkotiqIcons.chevronLeft
                            : SkotiqIcons.chevronRight,
                        size: 16,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AdaptiveTabButton extends StatefulWidget {
  final AdaptiveTab tab;
  final bool isSelected;
  final bool hideLabel;
  final VoidCallback onTap;
  final Key? buttonKey;

  const _AdaptiveTabButton({
    super.key,
    required this.tab,
    required this.isSelected,
    required this.hideLabel,
    required this.onTap,
    this.buttonKey,
  });

  @override
  State<_AdaptiveTabButton> createState() => _AdaptiveTabButtonState();
}

class _AdaptiveTabButtonState extends State<_AdaptiveTabButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final tab = widget.tab;

    // Ink is the only thing that changes between rest, hover and selection:
    // no fill, no border, no pill. The bar underneath carries the selection.
    final Color foreground;
    if (widget.isSelected) {
      foreground = colors.textPrimary;
    } else if (_isHovered) {
      foreground = colors.textSecondary;
    } else {
      foreground = colors.textMuted;
    }

    final showLabel = !widget.hideLabel;

    Widget content = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AdaptiveTabBar.tabPadding,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (tab.icon != null)
            Icon(tab.icon, size: _tabIconSize, color: foreground),
          if (tab.icon != null && showLabel) const SizedBox(width: _tabIconGap),
          if (showLabel)
            Text(
              tab.label,
              style: SkotiqTypography.button.copyWith(color: foreground),
            ),
          if (tab.count != null) ...[
            const SizedBox(width: _tabIconGap),
            _TabCount(count: tab.count!, tone: foreground),
          ],
        ],
      ),
    );

    if (!showLabel) {
      content = Tooltip(message: tab.label, child: content);
    }

    return Semantics(
      button: true,
      // Measured on the running app during the GUI drive 2026-08-09: the
      // sequencer's four tabs came off the accessibility tree as
      // `Builder [DISABLED]`, `Templates [DISABLED]`, `Sequences [DISABLED]`,
      // `History [DISABLED]` — every one of them live and clickable. Fifteen
      // controls on that one screen carried the same false flag.
      //
      // `Semantics` publishes SemanticsFlag.isEnabled ONLY when `enabled` is
      // passed; `button: true` alone leaves the flag unset, and AT-SPI treats
      // an interactive node with no enabled/sensitive state as disabled. The
      // `onTap` is non-nullable on this button, so the control is always live.
      enabled: true,
      selected: widget.isSelected,
      label: tab.semanticLabel ?? tab.label,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: widget.buttonKey,
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Stack(
            children: [
              // A tab's 2px padding is a DESKTOP measurement: an icon-only tab
              // collapsed on a phone is 19px wide inside it, well under the
              // 48dp Android minimum, and `mobile_tap_target_test` counts it.
              // The floor is applied only on touch platforms, so a pointer
              // keeps the dense strip the header was designed around.
              ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: SkotiqTouchTarget.minExtent(context),
                  minHeight: SkotiqTouchTarget.minExtent(
                    context,
                    desktopExtent: _tabMinHeight,
                  ),
                ),
                child: Center(widthFactor: 1, child: content),
              ),
              // The indicator spans the tab's whole box — the label plus its
              // 2px padding on each side — with square corners, and sits at the
              // bottom of whatever height the tab was given.
              if (widget.isSelected)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: Container(
                      height: AdaptiveTabBar.indicatorThickness,
                      color: colors.primary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The 18px count chip that may follow a tab label.
class _TabCount extends StatelessWidget {
  const _TabCount({required this.count, required this.tone});

  final String count;
  final Color tone;

  /// The chip's height, in logical pixels (05 §4).
  static const double height = 18;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: _tabCountPadding),
      decoration: SkotiqDecorations.chip(colors),
      // `Center(widthFactor: 1)` rather than the Container's own `alignment`,
      // which would expand the chip to the width the tab was offered.
      child: Center(
        widthFactor: 1,
        child: Text(
          count,
          style: SkotiqChip.textStyle().copyWith(color: tone),
        ),
      ),
    );
  }
}

/// Icon size inside a tab, in logical pixels (05 §4: leading icon 15).
const double _tabIconSize = SkotiqTokens.iconGlyphTab;

/// Gap between a tab's icon, its label and its count chip
/// (`observatory.css` `.tab { gap: 7px }`).
const double _tabIconGap = 7;

/// Horizontal padding inside a tab's count chip.
const double _tabCountPadding = 6;

/// Minimum tab height, so a tab in a bar with no height of its own is still a
/// reachable touch target.
const double _tabMinHeight = 40;
