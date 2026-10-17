import 'package:flutter/material.dart';

/// Drop-in replacements for Material's dropdowns that are operable by
/// assistive technology.
///
/// Material's `_DropdownMenuItemContainer` (the wrapper every
/// [DropdownMenuItem] and every dropdown hint is built into) declares
/// `button: true` and **never** an enabled state. AT-SPI derives "disabled"
/// from the ABSENCE of the enabled flag, so a raw Material dropdown announces
/// every entry of a perfectly live control as one the user cannot operate, and
/// no entry carries the `selected` mark that says which one is in force. That
/// is one framework behaviour, not one bug per screen.
///
/// The remedy, pinned in `SkotiqDropdown`, is two-part:
///
/// 1. wrap each item's child in `Semantics(enabled:, selected:)` — the flags
///    the framework leaves out — and
/// 2. supply a `selectedItemBuilder`, because the closed control otherwise
///    renders the chosen [DropdownMenuItem] itself and inherits its `selected`
///    state, announcing the control as a selected menu entry.
///
/// The `selectedItemBuilder` mirrors `_DropdownMenuItemContainer`'s own layout
/// exactly — a 48 px (`kMinInteractiveDimension`) minimum height and the
/// item's own alignment — so nothing moves on screen.
///
/// A wrapper is used rather than 42 hand-edited call sites so the recipe
/// cannot drift, and so a new dropdown inherits it by construction.
class AccessibleDropdown<T> extends StatelessWidget {
  const AccessibleDropdown({
    super.key,
    required this.items,
    required this.onChanged,
    this.value,
    this.hint,
    this.disabledHint,
    this.onTap,
    this.elevation = 8,
    this.style,
    this.underline,
    this.icon,
    this.iconDisabledColor,
    this.iconEnabledColor,
    this.iconSize = 24.0,
    this.isDense = false,
    this.isExpanded = false,
    this.itemHeight = kMinInteractiveDimension,
    this.focusColor,
    this.focusNode,
    this.autofocus = false,
    this.dropdownColor,
    this.menuMaxHeight,
    this.enableFeedback,
    this.alignment = AlignmentDirectional.centerStart,
    this.borderRadius,
    this.padding,
  });

  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final T? value;
  final Widget? hint;
  final Widget? disabledHint;
  final VoidCallback? onTap;
  final int elevation;
  final TextStyle? style;
  final Widget? underline;
  final Widget? icon;
  final Color? iconDisabledColor;
  final Color? iconEnabledColor;
  final double iconSize;
  final bool isDense;
  final bool isExpanded;
  final double? itemHeight;
  final Color? focusColor;
  final FocusNode? focusNode;
  final bool autofocus;
  final Color? dropdownColor;
  final double? menuMaxHeight;
  final bool? enableFeedback;
  final AlignmentGeometry alignment;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    // Mirrors DropdownButton's own `_enabled`.
    final bool enabled = onChanged != null && items.isNotEmpty;
    // When a hint is supplied Material hands the button role to the hint's
    // container instead of its own outer node, so the closed control has to
    // carry the role itself. Declaring it in both places is not harmless:
    // two fragments that set the SAME flag are held incompatible and split
    // into two nodes, which is how a dropdown ends up with an empty second
    // "push button" beside it.
    final bool roleIsOnTheChild = hint != null || disabledHint != null;

    return DropdownButton<T>(
      value: value,
      hint: hint == null ? null : Semantics(enabled: enabled, child: hint),
      disabledHint: disabledHint == null
          ? null
          : Semantics(enabled: false, child: disabledHint),
      items: annotateDropdownItems(items, value: value, enabled: enabled),
      selectedItemBuilder: (context) => buildSelectedDropdownItems(
        items,
        enabled: enabled,
        declareButtonRole: roleIsOnTheChild,
      ),
      onChanged: onChanged,
      onTap: onTap,
      elevation: elevation,
      style: style,
      underline: underline,
      icon: icon,
      iconDisabledColor: iconDisabledColor,
      iconEnabledColor: iconEnabledColor,
      iconSize: iconSize,
      isDense: isDense,
      isExpanded: isExpanded,
      itemHeight: itemHeight,
      focusColor: focusColor,
      focusNode: focusNode,
      autofocus: autofocus,
      dropdownColor: dropdownColor,
      menuMaxHeight: menuMaxHeight,
      enableFeedback: enableFeedback,
      alignment: alignment,
      borderRadius: borderRadius,
      padding: padding,
    );
  }
}

