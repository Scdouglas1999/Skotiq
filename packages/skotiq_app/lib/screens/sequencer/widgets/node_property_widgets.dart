import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show InterpolationVariable;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/sequence/variable_picker.dart';
import '../../accessible_dropdown.dart';

/// Finite upper/lower fallback used when only one of `min`/`max` is supplied to
/// a numeric field. Clamping against `double.infinity` let pathological values
/// (e.g. a fat-fingered exponent) flow straight into the timing estimator and
/// poison every downstream duration sum; a sane finite bound keeps the field
/// usable for any realistic value while refusing absurd ones.
const double kMaxNumberField = 1e6;

/// Debounce window before a number field commits its value to the sequence.
/// Long enough to coalesce a burst of keystrokes (which would otherwise rebuild
/// and re-estimate the whole sequence on every character) yet short enough that
/// the live timing/summary still feels responsive.
const Duration kNumberInputCommitDebounce = Duration(milliseconds: 250);

class NodeQuickTimeButton extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final VoidCallback onPressed;

  const NodeQuickTimeButton({
    super.key,
    required this.colors,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          padding: EdgeInsets.symmetric(
            vertical: Responsive.spacing(context, 8),
          ),
          decoration: BoxDecoration(
            color: colors.surfaceAlt,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
            border: Border.all(color: colors.border),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: SkotiqTypography.buttonSm.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// A numeric field's text: as many decimals as the value HAS, never more.
///
/// The field allows three decimals so sub-second exposures can be typed, but
/// printing that precision unconditionally turns a 120-second sub into
/// "120.000", which reads like a measurement rather than a setting. Trailing
/// zeros are dropped; a value that really is 1.5 still shows "1.5".
String formatNodeNumber(double value, int decimals) {
  if (decimals == 0) return value.toInt().toString();
  final fixed = value.toStringAsFixed(decimals);
  if (!fixed.contains('.')) return fixed;
  final trimmed = fixed.replaceFirst(RegExp(r'0+$'), '');
  return trimmed.endsWith('.')
      ? trimmed.substring(0, trimmed.length - 1)
      : trimmed;
}

class NodePropertyField extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final Widget child;

  /// Optional explanatory text. When set, a small info icon is rendered next
  /// to the label and reveals [helpText] in a tooltip on hover/long-press.
  final String? helpText;

  const NodePropertyField({
    super.key,
    required this.colors,
    required this.label,
    required this.child,
    this.helpText,
  });

  @override
  Widget build(BuildContext context) {
    // The label sits to the LEFT of the control (05 §8), which is what makes
    // a twelve-row property form scannable instead of a scroll: every label
    // lines up in one column and every control in another. A label above its
    // field cost a whole line of height per setting.
    //
    // [helpText] stays a tooltip on a trailing question mark rather than
    // becoming FormRow's `help` line: a form of explanations is a form nobody
    // reads, and these strings qualify one control each.
    return Padding(
      padding: const EdgeInsets.only(bottom: FormRow.rowGap),
      // The label column shrinks with the pane rather than pushing the control
      // off the row. The properties pane ANIMATES between 48 px and 300 px, and
      // a fixed 96 px label plus its 12 px gap is wider than the pane for part
      // of that tween — 108 px of inflexible content in a 107.5 px box is a
      // RenderFlex overflow on a frame nobody ever sees. Clamping the label to
      // 40% of the row keeps every intermediate frame legal and leaves the
      // settled pane at the spec's 96.
      child: LayoutBuilder(
        builder: (context, constraints) => FormRow(
          label: label,
          labelWidth: constraints.maxWidth.isFinite
              ? math.min(
                  FormRow.defaultLabelWidth,
                  constraints.maxWidth * _labelWidthCeiling,
                )
              : FormRow.defaultLabelWidth,
          child: helpText == null
              ? child
              : Row(
                  children: [
                    Expanded(child: child),
                    const SizedBox(width: SkotiqTokens.spaceXs),
                    Tooltip(
                      message: helpText!,
                      triggerMode: TooltipTriggerMode.tap,
                      child: Icon(
                        LucideIcons.helpCircle,
                        size: 14,
                        color: colors.textMuted,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  /// The most of a row the label column may claim.
  static const double _labelWidthCeiling = 0.4;
}

class NodeTextInput extends StatefulWidget {
  final SkotiqColors colors;
  final String value;
  final ValueChanged<String> onChanged;
  final String? hint;
  final int? maxLines;

  /// When true the field's border is drawn in [SkotiqColors.error] to flag
  /// invalid (but still-typeable) content such as malformed JSON.
  final bool hasError;

  /// When non-null the field gains a `${ }` insert control offering exactly
  /// these variables. Template fields (notification title/message) advertise
  /// `${target.name}`-style tokens in their hint and otherwise require the
  /// operator to type them from memory, with no list of what exists.
  final List<InterpolationVariable>? variables;

  const NodeTextInput({
    super.key,
    required this.colors,
    required this.value,
    required this.onChanged,
    this.hint,
    this.maxLines,
    this.hasError = false,
    this.variables,
  });

  @override
  State<NodeTextInput> createState() => _NodeTextInputState();
}

class _NodeTextInputState extends State<NodeTextInput> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(NodeTextInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && widget.value != _controller.text) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inputPaddingH = Responsive.spacing(context, 12);
    final inputPaddingV = Responsive.spacing(context, 10);
    final variables = widget.variables;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: inputPaddingH),
      decoration: BoxDecoration(
        color: widget.colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(
          color: widget.hasError ? widget.colors.error : widget.colors.border,
        ),
      ),
      child: TextField(
        controller: _controller,
        onChanged: widget.onChanged,
        maxLines: widget.maxLines ?? 1,
        minLines: widget.maxLines != null ? 1 : null,
        style: SkotiqTypography.bodySm.copyWith(
          color: widget.colors.textPrimary,
        ),
        decoration: InputDecoration(
          hintText: widget.hint,
          hintStyle: SkotiqTypography.bodySm.copyWith(
            color: widget.colors.textMuted,
          ),
          border: InputBorder.none,
          isDense: true,
          contentPadding: EdgeInsets.symmetric(vertical: inputPaddingV),
          suffixIcon: variables == null
              ? null
              : VariablePickerButton(
                  controller: _controller,
                  variables: variables,
                  // The picker writes through the controller, which does not
                  // fire TextField.onChanged (that only fires on user edits),
                  // so the insert has to be committed to the node explicitly.
                  onChanged: () => widget.onChanged(_controller.text),
                ),
        ),
      ),
    );
  }
}

class NodeNumberInput extends StatefulWidget {
  final SkotiqColors colors;
  final double value;
  final ValueChanged<double> onChanged;
  final String? suffix;
  final double? min;
  final double? max;
  final int decimals;

  /// Optional helper line shown under the field. When null and [min]/[max] are
  /// set, a "Range: min–max" line is synthesised automatically.
  final String? helperText;

  const NodeNumberInput({
    super.key,
    required this.colors,
    required this.value,
    required this.onChanged,
    this.suffix,
    this.min,
    this.max,
    this.decimals = 0,
    this.helperText,
  });

  @override
  State<NodeNumberInput> createState() => _NodeNumberInputState();
}

class _NodeNumberInputState extends State<NodeNumberInput> {
  late TextEditingController _controller;
  late FocusNode _focusNode;
  bool _hasFocus = false;
  bool _invalid = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _formatValue(widget.value));
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChange);
  }

  String _formatValue(double value) => formatNodeNumber(value, widget.decimals);

  void _onFocusChange() {
    final hadFocus = _hasFocus;
    _hasFocus = _focusNode.hasFocus;

    // When losing focus, flush any pending debounce and snap the field back to
    // the canonical value format so a half-typed/out-of-range string never
    // lingers.
    if (hadFocus && !_hasFocus) {
      _flushDebounce();
      final newText = _formatValue(widget.value);
      if (_controller.text != newText) {
        _controller.text = newText;
      }
      if (_invalid) setState(() => _invalid = false);
    }
  }

  void _flushDebounce() {
    if (_debounce?.isActive ?? false) {
      _debounce!.cancel();
    }
    _debounce = null;
  }

  void _handleChanged(String value) {
    final parsed = double.tryParse(value);
    if (parsed == null) {
      if (!_invalid) setState(() => _invalid = true);
      return;
    }
    final clamped = clampNumberField(parsed, widget.min, widget.max);
    // Reflect out-of-range typing visually but still commit the clamped value.
    final outOfRange = clamped != parsed;
    if (_invalid != outOfRange) {
      setState(() => _invalid = outOfRange);
    }
    _flushDebounce();
    _debounce = Timer(kNumberInputCommitDebounce, () {
      widget.onChanged(clamped);
      // Reconcile the displayed text when clamping actually changed the value
      // (don't fight the user mid-type otherwise).
      if (outOfRange && mounted && _focusNode.hasFocus) {
        final text = _formatValue(clamped);
        _controller.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
        setState(() => _invalid = false);
      }
    });
  }

  @override
  void didUpdateWidget(NodeNumberInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only update text if the field doesn't have focus (user isn't typing)
    if (!_hasFocus && oldWidget.value != widget.value) {
      final newText = _formatValue(widget.value);
      if (newText != _controller.text) {
        _controller.text = newText;
      }
    }
  }

  @override
  void dispose() {
    _flushDebounce();
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  String? get _rangeText {
    if (widget.min == null && widget.max == null) return null;
    final lo = widget.min == null ? null : _formatValue(widget.min!);
    final hi = widget.max == null ? null : _formatValue(widget.max!);
    if (lo != null && hi != null) return 'Range: $lo–$hi';
    if (lo != null) return 'Min: $lo';
    return 'Max: $hi';
  }

  /// The helper line under the field. We show an explicit [helperText] always,
  /// and otherwise only surface the value range while the field is invalid /
  /// out of range — keeping dense forms clean but explaining a rejected entry
  /// the moment it happens.
  String? get _resolvedHelperText {
    if (widget.helperText != null) return widget.helperText;
    if (_invalid) return _rangeText;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final inputPaddingH = Responsive.spacing(context, 12);
    final inputPaddingV = Responsive.spacing(context, 10);
    final helperText = _resolvedHelperText;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: EdgeInsets.symmetric(horizontal: inputPaddingH),
          decoration: BoxDecoration(
            color: widget.colors.surfaceAlt,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            border: Border.all(
              color: _invalid ? widget.colors.error : widget.colors.border,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  keyboardType: TextInputType.numberWithOptions(
                    decimal: widget.decimals > 0,
                    signed: (widget.min ?? 0) < 0,
                  ),
                  onChanged: _handleChanged,
                  style: SkotiqTypography.inputMono.copyWith(
                    color: widget.colors.textPrimary,
                  ),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(vertical: inputPaddingV),
                  ),
                ),
              ),
              // Flexible, not a bare Text: the unit is inflexible content in
              // a Row whose other child is Expanded, so in a narrow column
              // (a half-width field in the properties pane) a suffix wider
              // than the whole box overflowed the row rather than giving way.
              if (widget.suffix != null)
                Flexible(
                  child: Text(
                    widget.suffix!,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: SkotiqTypography.caption.copyWith(
                      color: widget.colors.textMuted,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (helperText != null)
          Padding(
            padding: EdgeInsets.only(
              top: Responsive.spacing(context, 4),
              left: Responsive.spacing(context, 2),
            ),
            child: Text(
              helperText,
              style: SkotiqTypography.caption.copyWith(
                color: _invalid ? widget.colors.error : widget.colors.textMuted,
              ),
            ),
          ),
      ],
    );
  }
}

/// Clamp [value] into [min]/[max], substituting a finite fallback when only one
/// bound is provided so a one-sided field can't admit absurd values into the
/// timing math.
double clampNumberField(double value, double? min, double? max) {
  final lo =
      min ?? (max != null ? math.min(max, -kMaxNumberField) : -kMaxNumberField);
  final hi =
      max ?? (min != null ? math.max(min, kMaxNumberField) : kMaxNumberField);
  return value.clamp(lo, hi).toDouble();
}

class NodeNumberInputWithHint extends StatefulWidget {
  final SkotiqColors colors;
  final double value;
  final ValueChanged<double> onChanged;
  final double? min;
  final double? max;
  final String? hintText;
  final int decimals;

  /// Whether the current value comes from a profile default rather than
  /// an explicit user override. When true, the value text is rendered in
  /// a muted color to visually distinguish it from user-set values.
  final bool isProfileDefault;

  const NodeNumberInputWithHint({
    super.key,
    required this.colors,
    required this.value,
    required this.onChanged,
    this.min,
    this.max,
    this.hintText,
    this.decimals = 0,
    this.isProfileDefault = false,
  });

  @override
  State<NodeNumberInputWithHint> createState() =>
      _NodeNumberInputWithHintState();
}

class _NodeNumberInputWithHintState extends State<NodeNumberInputWithHint> {
  late TextEditingController _controller;
  late FocusNode _focusNode;
  bool _hasFocus = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _formatValue(widget.value));
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChange);
  }

  String _formatValue(double value) => formatNodeNumber(value, widget.decimals);

  void _flushDebounce() {
    if (_debounce?.isActive ?? false) {
      _debounce!.cancel();
    }
    _debounce = null;
  }

  void _onFocusChange() {
    final hadFocus = _hasFocus;
    _hasFocus = _focusNode.hasFocus;

    // When losing focus, flush any pending commit and snap to canonical format.
    if (hadFocus && !_hasFocus) {
      _flushDebounce();
      final newText = _formatValue(widget.value);
      if (_controller.text != newText) {
        _controller.text = newText;
      }
    }
  }

  void _handleChanged(String value) {
    final parsed = double.tryParse(value);
    if (parsed == null) return;
    final clamped = clampNumberField(parsed, widget.min, widget.max);
    _flushDebounce();
    _debounce = Timer(kNumberInputCommitDebounce, () {
      widget.onChanged(clamped);
    });
  }

  @override
  void didUpdateWidget(NodeNumberInputWithHint oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only update text if the field doesn't have focus (user isn't typing)
    if (!_hasFocus && oldWidget.value != widget.value) {
      final newText = _formatValue(widget.value);
      if (newText != _controller.text) {
        _controller.text = newText;
      }
    }
  }

  @override
  void dispose() {
    _flushDebounce();
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // When showing a profile default, use a muted text color to visually
    // distinguish it from explicitly user-set values.
    final textColor = widget.isProfileDefault
        ? widget.colors.textSecondary
        : widget.colors.textPrimary;

    final inputPaddingH = Responsive.spacing(context, 12);
    final inputPaddingV = Responsive.spacing(context, 10);

    return Container(
      padding: EdgeInsets.symmetric(horizontal: inputPaddingH),
      decoration: BoxDecoration(
        color: widget.colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(
          color: widget.isProfileDefault
              ? widget.colors.border.withValues(alpha: 0.5)
              : widget.colors.border,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              keyboardType: TextInputType.numberWithOptions(
                decimal: widget.decimals > 0,
                signed: (widget.min ?? 0) < 0,
              ),
              onChanged: _handleChanged,
              style: SkotiqTypography.inputMono.copyWith(
                color: textColor,
              ),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: inputPaddingV),
                hintText: widget.hintText,
                hintStyle: SkotiqTypography.inputMono.copyWith(
                  color: widget.colors.textMuted,
                ),
              ),
            ),
          ),
          // Show profile indicator when using a profile default. Flexible,
          // because the properties pane animates from 48 px up to its width
          // and a fixed suffix overflowed the row by a few px on the frames
          // in between (caught by the public-screenshot capture).
          if (widget.isProfileDefault && widget.hintText != null)
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  'profile',
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  softWrap: false,
                  style: SkotiqTypography.caption.copyWith(
                    color: widget.colors.textMuted,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class NodeToggleSwitch extends StatelessWidget {
  final SkotiqColors colors;
  final bool value;
  final ValueChanged<bool> onChanged;

  const NodeToggleSwitch({
    super.key,
    required this.colors,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // Right-aligned at its own size. `FormRow` gives its control an
    // `Expanded`, and a bare switch inside one stretches its track across the
    // whole 300 px column — a 200 px switch reads as a progress bar.
    return Align(
      alignment: Alignment.centerRight,
      child: SkotiqSwitch(
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}

class NodeDropdown<T> extends StatelessWidget {
  final SkotiqColors colors;
  final T value;
  final List<T> items;
  final String Function(T) labelBuilder;
  final ValueChanged<T> onChanged;

  const NodeDropdown({
    super.key,
    required this.colors,
    required this.value,
    required this.items,
    required this.labelBuilder,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final dropdownIconSize = Responsive.iconSize(context, 16);
    final dropdownPaddingH = Responsive.spacing(context, 12);

    return Container(
      padding: EdgeInsets.symmetric(horizontal: dropdownPaddingH),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: AccessibleDropdown<T>(
          value: value,
          isExpanded: true,
          icon: Icon(
            LucideIcons.chevronDown,
            size: dropdownIconSize,
            color: colors.textMuted,
          ),
          dropdownColor: colors.surface,
          style: SkotiqTypography.bodySm.copyWith(
            color: colors.textPrimary,
          ),
          items: items.map((item) {
            return DropdownMenuItem(
              value: item,
              child: Text(labelBuilder(item)),
            );
          }).toList(),
          onChanged: (newValue) {
            if (newValue != null) onChanged(newValue);
          },
        ),
      ),
    );
  }
}

class NodeDangerButton extends StatefulWidget {
  final SkotiqColors colors;
  final String label;
  final IconData icon;
  // Nullable so callers can disable the button when the sequence is
  // locked (e.g. running). `_NodeDangerButtonState` swallows clicks when
  // onPressed is null.
  final VoidCallback? onPressed;

  const NodeDangerButton({
    super.key,
    required this.colors,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  @override
  State<NodeDangerButton> createState() => _NodeDangerButtonState();
}

class _NodeDangerButtonState extends State<NodeDangerButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final btnIconSize = Responsive.iconSize(context, 15);
    final btnPaddingV = Responsive.spacing(context, 12);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: EdgeInsets.symmetric(vertical: btnPaddingV),
          decoration: BoxDecoration(
            color: _isHovered
                ? SkotiqDecorations.tintedBadge(
                    widget.colors.error,
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                  ).color
                : Colors.transparent,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            border: Border.all(
              color: _isHovered ? widget.colors.error : widget.colors.border,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                widget.icon,
                size: btnIconSize,
                color: _isHovered
                    ? widget.colors.error
                    : widget.colors.textSecondary,
              ),
              SizedBox(width: Responsive.spacing(context, 8)),
              Text(
                widget.label,
                style: SkotiqTypography.buttonSm.copyWith(
                  color: _isHovered
                      ? widget.colors.error
                      : widget.colors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Responsive section header used consistently across all property panels.
///
/// Replaces the ad-hoc `Text(..., fontSize: SkotiqTypography.fontSize12, fontWeight: w600)` pattern
/// with a single widget that scales for high-res desktop displays.
class NodeSectionHeader extends StatelessWidget {
  final SkotiqColors colors;
  final String label;

  const NodeSectionHeader({
    super.key,
    required this.colors,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: SkotiqTypography.bodySm.copyWith(
        fontWeight: FontWeight.w600,
        color: colors.textPrimary,
      ),
    );
  }
}
