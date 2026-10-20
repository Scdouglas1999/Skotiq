import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/skotiq_colors.dart';
import '../theme/skotiq_decorations.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';
import '../utils/field_width.dart';

/// Field heights in logical pixels (03 §3.3: `inputHeight` 32, dense 28).
const double fieldHeight = SkotiqTokens.inputHeight;
const double fieldHeightDense = SkotiqTokens.inputHeightSm;

/// Horizontal padding inside a field (`observatory.css` `.field`).
const double fieldHorizontalPadding = SkotiqTokens.inputPaddingHorizontal;

/// Leading icon size inside a field, in logical pixels (05 §8: 14 muted).
const double fieldIconSize = SkotiqTokens.iconXs;

/// A single-line text or number field on the Observatory scale.
///
/// 32px tall, 28 with [dense]. The [SkotiqDecorations.field] face is a
/// `well` fill with a near-invisible resting ring that becomes a real 1px
/// `primary` line on focus and `error` on error — the one place in this
/// language where a border carries state.
///
/// The [label] parameter still renders a caption ABOVE the field for the call
/// sites that have not moved yet; new code puts the label to the LEFT with
/// `FormRow(label: …, child: SkotiqTextField(…))`.
class SkotiqTextField extends StatefulWidget {
  final String? initialValue;
  final String? hint;
  final String? label;
  final IconData? prefixIcon;
  final Widget? suffixWidget;
  final String? suffix;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextInputAction? textInputAction;
  final bool obscureText;
  final bool? autocorrect;
  final bool? enableSuggestions;
  final TextInputType? keyboardType;
  final int maxLines;
  final String? errorText;
  final bool enabled;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final List<TextInputFormatter>? inputFormatters;
  final TextAlign textAlign;

  /// 28px instead of 32 — for a field inside a toolbar or a dense row.
  final bool dense;

  /// Renders the value in [SkotiqTypography.inputMono] with tabular
  /// figures. Every numeric field sets this, so a column of numbers lines up
  /// digit under digit instead of drifting with the glyph widths.
  final bool mono;

  /// Take focus as soon as the field is mounted. Needed by fields that are the
  /// sole purpose of a dialog, so the user can type immediately.
  final bool autofocus;

  const SkotiqTextField({
    super.key,
    this.initialValue,
    this.hint,
    this.label,
    this.prefixIcon,
    this.suffixWidget,
    this.suffix,
    this.onChanged,
    this.onSubmitted,
    this.textInputAction,
    this.obscureText = false,
    this.autocorrect,
    this.enableSuggestions,
    this.keyboardType,
    this.maxLines = 1,
    this.errorText,
    this.enabled = true,
    this.controller,
    this.focusNode,
    this.inputFormatters,
    this.textAlign = TextAlign.start,
    this.dense = false,
    this.mono = false,
    this.autofocus = false,
  });

  /// The field's height in logical pixels. Null for a multi-line field, which
  /// grows with its content.
  double? get height =>
      maxLines == 1 ? (dense ? fieldHeightDense : fieldHeight) : null;

  @override
  State<SkotiqTextField> createState() => _SkotiqTextFieldState();
}

