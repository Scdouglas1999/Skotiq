import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';

/// Custom checkbox matching Skotiq theme semantics.
class SkotiqCheckbox extends StatefulWidget {
  final bool value;
  final ValueChanged<bool?>? onChanged;

  const SkotiqCheckbox({super.key, required this.value, this.onChanged});

  @override
  State<SkotiqCheckbox> createState() => _SkotiqCheckboxState();
}

class _SkotiqCheckboxState extends State<SkotiqCheckbox> {
  bool _isFocused = false;

  /// The outline of an UNCHECKED box, which is the whole of that state.
  ///
  /// NOT `colors.border`. That token is the palette's DIVIDER weight, chosen to
  /// sit just off its surface, and measured against the surfaces a checkbox
  /// lands on it runs 1.21:1 in red night (1.03:1 on `surfaceElevated`, the
  /// delivery destination editor's dialog, where an unchecked box rendered as a
  /// label with nothing beside it), 1.25:1 in light and 1.58:1 in dark — all far
  /// under the 3:1 WCAG 1.4.11 sets for the boundary of a control. A checked box
  /// has a fill and a tick to be seen by; an unchecked one has this line and
  /// nothing else, so when it disappears the option disappears with it.
  ///
  /// `textSecondary` is the answer the palettes already carry: every one of them
  /// holds its text ladder to a contrast floor, so the worst case here is 4.74:1
  /// (light on white) and red night's is 7.46:1 — and it stays inside the
  /// wavelength rule that palette exists for, which a hand-picked grey would
  /// not. It is also what Material draws an unselected checkbox with
  /// (`onSurfaceVariant`), so the weight is familiar rather than novel.
  ///
  /// Disabled keeps the quieter `textMuted` (2.78:1 worst case). WCAG exempts an
  /// inactive control from the floor, but exempt is not invisible: the operator
  /// still has to see that the option exists and is off before they can work out
  /// why it will not move.
  Color _uncheckedOutline(
    SkotiqColors colors, {
    required bool isDisabled,
  }) => isDisabled ? colors.textMuted : colors.textSecondary;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final isDisabled = widget.onChanged == null;
    final checkColor = colors.onPrimary;

    void toggle() => widget.onChanged!(!widget.value);

    // A checkbox must publish its checked state and be focusable: a bare
    // GestureDetector reports neither, and a control a keyboard cannot reach is
    // a control some users do not have.
    return Semantics(
      checked: widget.value,
      enabled: !isDisabled,
      onTap: isDisabled ? null : toggle,
      child: FocusableActionDetector(
        enabled: !isDisabled,
        mouseCursor: isDisabled
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        onShowFocusHighlight: (focused) => setState(() => _isFocused = focused),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              toggle();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: isDisabled ? null : toggle,
          // See skotiq_switch.dart: a second tap node here reads to AT-SPI
          // as an unnamed disabled panel beside the checkbox.
          excludeFromSemantics: true,
          child: AnimatedContainer(
            duration: SkotiqTokens.durationQuick,
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: widget.value
                  ? (isDisabled ? colors.surfaceHover : colors.primary)
                  : Colors.transparent,
              borderRadius: SkotiqTokens.borderRadiusXs,
              border: Border.all(
                color: _isFocused
                    ? colors.primary
                    : widget.value
                    ? (isDisabled ? colors.border : colors.primary)
                    : _uncheckedOutline(colors, isDisabled: isDisabled),
                width: 2,
              ),
            ),
            child: widget.value
                ? Icon(
                    LucideIcons.check,
                    size: 12,
                    color: isDisabled ? colors.textMuted : checkColor,
                  )
                : null,
          ),
        ),
      ),
    );
  }
}
