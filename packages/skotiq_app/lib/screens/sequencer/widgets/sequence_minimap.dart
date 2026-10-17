import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'sequence_tree.dart'
    show nodeCategoryTint, revealSequenceRow, treeNodeKeyRegistryProvider;
import 'sequence_tree_shortcuts.dart'
    show VisibleNode, visibleNodeOrderProvider;

/// One row of the sequence overview.
///
/// The 80 px strip below the tree and the Ledger gutter at its right edge draw
/// the SAME list of entries through the SAME painter; only the box they are
/// given differs. Anything that changes how a step reads in one of them has to
/// change it in the other, so both live here.
@immutable
class SequenceMapEntry {
  final SequenceNode node;
  final int depth;

  const SequenceMapEntry({required this.node, required this.depth});
}

/// The rows the tree is currently drawing, in draw order.
///
/// Built from [visibleNodeOrderProvider] — the single collapsed-aware order the
/// tree, the arrow keys and the search share — so a map block can never point
/// at a row the tree is not showing.
List<SequenceMapEntry> sequenceMapEntries(
  Sequence sequence,
  List<VisibleNode> order,
) {
  return <SequenceMapEntry>[
    for (final row in order)
      if (sequence.nodes[row.id] case final node?)
        SequenceMapEntry(node: node, depth: row.depth),
  ];
}

/// The index of the row a point [dy] down a map of [extent] pixels stands for.
int sequenceMapRowAt(double dy, double extent, int rowCount) {
  if (rowCount <= 0 || extent <= 0) return 0;
  return (dy / extent * rowCount).floor().clamp(0, rowCount - 1);
}

/// The scroll metrics a map may safely read, or null while the tree's position
/// has not been laid out yet.
///
/// Both maps build inside a `LayoutBuilder`, which runs BEFORE the scroll view
/// beside them has been given its dimensions on the very first frame; reading
/// `maxScrollExtent` there throws rather than returning zero.
({double offset, double viewportDimension, double maxScrollExtent})?
    sequenceMapMetrics(ScrollController controller) {
  if (!controller.hasClients) return null;
  final position = controller.position;
  if (!position.hasPixels ||
      !position.hasContentDimensions ||
      !position.hasViewportDimension) {
    return null;
  }
  return (
    offset: position.pixels,
    viewportDimension: position.viewportDimension,
    maxScrollExtent: position.maxScrollExtent,
  );
}

/// The rectangle inside a map of [size] that stands for what the tree's
/// viewport is currently showing.
///
/// Pure so both maps — and the tests — agree on where the indicator sits
/// without owning a scroll position. Returns null when the content fits and
/// there is nothing to indicate.
Rect? sequenceMapViewportRect({
  required double offset,
  required double viewportDimension,
  required double maxScrollExtent,
  required Size size,
}) {
  if (maxScrollExtent <= 0 || viewportDimension <= 0) return null;
  final totalContentHeight = maxScrollExtent + viewportDimension;
  final top = (offset / totalContentHeight) * size.height;
  final height = (viewportDimension / totalContentHeight) * size.height;
  // The 8 px readability floor cannot exceed the strip it sits in — a map
  // under 8 px tall would invert the bounds and throw out of paint().
  return Rect.fromLTWH(
    0,
    top,
    size.width,
    height.clamp(
        math.min(_viewportIndicatorMinExtent, size.height), size.height),
  );
}