class _SkotiqTextFieldState extends State<SkotiqTextField> {
  late FocusNode _focusNode;
  late TextEditingController _controller;
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _controller =
        widget.controller ?? TextEditingController(text: widget.initialValue);
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    if (widget.focusNode == null) _focusNode.dispose();
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (!mounted || _isFocused == _focusNode.hasFocus) return;
    setState(() => _isFocused = _focusNode.hasFocus);
  }

  TextStyle _valueStyle(SkotiqColors colors) {
    return (widget.mono ? SkotiqTypography.inputMono : SkotiqTypography.input)
        .copyWith(
          color: widget.enabled ? colors.textPrimary : colors.textMuted,
        );
  }

  InputDecoration _collapsedDecoration(
    TextStyle hintStyle,
    SkotiqColors colors,
  ) {
    // Collapsed: the chrome lives on the wrapping well, not on Material's
    // InputDecorator. An outline decorator with `isDense` sizes its *fill* to
    // the text line (~20px) and top-aligns that fill inside a 32px slot, which
    // is why capture-bar fields sat high against Snapshot/Loop and why a
    // FormRow's well did not share a centre line with its label.
    //
    // Borders and padding are set explicitly so Theme.inputDecorationTheme
    // (outline + 8px vertical inset) cannot leak back in through applyDefaults.
    return InputDecoration(
      isCollapsed: true,
      isDense: true,
      // The platform's VisualDensity (-8px on desktop's compact default) is
      // folded into the decorator's baseline math as phantom vertical room;
      // `textAlignVertical.center` then drops the editable 4px below its own
      // slot, which is what sat the digits low in the well. Pin standard so
      // the input fills the slot identically on every platform.
      visualDensity: VisualDensity.standard,
      filled: false,
      hintText: widget.hint,
      hintStyle: hintStyle,
      counterText: '',
      contentPadding: EdgeInsets.zero,
      floatingLabelBehavior: FloatingLabelBehavior.never,
      // The decorator lays the unit out on the input's baseline, so it reads
      // as a suffix of the value rather than a caption floating at the row's
      // centre line. height 1.0 keeps its line inside the 14px slot.
      suffix: widget.suffix == null
          ? null
          : ExcludeSemantics(
              child: Text(
                widget.suffix!,
                style: SkotiqTypography.caption.copyWith(
                  color: colors.textMuted,
                  height: 1.0,
                  leadingDistribution: TextLeadingDistribution.even,
                ),
              ),
            ),
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      disabledBorder: InputBorder.none,
      errorBorder: InputBorder.none,
      focusedErrorBorder: InputBorder.none,
    );
  }

  Widget _input({
    required TextStyle textStyle,
    required InputDecoration decoration,
    required int maxLines,
    StrutStyle? strutStyle,
    double? cursorHeight,
  }) {
    return TextFormField(
      controller: _controller,
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      onChanged: widget.onChanged,
      onFieldSubmitted: widget.onSubmitted,
      textInputAction: widget.textInputAction,
      obscureText: widget.obscureText,
      autocorrect: widget.autocorrect ?? !widget.obscureText,
      enableSuggestions: widget.enableSuggestions ?? !widget.obscureText,
      keyboardType: widget.keyboardType,
      inputFormatters: widget.inputFormatters,
      textAlign: widget.textAlign,
      maxLines: maxLines,
      enabled: widget.enabled,
      textAlignVertical: TextAlignVertical.center,
      scrollPadding: EdgeInsets.zero,
      style: textStyle,
      strutStyle: strutStyle,
      cursorHeight: cursorHeight,
      decoration: decoration,
    );
  }

  Widget _singleLineWell(SkotiqColors colors, BoxDecoration well) {
    final textStyle = _valueStyle(colors);
    final fontSize = textStyle.fontSize ?? 14;
    // Tight em-box: the named `input` style carries height 1.43 (~20px) for
    // multi-line copy. Inside a 32px well that line box plus Material's caret
    // prototype sits the glyphs low against the suffix and the prefix icon.
    // Height 1.0 at the font size, forced as the strut, and a box that tall
    // lets the Row centre the value with the 14px icon and the unit caption.
    final lineStyle = textStyle.copyWith(
      height: 1.0,
      leadingDistribution: TextLeadingDistribution.even,
    );
    final hintStyle = lineStyle.copyWith(color: colors.textMuted);
    // One line at the reader's text size: a slot of the bare font size cut
    // the value and the placeholder off at 1.3x text.
    final lineHeight = MediaQuery.textScalerOf(context).scale(fontSize);
    final wellHeight = widget.height;
    final input = SizedBox(
      height: lineHeight,
      child: _input(
        textStyle: lineStyle,
        decoration: _collapsedDecoration(hintStyle, colors),
        maxLines: 1,
        cursorHeight: lineHeight,
        strutStyle: StrutStyle(
          fontSize: fontSize,
          height: 1.0,
          leading: 0,
          forceStrutHeight: true,
          fontFamily: textStyle.fontFamily,
        ),
      ),
    );

    // [FieldWidthBox] resolves the same expand rule as [SkotiqDropdown] —
    // fill a bounded slot so the value reads from the leading edge and the
    // unit sits at the trailing one, shrink-wrap in a content-sized Row — but
    // in the render object rather than a `LayoutBuilder`, so this subtree can
    // still answer the intrinsic queries an `AlertDialog` puts to its content.
    // The width it hands down is tight either way, which is what lets the Row
    // below stay `MainAxisSize.max` with a tight [Flexible] in both cases.
    return FieldWidthBox(
      // Listener, not GestureDetector: a tap recognizer would publish its own
      // tappable node and steal the label off the text field.
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: widget.enabled
            ? (_) {
                if (!_focusNode.hasFocus) _focusNode.requestFocus();
              }
            : null,
        child: Container(
          // The well grows only when the scaled line would not fit inside it.
          height: wellHeight == null
              ? null
              : math.max(wellHeight, lineHeight + 2 * SkotiqTokens.spaceXs),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(
            horizontal: fieldHorizontalPadding,
          ),
          decoration: well,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              if (widget.prefixIcon != null) ...<Widget>[
                ExcludeSemantics(
                  child: Icon(
                    widget.prefixIcon,
                    size: fieldIconSize,
                    color: _isFocused && widget.enabled
                        ? colors.primary
                        : colors.textMuted,
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
              ],
              Expanded(child: input),
              if (widget.suffixWidget != null) widget.suffixWidget!,
            ],
          ),
        ),
      ),
    );
  }

  Widget _multilineField(SkotiqColors colors, BoxDecoration well) {
    final textStyle = _valueStyle(colors);
    final ring = well.border!.top.color;
    OutlineInputBorder outline(Color color) => OutlineInputBorder(
      borderRadius: SkotiqTokens.borderRadiusSm,
      borderSide: BorderSide(color: color),
    );
    return _input(
      textStyle: textStyle,
      decoration: InputDecoration(
        isDense: true,
        // Same platform-density pin as the collapsed single-line well.
        visualDensity: VisualDensity.standard,
        hintText: widget.hint,
        hintStyle: textStyle.copyWith(color: colors.textMuted),
        filled: true,
        fillColor: well.color,
        counterText: '',
        contentPadding: const EdgeInsets.symmetric(
          horizontal: fieldHorizontalPadding,
          vertical: SkotiqTokens.spaceSm,
        ),
        border: outline(ring),
        enabledBorder: outline(ring),
        focusedBorder: outline(ring),
        disabledBorder: outline(ring),
        errorBorder: outline(colors.error),
        focusedErrorBorder: outline(colors.error),
      ),
      maxLines: widget.maxLines,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final hasError = widget.errorText != null && widget.errorText!.isNotEmpty;
    final well = SkotiqDecorations.field(
      colors,
      focused: _isFocused && widget.enabled,
      hasError: hasError,
    );

    final field = widget.maxLines == 1
        ? _singleLineWell(colors, well)
        : _multilineField(colors, well);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (widget.label != null) ...<Widget>[
          Text(
            widget.label!,
            style: SkotiqTypography.caption.copyWith(
              color: _isFocused ? colors.primary : colors.textSecondary,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
        ],
        // The caption above is a sibling of the field, so the field itself
        // reached assistive tech as an anonymous text box — a settings leaf
        // full of them announced fifteen identical unnamed fields.
        Semantics(label: widget.label, child: field),
        if (hasError) ...<Widget>[
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            widget.errorText!,
            style: SkotiqTypography.captionSm.copyWith(color: colors.error),
          ),
        ],
      ],
    );
  }
}
