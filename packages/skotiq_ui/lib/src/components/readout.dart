import 'package:flutter/material.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';

/// The three readout scales: `lg` 28, `md` 20, `sm` 14.
enum ReadoutSize {
  /// 28px — hero numbers (sensor temperature on Equipment, HFR in a glance
  /// HUD).
  lg,

  /// 20px — the standard readout.
  md,

  /// 14px — readouts in dense rows and key/value lists.
  sm,
}

/// The em dash a readout shows when it has no value.
///
/// Never `---`, never `--:--`: those read as a value that happens to be
/// punctuation. One dash in muted grey reads as "not known".
const String kReadoutUnknown = '—';

/// A readout: a loud mono value over a quiet uppercase label.
///
/// The value is [SkotiqTypography.readoutLg]/`Md`/`Sm` in `textPrimary`
/// with tabular figures, the [unit] is the same style at 60% size in
/// `textMuted` attached with a 2px gap, and the [label] is
/// [SkotiqTypography.readoutLabel] in `textMuted` beneath it.
///
/// A null [value] renders [kReadoutUnknown] in `textMuted`; a screen never has
/// to invent a placeholder string of its own.
class Readout extends StatelessWidget {
  const Readout({
    super.key,
    required this.value,
    this.label,
    this.unit,
    this.size = ReadoutSize.md,
    this.valueColor,
  });

  /// The value. Null renders the em dash in `textMuted`.
  final String? value;

  /// The label beneath the value. Rendered uppercase.
  ///
  /// Null means there is no label AND no row reserved for one — the value is
  /// the whole widget. That is the case where the value already has a label
  /// beside it: the number at the centre of Tonight's progress ring, a value
  /// inside a `FormRow` whose label column has already named it. Without this
  /// those call sites reached for a bare `readoutMd` `Text` and lost the
  /// tabular figures and the muted unit with it.
  final String? label;

  /// An optional unit attached to the value at 60% size in `textMuted`.
  final String? unit;

  /// Which of the three scales to use.
  final ReadoutSize size;

  /// Overrides the value colour — a status colour on a value that carries
  /// status. Ignored when [value] is null, which is always muted.
  final Color? valueColor;

  /// Gap between the value baseline row and the label.
  static const double labelGap = 2;

  /// Gap between the value and its unit.
  static const double unitGap = 2;

  /// The proportion of the value size a unit is drawn at.
  static const double unitScale = 0.6;

  TextStyle get _valueStyle => switch (size) {
    ReadoutSize.lg => SkotiqTypography.readoutLg,
    ReadoutSize.md => SkotiqTypography.readoutMd,
    ReadoutSize.sm => SkotiqTypography.readoutSm,
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final unknown = value == null;
    final valueStyle = _valueStyle.copyWith(
      color: unknown ? colors.textMuted : (valueColor ?? colors.textPrimary),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text.rich(
          TextSpan(
            text: unknown ? kReadoutUnknown : value,
            children: <InlineSpan>[
              if (!unknown && unit != null) ...<InlineSpan>[
                const WidgetSpan(child: SizedBox(width: unitGap)),
                TextSpan(
                  text: unit,
                  // A unit is part of the number, not a second field, so it
                  // scales WITH the value — `apply(fontSizeFactor:)`, never a
                  // fontSize literal.
                  style: valueStyle.apply(
                    fontSizeFactor: unitScale,
                    fontWeightDelta: -1,
                    color: colors.textMuted,
                  ),
                ),
              ],
            ],
          ),
          style: valueStyle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (label != null) ...<Widget>[
          const SizedBox(height: labelGap),
          Text(
            label!.toUpperCase(),
            style: SkotiqTypography.readoutLabel.copyWith(
              color: colors.textMuted,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

/// A horizontal run of [Readout]s, top-aligned, with a 28px default gap.
///
/// Each readout takes the width its own words need. A `Row` of `Flexible`
/// children does not: flex splits the free space EQUALLY, so three readouts in
/// a 320px side panel got 69px each and "INTEGRATION" ellipsized while the
/// three of them together fitted with room to spare.
///
/// When the run genuinely does not fit, it wraps to a second line rather than
/// truncating — 07's rule is to reduce content or let it flow, never to shrink
/// what a number says. A single readout wider than the whole row still
/// ellipsizes, because at that point there is nowhere else for it to go.
class ReadoutRow extends StatelessWidget {
  const ReadoutRow({super.key, required this.children, this.gap = 28});

  /// The readouts, in reading order.
  final List<Readout> children;

  /// Horizontal gap between readouts.
  final double gap;

  /// Vertical gap between wrapped lines.
  static const double runGap = SkotiqTokens.spaceSm;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: gap,
      runSpacing: runGap,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: children,
    );
  }
}

/// A two-column key/value block: a 13px `textSecondary` key on the left and a
/// right-aligned mono value on the right.
///
/// Used where a panel lists facts that are not measurements loud enough to
/// deserve a [Readout] — weather figures, a target's catalogue entry.
class KeyValueList extends StatelessWidget {
  const KeyValueList({super.key, required this.rows});

  /// The rows, in reading order.
  final List<(String key, String value)> rows;

  /// Vertical gap between rows.
  static const double rowGap = 6;

  /// Minimum gap between a key and its value.
  static const double columnGap = SkotiqTokens.spaceLg;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var i = 0; i < rows.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: rowGap),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  rows[i].$1,
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: columnGap),
              Text(
                rows[i].$2,
                textAlign: TextAlign.right,
                style: SkotiqTypography.readoutSm.copyWith(
                  color: colors.textPrimary,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