/// Select the row at [index] and bring it on screen.
///
/// Routes through the tree's GlobalKey registry so the map lands exactly on
/// the row, mirroring the auto-follow path — proportional scroll only
/// approximated the position and drifted on collapsed / variable-height rows.
/// Falls back to proportional scroll while the registry or the key is not
/// mounted yet.
void navigateToSequenceMapRow(
  BuildContext context,
  WidgetRef ref,
  List<SequenceMapEntry> entries,
  int index,
  ScrollController scrollController,
) {
  if (entries.isEmpty) return;
  final row = entries[index.clamp(0, entries.length - 1)];

  ref.read(multiSelectedNodeIdsProvider.notifier).clear();
  ref.read(selectedNodeIdProvider.notifier).state = row.node.id;

  // The map's jump and the tree's own follow-execution scroll travel on the
  // same token (spec §9): they are the same movement, started by two different
  // hands, and a map that scrolled at a different speed from the run would
  // read as a different kind of navigation.
  final duration = animationDuration(context, _navigateDuration);
  final key = ref.read(treeNodeKeyRegistryProvider)?[row.node.id];
  if (key?.currentContext != null) {
    revealSequenceRow(
      key!.currentContext!,
      duration: _navigateDuration,
      alignment: _navigateAlignment,
    );
    return;
  }

  if (scrollController.hasClients) {
    final maxScroll = scrollController.position.maxScrollExtent;
    scrollController.animateTo(
      maxScroll * (index / entries.length),
      duration: duration,
      curve: SkotiqTokens.curveStandard,
    );
  }
}

/// Shortest readable jump for a navigation the user asked for by clicking a
/// position, matching the tree's own auto-follow scroll.
const Duration _navigateDuration = SkotiqTokens.durationSlow;

/// Land the row ~30 % from the top so its children are visible under it.
const double _navigateAlignment = 0.3;

/// Below this the viewport indicator stops being a grabbable thing.
const double _viewportIndicatorMinExtent = 8.0;

/// A small thumbnail overview of the sequence tree, rendered as colored blocks.
/// Shows a viewport indicator for the currently visible region and highlights
/// the executing node. Click to navigate to that position in the tree.
///
/// The Comfortable and Compact shape of the overview the canvas bar toggles
/// through `sequenceOverviewVisibleProvider`; Ledger draws the same map as a
/// gutter at the tree's right edge instead.
class SequenceMinimap extends ConsumerWidget {
  final SkotiqColors colors;
  final ScrollController scrollController;