/// [DropdownButtonFormField] with the same treatment as [AccessibleDropdown].
class AccessibleDropdownFormField<T> extends StatelessWidget {
  const AccessibleDropdownFormField({
    super.key,
    required this.items,
    required this.onChanged,
    this.initialValue,
    this.hint,
    this.disabledHint,
    this.decoration,
    this.validator,
    this.onSaved,
    this.autovalidateMode,
    this.style,
    this.icon,
    this.iconSize = 24.0,
    this.isDense = true,
    this.isExpanded = false,
    this.dropdownColor,
    this.menuMaxHeight,
    this.borderRadius,
    this.alignment = AlignmentDirectional.centerStart,
  });

  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final T? initialValue;
  final Widget? hint;
  final Widget? disabledHint;
  final InputDecoration? decoration;
  final FormFieldValidator<T>? validator;
  final FormFieldSetter<T>? onSaved;
  final AutovalidateMode? autovalidateMode;
  final TextStyle? style;
  final Widget? icon;
  final double iconSize;
  final bool isDense;
  final bool isExpanded;
  final Color? dropdownColor;
  final double? menuMaxHeight;
  final BorderRadius? borderRadius;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onChanged != null && items.isNotEmpty;
    // The form field synthesises a hint from `decoration.hintText`, which
    // moves the button role onto the displayed child exactly as an explicit
    // hint does.
    final bool roleIsOnTheChild =
        hint != null || disabledHint != null || decoration?.hintText != null;

    return DropdownButtonFormField<T>(
      initialValue: initialValue,
      hint: hint == null ? null : Semantics(enabled: enabled, child: hint),
      disabledHint: disabledHint == null
          ? null
          : Semantics(enabled: false, child: disabledHint),
      items:
          annotateDropdownItems(items, value: initialValue, enabled: enabled),
      selectedItemBuilder: (context) => buildSelectedDropdownItems(
        items,
        enabled: enabled,
        declareButtonRole: roleIsOnTheChild,
      ),
      onChanged: onChanged,
      decoration: decoration,
      validator: validator,
      onSaved: onSaved,
      autovalidateMode: autovalidateMode,
      style: style,
      icon: icon,
      iconSize: iconSize,
      isDense: isDense,
      isExpanded: isExpanded,
      dropdownColor: dropdownColor,
      menuMaxHeight: menuMaxHeight,
      borderRadius: borderRadius,
      alignment: alignment,
    );
  }
}

/// Re-wraps [items] so each entry announces whether it is operable and whether
/// it is the one in force.
///
/// [Semantics] imposes no layout of its own, so the menu is pixel-identical.
List<DropdownMenuItem<T>> annotateDropdownItems<T>(
  List<DropdownMenuItem<T>> items, {
  required T? value,
  required bool enabled,
}) =>
    <DropdownMenuItem<T>>[
      for (final item in items)
        DropdownMenuItem<T>(
          key: item.key,
          value: item.value,
          enabled: item.enabled,
          alignment: item.alignment,
          onTap: item.onTap,
          child: Semantics(
            enabled: enabled && item.enabled,
            selected: item.value == value,
            // `selected` alone reaches AT-SPI as SELECTED, which several
            // readers (and the audit harness, which prints [ON]/[off] from the
            // checked/checkable states) do not announce for a menu entry — so
            // the Analytics session pickers highlighted the current row
            // visually while publishing no checked state at all, unlike
            // `SkotiqDropdown`, which sets both. Parity, one line: the two
            // dropdown families must announce the same way.
            checked: item.value == value,
            child: item.child,
          ),
        ),
    ];

/// Builds the widgets the CLOSED control paints, from the UNANNOTATED item
/// children — so the control does not inherit the chosen entry's `selected`
/// state and announce itself as a menu entry.
///
/// The [ConstrainedBox]/[Align] pair reproduces Material's
/// `_DropdownMenuItemContainer` layout verbatim (48 px minimum height, the
/// item's own alignment), which is what keeps the rendered pixels unchanged.
List<Widget> buildSelectedDropdownItems<T>(
  List<DropdownMenuItem<T>> items, {
  required bool enabled,
  required bool declareButtonRole,
}) =>
    <Widget>[
      for (final item in items)
        Semantics(
          enabled: enabled,
          button: declareButtonRole ? true : null,
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(minHeight: kMinInteractiveDimension),
            child: Align(alignment: item.alignment, child: item.child),
          ),
        ),
    ];
