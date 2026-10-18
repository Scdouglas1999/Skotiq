import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../theme/skotiq_colors.dart';
import '../theme/skotiq_decorations.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';
import '../utils/touch_target.dart';
import 'skotiq_text_field.dart';

/// A select on the Observatory scale: the same 32px [SkotiqDecorations.field]
/// face as [SkotiqTextField], a 14px muted chevron, and an open list on the
/// `popover` decoration with 32px rows.
///
/// The open list is this file's own popover, not Material's menu. Material's
/// `DropdownButton` asserts a 48px floor on every entry, which is a TOUCH
/// figure applied to a pointer control: it made the open list a third taller
/// than the sheet asks for (05 §8) and half again as tall as the field that
/// opened it. The floor is still honoured where it means something — on a
/// touch platform every row grows to [SkotiqTokens.minTouchTarget], the
/// same rule `SkotiqIconButton` follows.
class SkotiqDropdown extends StatefulWidget {
  final String? value;
  final String? hint;
  final List<String> items;
  final List<String>? itemLabels;
  final ValueChanged<String?>? onChanged;

  /// Force the value/chevron row to fill the control even where the incoming
  /// width is unbounded.
  ///
  /// Rarely needed: a select given a bounded width now fills it on its own, so
  /// its value reads from the leading edge and its chevron sits at the trailing
  /// one, like every other field.
  final bool isExpanded;

  /// No longer read: the closed control's height is fixed by the field face.
  @Deprecated('The field height is fixed; use `dense`. Removed in wave 4.')
  final bool isDense;

  /// 28px instead of 32 — matches [SkotiqTextField.dense] so a dense row
  /// can mix the two without a step in the baseline.
  final bool dense;

  const SkotiqDropdown({
    super.key,
    this.value,
    this.hint,
    required this.items,
    this.itemLabels,
    this.onChanged,
    this.isExpanded = false,
    // ignore: deprecated_member_use_from_same_package
    this.isDense = false,
    this.dense = false,
  });

  /// The style the closed control paints its current value in.
  ///
  /// Public so a caller that has to SIZE this control can measure the label
  /// with the same style it will be painted in, instead of guessing.
  static const TextStyle labelStyle = SkotiqTypography.input;

  /// Horizontal space this control spends on everything that is not the label:
  /// 10px padding each side, the 14px chevron, the 8px gap before it, and the
  /// 1px ring each side.
  ///
  /// A caller that sizes this control adds the widest label to this figure, so
  /// leaving the gap out of it is what ellipsizes a value that fits.
  static const double chromeWidth =
      fieldHorizontalPadding * 2 + fieldIconSize + SkotiqTokens.spaceSm + 2;

  /// The control's height in logical pixels.
  double get height => dense ? fieldHeightDense : fieldHeight;

  String labelFor(int index) => itemLabels != null && index < itemLabels!.length
      ? itemLabels![index]
      : items[index];

  @override
  State<SkotiqDropdown> createState() => _SkotiqDropdownState();
}

class _SkotiqDropdownState extends State<SkotiqDropdown> {
  final GlobalKey _fieldKey = GlobalKey();
  bool _open = false;
  bool _focused = false;

  bool get _isEnabled => widget.onChanged != null && widget.items.isNotEmpty;

