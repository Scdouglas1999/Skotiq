import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme/skotiq_colors.dart';
import 'skotiq_icon_button.dart';

/// A row of grouped actions, separated by hairlines rather than boxes.
///
/// `SkotiqToolbar(groups: [[undo, redo], [timeline, map], [more]])`. Each
/// group is separated from the next by a 1 × 14 hairline with 6px either side.
/// Children are `SkotiqIconButton(size: IconButtonSize.sm)` or small ghost
/// buttons with labels — a toolbar labels the two or three most-used actions
/// and leaves the rest as glyphs.
///
/// [overflow] actions move behind a `more-horizontal` menu when the width is
/// tight. That decision is MEASURED with a `LayoutBuilder`, never counted:
/// three long labels overflow a 300px side panel while six short glyphs do not,
/// so a count is the wrong question.
class SkotiqToolbar extends StatelessWidget {
  const SkotiqToolbar({
    super.key,
    required this.groups,
    this.overflow = const <Widget>[],
    this.overflowIcon,
    this.onOverflowPressed,
    this.overflowTooltip = 'More actions',
  });

  /// The action groups, in reading order.
  final List<List<Widget>> groups;

  /// Actions that are dropped when the toolbar cannot fit its groups.
  ///
  /// They are laid out as a final group while there is room, and replaced by
  /// the overflow button when there is not.
  final List<Widget> overflow;

  /// The overflow menu's glyph. Supplied by the caller so this package does not
  /// bind an icon set at its API boundary; pass `LucideIcons.moreHorizontal`.
  final IconData? overflowIcon;

  /// Opens the overflow menu.
  final VoidCallback? onOverflowPressed;

  /// The overflow button's tooltip.
  final String overflowTooltip;

  /// Gap between the buttons inside one group.
  static const double itemGap = 2;

  /// Padding on either side of a group separator.
  static const double groupPadding = 6;

  /// The separator's size.
  static const double separatorWidth = 1;
  static const double separatorHeight = 14;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;

    Widget group(List<Widget> children) => Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        for (var i = 0; i < children.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: itemGap),
          children[i],
        ],
      ],
    );

    Widget separator() => Padding(
      padding: const EdgeInsets.symmetric(horizontal: groupPadding),
      child: Container(
        width: separatorWidth,
        height: separatorHeight,
        color: colors.border,
      ),
    );

    Widget bar(List<List<Widget>> visible, {required bool showOverflow}) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (var i = 0; i < visible.length; i++) ...<Widget>[
            if (i > 0) separator(),
            group(visible[i]),
          ],
          if (showOverflow && overflowIcon != null) ...<Widget>[
            if (visible.isNotEmpty) separator(),
            SkotiqIconButton(
              icon: overflowIcon!,
              tooltip: overflowTooltip,
              size: IconButtonSize.sm,
              onPressed: onOverflowPressed,
            ),
          ],
        ],
      );
    }

    if (overflow.isEmpty) {
      return bar(groups, showOverflow: false);
    }

    final full = <List<Widget>>[...groups, overflow];
    return _ToolbarFit(
      children: <Widget>[
        bar(full, showOverflow: false),
        bar(groups, showOverflow: true),
      ],
    );
  }
}

/// Renders the first child when it fits the incoming width and the second when
/// it does not.
///
/// Both are laid out, so the decision is made against a real measured width —
/// the toolbar can then say honestly that it collapsed because the actions did
/// not fit, not because there were more than N of them.
class _ToolbarFit extends MultiChildRenderObjectWidget {
  const _ToolbarFit({required super.children});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderToolbarFit();
}

class _ToolbarFitParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderToolbarFit extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _ToolbarFitParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _ToolbarFitParentData> {
  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! _ToolbarFitParentData) {
      child.parentData = _ToolbarFitParentData();
    }
  }

  RenderBox get _full => firstChild!;
  RenderBox get _collapsed => childAfter(firstChild!)!;

  /// The child actually painted and hit-tested. Set in [performLayout].
  RenderBox? _chosen;

  @override
  double computeMinIntrinsicWidth(double height) =>
      _collapsed.getMinIntrinsicWidth(height);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _full.getMaxIntrinsicWidth(height);

  @override
  double computeMinIntrinsicHeight(double width) =>
      _full.getMinIntrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _full.getMaxIntrinsicHeight(width);

  @override
  void performLayout() {
    // Both children take a REAL layout. Handing the loser a tight zero box
    // instead would make its Row report an overflow in debug, which is a
    // console full of red for a widget that is not even drawn.
    final loose = BoxConstraints(
      maxHeight: constraints.maxHeight,
      minHeight: constraints.minHeight,
    );
    _full.layout(loose, parentUsesSize: true);
    _collapsed.layout(loose, parentUsesSize: true);

    _chosen = _full.size.width <= constraints.maxWidth ? _full : _collapsed;
    (_chosen!.parentData! as _ToolbarFitParentData).offset = Offset.zero;
    size = constraints.constrain(_chosen!.size);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final chosen = _chosen;
    if (chosen == null) return;
    context.paintChild(chosen, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final chosen = _chosen;
    if (chosen == null) return false;
    return result.addWithPaintOffset(
      offset: Offset.zero,
      position: position,
      hitTest: (BoxHitTestResult result, Offset transformed) =>
          chosen.hitTest(result, position: transformed),
    );
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    final chosen = _chosen;
    if (chosen != null) visitor(chosen);
  }
}
