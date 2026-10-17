part of '../sequence_tree.dart';

// The Ledger gutter map (spec §7).
//
// Comfortable and Compact put the overview in the 80 px strip under the tree.
// Ledger's whole promise is that the night fits on one screen, so its overview
// lives where the eye already is — a narrow column down the right edge of the
// tree's own viewport, drawn by the same painter the strip uses. Both shapes
// answer to the same canvas-bar control, which is on by default here and off
// by default there.

/// Identifies the gutter for tests.
const Key sequenceGutterMapKey = Key('sequence-tree-gutter-map');

/// The gutter's width: wide enough that a block reads as a block and the
/// viewport rectangle is grabbable, narrow enough to cost the tree nothing.
const double _gutterMapWidth = 34.0;

/// The width the gutter is given, animated so the ledger columns take it back
/// (and give it up) instead of jumping by 34 px.
///
/// A width factor rather than an `AnimatedContainer` around the gutter: the
/// painter sizes itself from its constraints, so shrinking the box would
/// re-lay-out and repaint every block on every frame of the close. Clipping a
/// full-width gutter costs one layer and paints the same picture throughout.
///
/// At rest closed the gutter is not built at all — the painter repaints from
/// the tree's scroll controller, and an invisible map has no business
/// repainting while the operator scrolls.
class _GutterMapSlot extends StatelessWidget {
  final bool visible;
  final SkotiqColors colors;
  final ScrollController scrollController;
  final int? Function(double contentOffset) rowAtContentOffset;

  const _GutterMapSlot({
    required this.visible,
    required this.colors,
    required this.scrollController,
    required this.rowAtContentOffset,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      // No `begin`: a tween with only an end starts AT that end, so a tree
      // that mounts with the gutter on draws it open rather than sliding it
      // in over the first rows the operator reads.
      tween: Tween<double>(end: visible ? 1.0 : 0.0),
      duration: animationDuration(context, SkotiqTokens.durationSmooth),
      curve: SkotiqTokens.curveStandard,
      child: _SequenceGutterMap(
        key: sequenceGutterMapKey,
        colors: colors,
        scrollController: scrollController,
        rowAtContentOffset: rowAtContentOffset,
      ),
      builder: (context, openness, child) {
        if (openness <= 0) return const SizedBox.shrink();
        return ClipRect(
          child: Align(
            // Anchored to its own left edge, so the blocks slide out under
            // the rows rather than the map redrawing itself narrower.
            alignment: Alignment.centerLeft,
            widthFactor: openness,
            child: child,
          ),
        );
      },
    );
  }
}

class _SequenceGutterMap extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final ScrollController scrollController;

  /// Which visible row covers a given number of content pixels down the tree,
  /// answered by the tree itself from its live row boxes.
  ///
  /// The gutter cannot work this out on its own: its blocks are evenly spaced
  /// and the tree's content is not, so `dy / height × rowCount` names a
  /// different row than the one the viewport rectangle at the same `dy` is
  /// drawn over. Null while no row box is mounted.
  final int? Function(double contentOffset) rowAtContentOffset;

  const _SequenceGutterMap({
    super.key,
    required this.colors,
    required this.scrollController,
    required this.rowAtContentOffset,
  });

  @override
  ConsumerState<_SequenceGutterMap> createState() => _SequenceGutterMapState();
}

class _SequenceGutterMapState extends ConsumerState<_SequenceGutterMap> {
  /// Where the finger went down, and where the tree was scrolled to then.
  ///
  /// The drag is a DELTA from that pair rather than an absolute y → offset
  /// mapping, so grabbing the viewport rectangle anywhere inside it keeps the
  /// tree exactly where it is instead of snapping the grab point to the
  /// rectangle's centre.
  double? _dragAnchorY;
  double _dragAnchorOffset = 0;

