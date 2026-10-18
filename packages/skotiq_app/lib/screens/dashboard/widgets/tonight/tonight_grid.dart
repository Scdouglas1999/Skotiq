// The 12-column grid Tonight's panels live in (06 §Tonight, "Grid").
//
// The panels are registry tiles, so this lays out whatever Edit layout has
// enabled, in the order Edit layout put them in, at the width each tile's size
// asks for. Nothing here knows what a panel contains.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../dashboard_layout.dart';
import '../dashboard_tile.dart';
import '../dashboard_widget_registry.dart';

/// The grid's column count and gap (06 §Tonight: 12 columns, 16 gap).
const int kTonightGridColumns = 12;
const double kTonightGridGap = SkotiqTokens.spaceLg;

/// Below this the grid collapses to one column.
///
/// The shell's own narrow breakpoint, not a number of this file's own: below it
/// the rail is already a bottom nav and the page header has shrunk, and a c4
/// panel there is ~180 px — narrower than the readout row inside it.
const double _singleColumnWidth = ShellChromeMetrics.shellLayoutBreakpoint;

/// Lays [tiles] out across [kTonightGridColumns], wrapping when a row is full.
class TonightGrid extends ConsumerWidget {
  const TonightGrid({
    super.key,
    required this.tiles,
    required this.colors,
    required this.pulseController,
    required this.isEditing,
    required this.onReorder,
    required this.onResize,
    required this.onToggleEnabled,
  });

  final List<DashboardTileConfig> tiles;
  final SkotiqColors colors;
  final AnimationController pulseController;
  final bool isEditing;
  final void Function(DashboardWidgetId dragged, DashboardWidgetId target)
      onReorder;
  final void Function(DashboardWidgetId id) onResize;
  final void Function(DashboardWidgetId id, bool enabled) onToggleEnabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registry = {for (final def in dashboardWidgetRegistry) def.id: def};
    final visible = tiles
        .where((tile) => tile.enabled && registry.containsKey(tile.widgetId))
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));

    if (visible.isEmpty) return const SizedBox.shrink();

    final preferences = <DashboardWidgetId, double? Function(double)>{
      for (final tile in visible)
        if (registry[tile.widgetId]!.preferredWidth case final preference?)
          tile.widgetId: preference(ref),
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final narrow = width < _singleColumnWidth;
        final columnWidth =
            (width - kTonightGridGap * (kTonightGridColumns - 1)) /
                kTonightGridColumns;

        double widthFor(int span) =>
            columnWidth * span + kTonightGridGap * (span - 1);

        final rows = <List<(DashboardTileConfig, int)>>[];
        var current = <(DashboardTileConfig, int)>[];
        var used = 0;

        for (final tile in visible) {
          final span = narrow
              ? kTonightGridColumns
              : tile.size.columnSpan.clamp(1, kTonightGridColumns);
          if (used + span > kTonightGridColumns && current.isNotEmpty) {
            rows.add(current);
            current = <(DashboardTileConfig, int)>[];
            used = 0;
          }
          current.add((tile, span));
          used += span;
        }
        if (current.isNotEmpty) rows.add(current);

        // A tile that asks for less than its span (the preview, sized to its
        // frame) gives the rest to the tiles beside it, in proportion to their
        // spans, rather than leaving it as dead space inside itself. Not while
        // editing: the resize handles must show the spans as configured.
        List<double> widthsFor(List<(DashboardTileConfig, int)> row) {
          final widths = [for (final cell in row) widthFor(cell.$2)];
          if (narrow || isEditing || row.length < 2) return widths;
          var slack = 0.0;
          final absorbing = <int>[];
          for (var i = 0; i < row.length; i++) {
            final preference = preferences[row[i].$1.widgetId]?.call(
              widths[i],
            );
            if (preference != null && preference < widths[i]) {
              slack += widths[i] - preference;
              widths[i] = preference;
            } else if (preference == null) {
              absorbing.add(i);
            }
          }
          if (slack == 0) return widths;
          if (absorbing.isEmpty) {
            return [for (final cell in row) widthFor(cell.$2)];
          }
          final absorbingSpan =
              absorbing.fold<int>(0, (sum, i) => sum + row[i].$2);
          for (final i in absorbing) {
            widths[i] += slack * row[i].$2 / absorbingSpan;
          }
          return widths;
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (var r = 0; r < rows.length; r++) ...<Widget>[
              if (r > 0) const SizedBox(height: kTonightGridGap),
              _row(rows[r], widthsFor(rows[r]), registry),
            ],
          ],
        );
      },
    );
  }

  Widget _row(
    List<(DashboardTileConfig, int)> row,
    List<double> widths,
    Map<DashboardWidgetId, DashboardWidgetDefinition> registry,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (var c = 0; c < row.length; c++) ...<Widget>[
          if (c > 0) const SizedBox(width: kTonightGridGap),
          SizedBox(width: widths[c], child: _tile(row[c].$1, registry)),
        ],
      ],
    );
  }

  Widget _tile(
    DashboardTileConfig tile,
    Map<DashboardWidgetId, DashboardWidgetDefinition> registry,
  ) {
    final definition = registry[tile.widgetId]!;
    return DashboardTile(
      tile: tile,
      width: double.infinity,
      colors: colors,
      isEditing: isEditing,
      isHero: false,
      selfChromed: definition.selfChromed,
      onReorder: onReorder,
      onResize: onResize,
      onToggleEnabled: onToggleEnabled,
      child: Builder(
        builder: (context) =>
            definition.builder(context, colors, pulseController),
      ),
    );
  }
}