  Future<void> _openMenu() async {
    if (!_isEnabled || _open) return;
    final navigator = Navigator.maybeOf(context);
    final overlay =
        navigator?.overlay?.context.findRenderObject() as RenderBox?;
    final field = _fieldKey.currentContext?.findRenderObject() as RenderBox?;
    if (navigator == null ||
        overlay == null ||
        field == null ||
        !field.hasSize ||
        !overlay.hasSize) {
      return;
    }

    // The anchor is measured in the OVERLAY's coordinate space, which is the
    // space the route lays out in. Measuring in global coordinates instead
    // puts the menu a title bar's height too low inside any app whose overlay
    // does not start at the top of the window.
    final anchor =
        field.localToGlobal(Offset.zero, ancestor: overlay) & field.size;

    setState(() => _open = true);
    final chosen = await navigator.push<String>(
      _DropdownMenuRoute(
        anchor: anchor,
        items: List<String>.unmodifiable(widget.items),
        labels: List<String>.unmodifiable(<String>[
          for (var i = 0; i < widget.items.length; i++) widget.labelFor(i),
        ]),
        value: widget.value,
        // The menu is a route, so it is built outside this subtree and would
        // otherwise lose any Theme (and with it `SkotiqColors`) that a
        // caller wrapped this control in — a select inside `Glass` would come
        // back light.
        capturedThemes: InheritedTheme.capture(
          from: context,
          to: navigator.context,
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _open = false);
    if (chosen != null && chosen != widget.value) {
      widget.onChanged?.call(chosen);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;

    // The closed control is ONE control, and it says so here rather than
    // leaving the role to Material.
    //
    // Everything the operator can perceive about the control — the value's
    // words, the button role, the enabled state — has to arrive on ONE node.
    // Split across two, assistive tech gets one node it can read and another
    // it can press, and announces neither usefully; that is how the export
    // sheet's step picker reached AT-SPI as ROLE_PANEL. `MergeSemantics` is
    // what folds the `Text` below into the annotation above it.
    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: _isEnabled,
        // The control is always [_boxHeight] tall, and saying so here gives it
        // an intrinsic height. A bare LayoutBuilder has none: inside an
        // IntrinsicHeight row (the Equipment device grid) it asserted in debug
        // and measured as zero in release, so the row came out shorter than
        // the card holding the select.
        child: SizedBox(
          height: _boxHeight(context),
          child: LayoutBuilder(
            builder: (context, constraints) => _control(
              colors,
              // A select is a FIELD: given a width it fills it, so the value
              // reads from the leading edge and the chevron sits at the
              // trailing one. Where the width is UNBOUNDED — a shrink-wrapping
              // Row, which is how a settings row hosts one — filling is not a
              // thing a box can do.
              expand: widget.isExpanded || constraints.hasBoundedWidth,
            ),
          ),
        ),
      ),
    );
  }

  /// The interactive box's height.
  ///
  /// 32 is a desktop POINTER size (03 §3.3). A finger needs 48, so on a touch
  /// platform the interactive box grows to it while the painted field stays
  /// the height the sheet specifies — the same split `SkotiqIconButton`
  /// makes, and the reason the mobile tap-target audit measured this control
  /// at 24px tall.
  double _boxHeight(BuildContext context) =>
      math.max(widget.height, SkotiqTouchTarget.minExtent(context));

  Widget _control(SkotiqColors colors, {required bool expand}) {
    final Widget field = _closed(colors, expand: expand);

    final double box = _boxHeight(context);
    final Widget sized = box == widget.height
        ? field
        : SizedBox(
            height: box,
            child: Center(child: field),
          );

    return FocusableActionDetector(
      enabled: _isEnabled,
      onShowFocusHighlight: (value) {
        if (!mounted || _focused == value) return;
        setState(() => _focused = value);
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _openMenu();
            return null;
          },
        ),
        ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
          onInvoke: (_) {
            _openMenu();
            return null;
          },
        ),
      },
      mouseCursor: _isEnabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _isEnabled ? _openMenu : null,
        child: sized,
      ),
    );
  }

  Widget _closed(SkotiqColors colors, {required bool expand}) {
    final index = widget.value == null
        ? -1
        : widget.items.indexOf(widget.value!);
    final bool showsHint = index < 0;
    final String text = showsHint
        ? (widget.hint ?? '')
        : widget.labelFor(index);

    final Widget label = Text(
      text,
      style: SkotiqDropdown.labelStyle.copyWith(
        color: !_isEnabled || showsHint ? colors.textMuted : colors.textPrimary,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
    );

    return Container(
      key: _fieldKey,
      height: widget.height,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: fieldHorizontalPadding),
      decoration: SkotiqDecorations.field(colors, focused: _open || _focused),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Flexible(fit: expand ? FlexFit.tight : FlexFit.loose, child: label),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Icon(
            LucideIcons.chevronDown,
            size: fieldIconSize,
            color: colors.textMuted,
          ),
        ],
      ),
    );
  }
}

/// The open list: a popover anchored to the field, not a Material menu.
class _DropdownMenuRoute extends PopupRoute<String> {
  _DropdownMenuRoute({
    required this.anchor,
    required this.items,
    required this.labels,
    required this.value,
    required this.capturedThemes,
  });

  /// The closed control's rect in the overlay's coordinate space.
  final Rect anchor;
  final List<String> items;
  final List<String> labels;
  final String? value;
  final CapturedThemes capturedThemes;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss menu';

  @override
  Duration get transitionDuration => SkotiqTokens.durationFast;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return CustomSingleChildLayout(
      delegate: _DropdownMenuLayout(anchor: anchor),
      child: capturedThemes.wrap(
        _DropdownMenu(items: items, labels: labels, value: value),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: animation,
        curve: SkotiqTokens.curveStandard,
      ),
      child: child,
    );
  }
}