  @override
  Widget build(BuildContext context) {
    final sequence = ref.watch(currentSequenceProvider);
    final entries = sequence == null
        ? const <SequenceMapEntry>[]
        : sequenceMapEntries(sequence, ref.watch(visibleNodeOrderProvider));
    final progress = ref.watch(sequenceProgressProvider);
    final selectedId = ref.watch(selectedNodeIdProvider);

    return SizedBox(
      width: _gutterMapWidth,
      // Explicit rather than inherited from the Row's `stretch`: the density
      // cross-fade puts the gutter inside a loosely-fitted Stack while it
      // fades, and a gutter that shrink-wrapped its painter there would
      // collapse to nothing for the length of the fade.
      height: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: widget.colors.surface,
          border: Border(left: BorderSide(color: widget.colors.border)),
        ),
        child: entries.isEmpty
            ? const SizedBox.expand()
            : LayoutBuilder(
                builder: (context, constraints) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // On UP, not on DOWN: a press that turns into a drag of the
                  // viewport rectangle would otherwise jump the tree to
                  // wherever the finger landed before the drag it was actually
                  // starting had moved a pixel.
                  onTapUp: (details) {
                    if (_dragAnchorY != null) return;
                    navigateToSequenceMapRow(
                      context,
                      ref,
                      entries,
                      _rowAtGutterY(
                        details.localPosition.dy,
                        constraints.maxHeight,
                        entries.length,
                      ),
                      widget.scrollController,
                    );
                  },
                  onVerticalDragStart: (details) {
                    final metrics = sequenceMapMetrics(widget.scrollController);
                    if (metrics == null) return;
                    _dragAnchorY = details.localPosition.dy;
                    _dragAnchorOffset = metrics.offset;
                  },
                  onVerticalDragUpdate: (details) => _dragTo(
                    details.localPosition.dy,
                    constraints.maxHeight,
                  ),
                  onVerticalDragEnd: (_) => _dragAnchorY = null,
                  onVerticalDragCancel: () => _dragAnchorY = null,
                  child: AnimatedBuilder(
                    animation: widget.scrollController,
                    // The picture does not depend on this animation:
                    // [SequenceMapPainter] already repaints from the same
                    // controller. Handing it through as `child` — behind its
                    // own boundary, so a scroll repaints the gutter without
                    // touching the tree's layer — leaves the rebuild the
                    // Semantics value needs and nothing else.
                    child: RepaintBoundary(
                      child: CustomPaint(
                        size: Size(
                          constraints.maxWidth,
                          constraints.maxHeight,
                        ),
                        painter: SequenceMapPainter(
                          colors: widget.colors,
                          entries: entries,
                          progress: progress,
                          selectedId: selectedId,
                          scrollController: widget.scrollController,
                        ),
                      ),
                    ),
                    builder: (context, child) => Semantics(
                      slider: true,
                      label: 'Sequence overview',
                      value: _positionLabel(entries.length),
                      // Both required alongside the actions: a reader
                      // announces where the increase/decrease will land, and
                      // the framework asserts on a valued slider that names
                      // neither.
                      increasedValue: _positionLabel(entries.length, pages: 1),
                      decreasedValue: _positionLabel(entries.length, pages: -1),
                      // A slider a reader cannot move is a label wearing a
                      // control's clothes: the two actions page the tree by a
                      // screen, which is what dragging the rectangle by its
                      // own height does.
                      onIncrease: () => _pageBy(1),
                      onDecrease: () => _pageBy(-1),
                      // The blocks are a picture of the tree, not a second
                      // copy of it: every row they stand for is already
                      // reachable in the tree's own traversal order.
                      excludeSemantics: true,
                      child: child,
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  /// Scroll the tree by the distance the finger has travelled down the gutter,
  /// scaled from gutter pixels to content pixels.
  void _dragTo(double localY, double extent) {
    final anchorY = _dragAnchorY;
    if (anchorY == null || extent <= 0) return;
    final metrics = sequenceMapMetrics(widget.scrollController);
    if (metrics == null) return;
    final contentExtent = metrics.maxScrollExtent + metrics.viewportDimension;
    final offset =
        _dragAnchorOffset + ((localY - anchorY) / extent) * contentExtent;
    widget.scrollController.jumpTo(
      offset.clamp(0.0, metrics.maxScrollExtent),
    );
  }

  /// Scroll one full viewport in [direction], the way the slider's increase
  /// and decrease actions move it.
  void _pageBy(int direction) {
    final metrics = sequenceMapMetrics(widget.scrollController);
    if (metrics == null) return;
    widget.scrollController.animateTo(
      (metrics.offset + direction * metrics.viewportDimension)
          .clamp(0.0, metrics.maxScrollExtent),
      duration: animationDuration(context, SkotiqTokens.durationSlow),
      curve: SkotiqTokens.curveStandard,
    );
  }

  /// The row a point [localY] down a gutter of [extent] pixels stands for.
  ///
  /// Through content pixels, not through the block grid: the viewport
  /// rectangle is drawn at `offset / contentExtent` of the gutter's height, so
  /// mapping a tap back the same way is the only thing that makes clicking the
  /// top of that rectangle select the row at the top of the viewport. Falls
  /// back to the block grid while the tree's row boxes are not mounted.
  int _rowAtGutterY(double localY, double extent, int rowCount) {
    final metrics = sequenceMapMetrics(widget.scrollController);
    if (metrics == null || extent <= 0) {
      return sequenceMapRowAt(localY, extent, rowCount);
    }
    final contentExtent = metrics.maxScrollExtent + metrics.viewportDimension;
    final row = widget.rowAtContentOffset((localY / extent) * contentExtent);
    return row ?? sequenceMapRowAt(localY, extent, rowCount);
  }

  /// What the slider reads: the row at the top of the viewport, or at the top
  /// of the viewport [pages] screens from here — the value an increase or a
  /// decrease will move it to.
  ///
  /// When the tree's row boxes are not mounted the answer falls back to the
  /// evenly-spaced block grid, exactly as [_rowAtGutterY] does. It used to
  /// fall back to "row 1", which is not an approximation — it is a number,
  /// announced with as much confidence as a measured one, and it said the
  /// operator was at the top of the night from wherever they actually were.
  String _positionLabel(int rowCount, {int pages = 0}) {
    final metrics = sequenceMapMetrics(widget.scrollController);
    if (metrics == null) return 'row 1 of $rowCount';
    final offset = (metrics.offset + pages * metrics.viewportDimension)
        .clamp(0.0, metrics.maxScrollExtent);
    final contentExtent = metrics.maxScrollExtent + metrics.viewportDimension;
    final row = widget.rowAtContentOffset(offset) ??
        sequenceMapRowAt(offset, contentExtent, rowCount);
    return 'row ${row + 1} of $rowCount';
  }
}