  const SequenceMinimap({
    super.key,
    required this.colors,
    required this.scrollController,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sequence = ref.watch(currentSequenceProvider);
    if (sequence == null || sequence.rootNode == null) {
      return const SizedBox.shrink();
    }

    final progress = ref.watch(sequenceProgressProvider);
    final selectedId = ref.watch(selectedNodeIdProvider);
    final entries =
        sequenceMapEntries(sequence, ref.watch(visibleNodeOrderProvider));
    if (entries.isEmpty) return const SizedBox.shrink();

    return Container(
      height: 80,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return GestureDetector(
            onTapDown: (details) => navigateToSequenceMapRow(
              context,
              ref,
              entries,
              sequenceMapRowAt(
                details.localPosition.dy,
                constraints.maxHeight,
                entries.length,
              ),
              scrollController,
            ),
            child: CustomPaint(
              size: Size(constraints.maxWidth, constraints.maxHeight),
              painter: SequenceMapPainter(
                colors: colors,
                entries: entries,
                progress: progress,
                selectedId: selectedId,
                scrollController: scrollController,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Paints one block per visible row, the selection outline, the viewport
/// indicator and the execution marker.
///
/// Shared by [SequenceMinimap] and the Ledger gutter: the gutter is this
/// painter in a tall, narrow box rather than a short, wide one.
class SequenceMapPainter extends CustomPainter {
  final SkotiqColors colors;
  final List<SequenceMapEntry> entries;
  final SequenceProgress progress;
  final String? selectedId;
  final ScrollController scrollController;

  SequenceMapPainter({
    required this.colors,
    required this.entries,
    required this.progress,
    required this.selectedId,
    required this.scrollController,
  }) : super(repaint: scrollController);

  /// Share of the map's width the deepest row indents by, so nesting reads
  /// without any row losing its block entirely.
  static const double _depthIndentFraction = 0.15;

  /// Blocks sit under the viewport indicator, so they are drawn softened.
  static const double _blockAlpha = 0.6;

  @override
  void paint(Canvas canvas, Size size) {
    if (entries.isEmpty) return;

    final rowHeight = size.height / entries.length;
    final maxDepth = entries.fold<int>(
        0, (max, entry) => entry.depth > max ? entry.depth : max);
    final depthWidth = maxDepth > 0 ? size.width * _depthIndentFraction : 0.0;

    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final indent =
          maxDepth > 0 ? (entry.depth / (maxDepth + 1)) * depthWidth : 0.0;

      // The map colours a step exactly as its row's glyph does, so a block and
      // the row it stands for are recognisably the same step.
      var blockColor = nodeCategoryTint(entry.node.category, colors);
      if (!entry.node.isEnabled) {
        blockColor =
            blockColor.withValues(alpha: SkotiqTokens.opacityMedium);
      }

      // Run state outranks category: while a run is on, where it is and what
      // it has already done is the only thing the strip is being read for.
      switch (progress.nodeStatuses[entry.node.id]) {
        case NodeStatus.running:
          blockColor = colors.primary;
        case NodeStatus.success:
          blockColor =
              colors.success.withValues(alpha: SkotiqTokens.opacityMuted);
        case NodeStatus.failure:
          blockColor = colors.error;
        case _:
          break;
      }

      final rect = Rect.fromLTWH(
        indent,
        i * rowHeight,
        size.width - indent,
        (rowHeight - 1).clamp(1, double.infinity),
      );

      canvas.drawRect(
        rect,
        Paint()
          ..color = blockColor.withValues(alpha: _blockAlpha)
          ..style = PaintingStyle.fill,
      );

      if (entry.node.id == selectedId) {
        canvas.drawRect(
          rect,
          Paint()
            ..color = colors.primary
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
    }

    _paintViewport(canvas, size);

    if (progress.currentNodeId != null) {
      final execIndex =
          entries.indexWhere((e) => e.node.id == progress.currentNodeId);
      if (execIndex >= 0) {
        final y = execIndex * rowHeight + rowHeight / 2;
        canvas.drawLine(
          Offset(0, y),
          Offset(size.width, y),
          Paint()
            ..color = colors.info
            ..strokeWidth = 2.0,
        );
      }
    }
  }

  /// The tint + hairline that says which rows are on screen.
  ///
  /// A fill rather than a scrim over everything else: the gutter is 34 px wide
  /// and permanently on screen, so dimming the majority of it would make the
  /// map read as disabled rather than as positioned.
  ///
  /// The fill is [SkotiqTokens.opacityMedium], not the accent tint the
  /// rest of the language uses for a selected surface: this rectangle is read
  /// across an 80 px strip of primary-coloured row blocks, and at 12 % of the
  /// same hue it disappeared into them. The `borderHighlight` hairline just
  /// outside the accent stroke is what stops the two primaries from touching,
  /// so the edge stays an edge wherever the viewport happens to sit.
  void _paintViewport(Canvas canvas, Size size) {
    final metrics = sequenceMapMetrics(scrollController);
    if (metrics == null) return;
    final rect = sequenceMapViewportRect(
      offset: metrics.offset,
      viewportDimension: metrics.viewportDimension,
      maxScrollExtent: metrics.maxScrollExtent,
      size: size,
    );
    if (rect == null) return;

    canvas.drawRect(
      rect,
      Paint()
        ..color =
            colors.primary.withValues(alpha: SkotiqTokens.opacityMedium)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRect(
      rect.inflate(0.5),
      Paint()
        ..color = colors.borderHighlight
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
    canvas.drawRect(
      rect.deflate(0.5),
      Paint()
        ..color = colors.primary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
  }

  @override
  bool shouldRepaint(SequenceMapPainter oldDelegate) {
    return oldDelegate.entries != entries ||
        oldDelegate.progress != progress ||
        oldDelegate.selectedId != selectedId ||
        oldDelegate.colors != colors;
  }
}