/// Puts the menu under the field, or above it when there is no room below.
class _DropdownMenuLayout extends SingleChildLayoutDelegate {
  _DropdownMenuLayout({required this.anchor});

  final Rect anchor;

  /// Gap between the field and its menu.
  static const double gap = SkotiqTokens.spaceXs;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final below = constraints.maxHeight - anchor.bottom - gap;
    final above = anchor.top - gap;
    return BoxConstraints(
      minWidth: math.min(anchor.width, constraints.maxWidth),
      maxWidth: constraints.maxWidth,
      maxHeight: math.max(0.0, math.max(below, above)),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    double y = anchor.bottom + gap;
    if (y + childSize.height > size.height) {
      final double above = anchor.top - gap - childSize.height;
      y = above >= 0 ? above : math.max(0.0, size.height - childSize.height);
    }
    double x = anchor.left;
    if (x + childSize.width > size.width) {
      x = math.max(0.0, size.width - childSize.width);
    }
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_DropdownMenuLayout oldDelegate) =>
      oldDelegate.anchor != anchor;
}

class _DropdownMenu extends StatefulWidget {
  const _DropdownMenu({
    required this.items,
    required this.labels,
    required this.value,
  });

  final List<String> items;
  final List<String> labels;
  final String? value;

  @override
  State<_DropdownMenu> createState() => _DropdownMenuState();
}

class _DropdownMenuState extends State<_DropdownMenu> {
  final ScrollController _scroll = ScrollController();
  late int _highlighted;

  @override
  void initState() {
    super.initState();
    final index = widget.value == null
        ? -1
        : widget.items.indexOf(widget.value!);
    _highlighted = index < 0 ? 0 : index;
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Row height: the sheet's 32 for a pointer, [SkotiqTokens.minTouchTarget]
  /// for a finger.
  double _rowHeight(BuildContext context) =>
      math.max(SkotiqTokens.buttonHeight, SkotiqTouchTarget.minExtent(context));

  void _reveal() {
    if (!mounted || !_scroll.hasClients) return;
    final row = _rowHeight(context);
    final target = (_highlighted * row).clamp(
      _scroll.position.minScrollExtent,
      _scroll.position.maxScrollExtent,
    );
    _scroll.jumpTo(target);
  }

  void _move(int delta) {
    final next = (_highlighted + delta).clamp(0, widget.items.length - 1);
    if (next == _highlighted) return;
    setState(() => _highlighted = next);
    _reveal();
  }

  void _choose(int index) => Navigator.of(context).pop(widget.items[index]);

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      _move(-widget.items.length);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      _move(widget.items.length);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space) {
      _choose(_highlighted);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final row = _rowHeight(context);

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Container(
        decoration: SkotiqDecorations.popover(colors),
        clipBehavior: Clip.antiAlias,
        padding: const EdgeInsets.all(SkotiqTokens.spaceXs),
        child: SingleChildScrollView(
          controller: _scroll,
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (var index = 0; index < widget.items.length; index++)
                  _row(colors, index, row),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(SkotiqColors colors, int index, double height) {
    final bool chosen = widget.items[index] == widget.value;
    final bool highlighted = index == _highlighted;

    // A menu of mutually exclusive options is a radio group, and CHECKED is
    // the state that role publishes — set on every entry so the unchosen ones
    // say "not checked" rather than nothing. `selected` alone is not enough:
    // AT-SPI carries it as SELECTED, which no menu consumer reads.
    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: true,
        selected: chosen,
        checked: chosen,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) {
            if (!mounted || _highlighted == index) return;
            setState(() => _highlighted = index);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _choose(index),
            child: Container(
              // Keyed so a test can measure the row it means without
              // reaching into a private widget type.
              key: ValueKey<String>('skotiqDropdownRow$index'),
              height: height,
              alignment: AlignmentDirectional.centerStart,
              padding: const EdgeInsets.symmetric(
                horizontal: SkotiqTokens.inputPaddingHorizontal,
              ),
              decoration: BoxDecoration(
                color: highlighted ? colors.surfaceHover : Colors.transparent,
                borderRadius: SkotiqTokens.borderRadiusSm,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      widget.labels[index],
                      style: SkotiqDropdown.labelStyle.copyWith(
                        color: chosen ? colors.primary : colors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ),
                  if (chosen) ...<Widget>[
                    const SizedBox(width: SkotiqTokens.spaceSm),
                    Icon(
                      LucideIcons.check,
                      size: SkotiqTokens.iconPillGlyph,
                      color: colors.primary,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
