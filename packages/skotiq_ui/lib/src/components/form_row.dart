import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';

/// A labelled control: the label sits to the LEFT in a fixed column, not above
/// the field.
///
/// A label above its field costs a whole line of height per setting and turns
/// a dense panel into a scroll. Beside it, the labels line up into a readable
/// column and the controls line up into another, which is what makes a form of
/// twelve rows scannable.
///
/// The exception is [stacked]: a value that is routinely longer than the
/// control column (a folder, a file-name pattern) goes under its label at the
/// form's full width, rather than cut to a few characters beside it.
class FormRow extends StatelessWidget {
  const FormRow({
    super.key,
    required this.label,
    required this.child,
    this.labelWidth = defaultLabelWidth,
    this.help,
    this.stacked = false,
  });

  /// The label, in `textSecondary` at 13.
  final String label;

  final Widget child;

  /// Width of the label column. The spec's range is 84–104; pick one width per
  /// form and keep it for every row in that form.
  ///
  /// The row CLAMPS this to what it has: a side panel that animates open from
  /// 48 to 300px spends every frame of that 220ms narrower than the label
  /// column, and a fixed column in a `Row` that narrow overflows on every one
  /// of them. Below [minControlWidth] of remaining width the label gives way,
  /// down to [minLabelWidth]. Sequencer's `NodePropertyField` was clamping to
  /// 40% of the pane itself for exactly this reason; that belongs here, where
  /// every form gets it.
  final double labelWidth;

  /// One short line under the control. Use sparingly — most rows do not need
  /// one, and a form of explanations is a form nobody reads.
  final String? help;

  /// The label above the control, which then takes the form's full width.
  final bool stacked;

  /// The default label column width in logical pixels (`observatory.css`
  /// `.form .row` grid column).
  static const double defaultLabelWidth = 96;

  /// Gap between the label column and the control.
  static const double columnGap = SkotiqTokens.spaceMd;

  /// Vertical gap between rows of a form.
  static const double rowGap = 10;

  /// The narrowest the label column may be squeezed to before the control
  /// starts giving way instead.
  static const double minLabelWidth = 40;

  /// The width the control keeps while the label is being squeezed.
  static const double minControlWidth = 72;

  /// The label column width [FormRow] will actually use inside [maxWidth].
  ///
  /// Public so a caller that lays out its own label column beside a form can
  /// line up with it instead of guessing.
  static double resolveLabelWidth(double requested, double maxWidth) {
    if (!maxWidth.isFinite) return requested;
    final available = maxWidth - columnGap - minControlWidth;
    if (available >= requested) return requested;
    return math.max(minLabelWidth, math.min(requested, available));
  }

  @override
  Widget build(BuildContext context) {
    if (stacked) return _stacked(context);
    return LayoutBuilder(
      builder: (context, constraints) =>
          _row(context, resolveLabelWidth(labelWidth, constraints.maxWidth)),
    );
  }

  Widget _label(BuildContext context) => Text(
    label,
    style: SkotiqTypography.bodySm.copyWith(
      color: context.skotiqColors.textSecondary,
    ),
  );

  Widget _stacked(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _label(context),
        const SizedBox(height: SkotiqTokens.spaceXs),
        child,
        if (help != null) ...<Widget>[
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            help!,
            style: SkotiqTypography.caption.copyWith(
              color: context.skotiqColors.textMuted,
            ),
          ),
        ],
      ],
    );
  }

  Widget _row(BuildContext context, double labelWidth) {
    final colors = context.skotiqColors;
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        SizedBox(
          width: labelWidth,
          child: Align(alignment: Alignment.centerLeft, child: _label(context)),
        ),
        const SizedBox(width: columnGap),
        Expanded(child: child),
      ],
    );

    if (help == null) return row;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        row,
        const SizedBox(height: SkotiqTokens.spaceXs),
        Padding(
          padding: EdgeInsets.only(left: labelWidth + columnGap),
          child: Text(
            help!,
            style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
        ),
      ],
    );
  }
}
