import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../theme/skotiq_tokens.dart';

/// One cell of an [AdaptiveColumns] grid.
@immutable
class AdaptiveCell {
  const AdaptiveCell({required this.minWidth, required this.child});

  /// The width [child] needs to show its content in full, in logical pixels.
  ///
  /// Measured, never guessed: `SkotiqButton.measureWidth` for a button,
  /// `measureTextWidth` for anything else. A dp threshold cannot be right,
  /// because what fits depends on the words (a mount reports "Start tracking"
  /// or "Stop tracking" at different widths), on the locale and on the
  /// reader's text scale.
  final double minWidth;

  /// The cell's content. Laid out at the column width, which is at least
  /// [minWidth].
  final Widget child;
}

/// Lays [cells] out in as many equal columns as their measured widths allow,
/// and stacks them full-width when not even two fit.
///
/// The alternative — a fixed `Row` of `Expanded` cells — splits whatever room
/// there is equally and lets each child ellipsise its own label. In the
/// Imaging side panel (a 320px column, 216px inside a section card) that is
/// exactly how "Unpark" and "Start tracking" became "U…" and "St…": the row
/// was still a valid layout, so nothing anywhere reported a problem.
///
/// The widest cell sets the column width, so no single cell is the one that
/// truncates, and a short final run keeps the grid's columns rather than
/// stretching across the gap.
class AdaptiveColumns extends StatelessWidget {
  const AdaptiveColumns({
    super.key,
    required this.cells,
    this.spacing = SkotiqTokens.spaceSm,
    this.runSpacing = SkotiqTokens.spaceSm,
    this.maxColumns,
  });

  /// The cells, in reading order.
  final List<AdaptiveCell> cells;

  /// Horizontal gap between columns.
  final double spacing;

  /// Vertical gap between rows, including the gap between stacked cells.
  final double runSpacing;

  /// Caps the column count however much room there is — for a grid whose
  /// pairing is meaningful (RA beside Dec) rather than a free-flowing run.
  final int? maxColumns;

  /// How many equal columns of [cellWidth] fit in [available].
  ///
  /// Always at least one: a cell wider than the whole row has nowhere else to
  /// go, and a stacked full-width cell truncates later than a shared one.
  static int columnsThatFit({
    required double available,
    required double cellWidth,
    required double spacing,
    required int cellCount,
  }) {
    var columns = cellCount;
    while (columns > 1 &&
        columns * cellWidth + (columns - 1) * spacing > available) {
      columns--;
    }
    return columns;
  }

  @override
  Widget build(BuildContext context) {
    if (cells.isEmpty) return const SizedBox.shrink();
    final widest = cells
        .map((AdaptiveCell cell) => cell.minWidth)
        .reduce(math.max);
    final cap = math.min(maxColumns ?? cells.length, cells.length);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // An unbounded row (a `Row` with no `Expanded` above us) has no width
        // to divide, so the cells take the width they measured and the caller
        // gets the intrinsic layout it asked for.
        if (!constraints.hasBoundedWidth) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (var i = 0; i < cells.length; i++) ...<Widget>[
                if (i > 0) SizedBox(width: spacing),
                SizedBox(width: cells[i].minWidth, child: cells[i].child),
              ],
            ],
          );
        }

        final columns = columnsThatFit(
          available: constraints.maxWidth,
          cellWidth: widest,
          spacing: spacing,
          cellCount: cap,
        );

        final rows = <Widget>[];
        for (var start = 0; start < cells.length; start += columns) {
          final end = math.min(start + columns, cells.length);
          final children = <Widget>[];
          for (var i = start; i < end; i++) {
            if (i > start) children.add(SizedBox(width: spacing));
            children.add(Expanded(child: cells[i].child));
          }
          for (var i = end; i < start + columns; i++) {
            children
              ..add(SizedBox(width: spacing))
              ..add(const Expanded(child: SizedBox.shrink()));
          }
          rows.add(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          );
        }

        if (rows.length == 1) return rows.single;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (var i = 0; i < rows.length; i++) ...<Widget>[
              if (i > 0) SizedBox(height: runSpacing),
              rows[i],
            ],
          ],
        );
      },
    );
  }
}
