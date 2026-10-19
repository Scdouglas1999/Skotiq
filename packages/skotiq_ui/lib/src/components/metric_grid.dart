import 'package:flutter/material.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_typography.dart';
import 'readout.dart';

/// Emphasis for a [MetricGridItem]'s value or delta.
enum MetricGridTone { neutral, good, warning, bad }

/// One cell of a [MetricGrid].
@immutable
class MetricGridItem {
  const MetricGridItem({
    required this.label,
    this.value,
    this.delta,
    this.deltaTone = MetricGridTone.neutral,
    this.valueTone = MetricGridTone.neutral,
  });

  final String label;

  /// The value with its unit. Null renders [kReadoutUnknown].
  final String? value;

  /// A change beside the label, e.g. "−0.04" against the night median. Null
  /// leaves it out.
  final String? delta;

  final MetricGridTone deltaTone;
  final MetricGridTone valueTone;

  @override
  bool operator ==(Object other) =>
      other is MetricGridItem &&
      other.label == label &&
      other.value == value &&
      other.delta == delta &&
      other.deltaTone == deltaTone &&
      other.valueTone == valueTone;

  @override
  int get hashCode => Object.hash(label, value, delta, deltaTone, valueTone);
}

/// A dense grid of small readouts: the last frame's figures, the session's
/// counts and the sky's conditions in the Tonight side panel.
///
/// Each cell is a [ReadoutSize.sm] [Readout] over its label, with an optional
/// delta after the label in its tone's color. Labels keep the caller's case,
/// not a readout's capitals: at four columns in a 300 px panel "DEW POINT"
/// ellipsized where "Dew point" fits. Cells take equal widths, so the
/// columns line up from row to row, and a value too long for its cell
/// ellipsizes instead of pushing the grid wider.
class MetricGrid extends StatelessWidget {
  const MetricGrid({
    super.key,
    required this.items,
    this.columns = 4,
    this.semanticLabel,
  }) : assert(columns > 0);

  final List<MetricGridItem> items;
  final int columns;

  /// Names the group for assistive technology, e.g. "Last frame". Each cell
  /// still reads as its own value and label.
  final String? semanticLabel;

  /// Gap between columns.
  static const double columnGap = 6;

  /// Gap between rows.
  static const double rowGap = 5;

  /// The color [tone] gives a value: `textPrimary` when neutral.
  static Color valueColor(MetricGridTone tone, SkotiqColors colors) =>
      switch (tone) {
        MetricGridTone.neutral => colors.textPrimary,
        MetricGridTone.good => colors.success,
        MetricGridTone.warning => colors.warning,
        MetricGridTone.bad => colors.error,
      };

  /// The color [tone] gives a delta: `textMuted` when neutral, so a delta
  /// that says nothing stays as quiet as its label.
  static Color deltaColor(MetricGridTone tone, SkotiqColors colors) =>
      tone == MetricGridTone.neutral
      ? colors.textMuted
      : valueColor(tone, colors);

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final rows = <Widget>[];
    for (var start = 0; start < items.length; start += columns) {
      if (rows.isNotEmpty) rows.add(const SizedBox(height: rowGap));
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (var c = 0; c < columns; c++) ...<Widget>[
              if (c > 0) const SizedBox(width: columnGap),
              Expanded(
                child: start + c < items.length
                    ? _MetricCell(item: items[start + c], colors: colors)
                    : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      );
    }

    final grid = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
    if (semanticLabel == null) return grid;
    return Semantics(container: true, label: semanticLabel, child: grid);
  }
}

class _MetricCell extends StatelessWidget {
  const _MetricCell({required this.item, required this.colors});

  final MetricGridItem item;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    final labelStyle = SkotiqTypography.readoutLabel.copyWith(
      color: colors.textMuted,
    );
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Readout(
            value: item.value,
            size: ReadoutSize.sm,
            valueColor: MetricGrid.valueColor(item.valueTone, colors),
          ),
          const SizedBox(height: Readout.labelGap),
          Text.rich(
            TextSpan(
              text: item.label,
              children: <InlineSpan>[
                if (item.delta != null)
                  TextSpan(
                    text: ' ${item.delta}',
                    style: labelStyle.copyWith(
                      color: MetricGrid.deltaColor(item.deltaTone, colors),
                    ),
                  ),
              ],
            ),
            style: labelStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
