import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../utils/preview_transform.dart';
import 'depthlock_geometry.dart';
import 'depthlock_presentation.dart';

/// Which rectangle the region tool is waiting for.
enum DepthLockRegionStep {
  /// The faint structure the operator cares about.
  structure,

  /// A nearby blank patch the structure is measured against.
  background,

  /// Both are drawn; they can be adjusted, and the editor can be opened.
  ready,
}

/// Which of the two rectangles an interaction is addressing.
enum DepthLockRectKind { structure, background }

/// The two rectangles of an in-progress selection, in IMAGE pixels.
///
/// Held in image pixels for as long as the operator is still adjusting them:
/// pixels are what the pointer produces and what the painter consumes, and
/// they stay put under pan and zoom. The conversion to a [SkyRectangle]
/// happens once, at commit, through the native `depthLockSkyRectangle` — so
/// there is exactly one place where the projection convention can be wrong.
@immutable
class DepthLockRegionDraft {
  const DepthLockRegionDraft({this.structure, this.background});

  final Rect? structure;
  final Rect? background;

  bool get isEmpty => structure == null && background == null;

  DepthLockRegionStep get step {
    if (structure == null) return DepthLockRegionStep.structure;
    if (background == null) return DepthLockRegionStep.background;
    return DepthLockRegionStep.ready;
  }

  Rect? operator [](DepthLockRectKind kind) =>
      kind == DepthLockRectKind.structure ? structure : background;

  DepthLockRegionDraft withRect(DepthLockRectKind kind, Rect rect) =>
      kind == DepthLockRectKind.structure
          ? DepthLockRegionDraft(structure: rect, background: background)
          : DepthLockRegionDraft(structure: structure, background: rect);

  @override
  bool operator ==(Object other) =>
      other is DepthLockRegionDraft &&
      other.structure == structure &&
      other.background == background;

  @override
  int get hashCode => Object.hash(structure, background);
}

/// Holds the draft rectangles while the tool is in use.
class DepthLockRegionDraftNotifier extends StateNotifier<DepthLockRegionDraft> {
  DepthLockRegionDraftNotifier() : super(const DepthLockRegionDraft());

  /// Record the rectangle the operator just finished dragging. The first drag
  /// is the structure, the second the background; a third replaces the
  /// background, so a badly-placed second rectangle is redrawn rather than
  /// requiring a reset.
  void commit(Rect rect) {
    state = state.structure == null
        ? DepthLockRegionDraft(structure: rect)
        : DepthLockRegionDraft(structure: state.structure, background: rect);
  }

  /// Replace one rectangle in place — what a move or a resize does.
  void replace(DepthLockRectKind kind, Rect rect) =>
      state = state.withRect(kind, rect);

  /// Load an existing goal's rectangles for adjustment.
  void load({required Rect structure, required Rect background}) =>
      state = DepthLockRegionDraft(
        structure: structure,
        background: background,
      );

  /// Drop the most recent rectangle.
  void undo() {
    state = state.background != null
        ? DepthLockRegionDraft(structure: state.structure)
        : const DepthLockRegionDraft();
  }

  void clear() => state = const DepthLockRegionDraft();
}

/// Whether the DepthLock region tool owns canvas gestures right now.
final depthLockRegionToolActiveProvider = StateProvider<bool>((ref) => false);

/// The rectangles drawn so far.
final depthLockRegionDraftProvider =
    StateNotifierProvider<DepthLockRegionDraftNotifier, DepthLockRegionDraft>(
  (ref) => DepthLockRegionDraftNotifier(),
);

/// Whether saved goals are drawn over the frame. Defaults on: a goal the
/// operator cannot see is a goal they will draw twice.
final depthLockGoalOverlayVisibleProvider = StateProvider<bool>((ref) => true);

/// The goal whose region is being re-drawn, or null when the tool is defining
/// a new one. Set by "Edit region"; cleared when the tool is left.
final depthLockRegionEditTargetProvider = StateProvider<String?>((ref) => null);

/// Bumped each time the operator says the rectangles are finished.
///
/// A counter rather than a flag because the panel acts on the transition, and
/// a second commit after a cancelled editor has to be distinguishable from the
/// first. The panel listens; the layer never needs to know what happens next.
final depthLockRegionCommitProvider = StateProvider<int>((ref) => 0);

/// Leave the region tool and throw away anything half-drawn.
void cancelDepthLockRegionTool(WidgetRef ref) {
  ref.read(depthLockRegionDraftProvider.notifier).clear();
  ref.read(depthLockRegionEditTargetProvider.notifier).state = null;
  ref.read(depthLockRegionToolActiveProvider.notifier).state = false;
}

/// Say the rectangles are finished. No-op until both exist.
void commitDepthLockRegion(WidgetRef ref) {
  if (ref.read(depthLockRegionDraftProvider).step !=
      DepthLockRegionStep.ready) {
    return;
  }
  ref.read(depthLockRegionCommitProvider.notifier).update((value) => value + 1);
}

/// What the pointer is currently doing to the draft.
enum _DragMode { create, move, resize }

/// The preview overlay that draws DepthLock regions and, while the tool is
/// active, owns the drags that define and adjust them.
///
/// Mirrors `CustomAnnotationDrawingLayer`: it takes the same
/// `zoomLevel` / `imageOffset` / `imageSize` the other overlays are handed,
/// converts pointer positions through `preview_transform`, and passes pointer
/// events straight through whenever no tool is active.
class DepthLockRegionLayer extends ConsumerStatefulWidget {
  const DepthLockRegionLayer({
    super.key,
    required this.zoomLevel,
    required this.imageOffset,
    required this.imageSize,
    required this.geometry,
  });

  /// Screen pixels per image pixel — the preview's display scale, not the
  /// viewer's fit-relative zoom multiplier.
  final double zoomLevel;
  final Offset imageOffset;
  final Size imageSize;

  /// The displayed frame's solved astrometry, or null when it has none. Saved
  /// goals can only be drawn on a frame that has one, since their rectangles
  /// are stored on the sky rather than in this frame's pixels.
  final ReferenceGeometry? geometry;

  /// The smallest rectangle, in image pixels, that counts as a deliberate
  /// drag rather than a stray click.
  static const double minimumSideImagePixels = 8;

  /// How close, in SCREEN pixels, the pointer must come to a handle to grab
  /// it. Converted to image pixels through the display scale, so a handle is
  /// equally easy to hit zoomed in and zoomed out.
  static const double handleTouchScreenPixels = 12;

  /// The drawn size of a handle, in screen pixels.
  static const double handleScreenSize = 8;

  @override
  ConsumerState<DepthLockRegionLayer> createState() =>
      _DepthLockRegionLayerState();
}

class _DepthLockRegionLayerState extends ConsumerState<DepthLockRegionLayer> {
  _DragMode _mode = _DragMode.create;
  DepthLockRectKind? _target;
  DepthLockHandle? _handle;

  /// Where the pointer went down, and what the rectangle looked like then —
  /// a move is applied from the ORIGINAL rectangle each update rather than
  /// accumulated, so a slow drag cannot drift.
  Offset? _dragStart;
  Offset? _dragCurrent;
  Rect? _originRect;

  Offset _toImage(Offset viewportPoint) => viewportToImage(
        viewportPoint: viewportPoint,
        imageOffset: widget.imageOffset,
        zoomLevel: widget.zoomLevel,
      );

  double get _handleTolerance =>
      DepthLockRegionLayer.handleTouchScreenPixels /
      (widget.zoomLevel <= 0 ? 1 : widget.zoomLevel);

  void _onPanStart(DragStartDetails details) {
    final start = _toImage(details.localPosition);
    final draft = ref.read(depthLockRegionDraftProvider);

    // Handles first, then interiors, then a fresh rectangle. The background
    // is tested before the structure because it is drawn second and is the
    // one on top where they are close together.
    for (final kind in const <DepthLockRectKind>[
      DepthLockRectKind.background,
      DepthLockRectKind.structure,
    ]) {
      final rect = draft[kind];
      if (rect == null) continue;
      final handle = depthLockHandleAt(
        rect,
        start,
        tolerance: _handleTolerance,
      );
      if (handle != null) {
        setState(() {
          _mode = _DragMode.resize;
          _target = kind;
          _handle = handle;
          _originRect = rect;
          _dragStart = start;
          _dragCurrent = start;
        });
        return;
      }
    }
    for (final kind in const <DepthLockRectKind>[
      DepthLockRectKind.background,
      DepthLockRectKind.structure,
    ]) {
      final rect = draft[kind];
      if (rect != null && rect.contains(start)) {
        setState(() {
          _mode = _DragMode.move;
          _target = kind;
          _handle = null;
          _originRect = rect;
          _dragStart = start;
          _dragCurrent = start;
        });
        return;
      }
    }

    setState(() {
      _mode = _DragMode.create;
      _target = null;
      _handle = null;
      _originRect = null;
      _dragStart = start;
      _dragCurrent = start;
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_dragStart == null) return;
    final current = _toImage(details.localPosition);
    setState(() => _dragCurrent = current);

    final kind = _target;
    final origin = _originRect;
    if (kind == null || origin == null) return;

    final notifier = ref.read(depthLockRegionDraftProvider.notifier);
    switch (_mode) {
      case _DragMode.move:
        notifier.replace(kind, depthLockMove(origin, current - _dragStart!));
      case _DragMode.resize:
        notifier.replace(kind, depthLockResize(origin, _handle!, current));
      case _DragMode.create:
        break;
    }
  }

  void _onPanEnd(DragEndDetails details) {
    final mode = _mode;
    final start = _dragStart;
    final end = _dragCurrent;
    final kind = _target;
    final origin = _originRect;
    setState(() {
      _dragStart = null;
      _dragCurrent = null;
      _originRect = null;
      _target = null;
      _handle = null;
      _mode = _DragMode.create;
    });

    if (mode != _DragMode.create) {
      // An adjustment that collapsed the rectangle is not an adjustment; put
      // the rectangle back rather than leave one the validator will refuse.
      final rect = ref.read(depthLockRegionDraftProvider)[kind!];
      if (rect == null || !_isBigEnough(rect)) {
        ref.read(depthLockRegionDraftProvider.notifier).replace(kind, origin!);
      }
      return;
    }

    if (start == null || end == null) return;
    final rect = depthLockNormalizedRect(start, end);
    // A click that never became a drag is not an empty region — it is a
    // misfire, and committing it would leave a zero-width rectangle the
    // native validator refuses with a message about grid cells.
    if (!_isBigEnough(rect)) return;
    ref.read(depthLockRegionDraftProvider.notifier).commit(rect);
  }

  bool _isBigEnough(Rect rect) =>
      rect.width >= DepthLockRegionLayer.minimumSideImagePixels &&
      rect.height >= DepthLockRegionLayer.minimumSideImagePixels;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final bool toolActive = ref.watch(depthLockRegionToolActiveProvider);
    final draft = ref.watch(depthLockRegionDraftProvider);
    final bool overlayVisible = ref.watch(depthLockGoalOverlayVisibleProvider);
    final goals = overlayVisible
        ? ref.watch(depthLockGoalsProvider).valueOrNull ??
            const <DepthLockGoal>[]
        : const <DepthLockGoal>[];

    final Rect? active =
        _mode == _DragMode.create && _dragStart != null && _dragCurrent != null
            ? depthLockNormalizedRect(_dragStart!, _dragCurrent!)
            : null;

    final painter = DepthLockRegionPainter(
      draft: draft,
      activeRect: active,
      activeIsBackground: draft.structure != null,
      showHandles: toolActive,
      handleSize: DepthLockRegionLayer.handleScreenSize,
      goals: goals,
      geometry: widget.geometry,
      imageSize: widget.imageSize,
      zoomLevel: widget.zoomLevel,
      imageOffset: widget.imageOffset,
      colors: colors,
    );

    if (!toolActive) {
      return IgnorePointer(
        child: CustomPaint(painter: painter, size: Size.infinite),
      );
    }

    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: MouseRegion(
            cursor: SystemMouseCursors.precise,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: _onPanStart,
              onPanUpdate: _onPanUpdate,
              onPanEnd: _onPanEnd,
              child: CustomPaint(painter: painter, size: Size.infinite),
            ),
          ),
        ),
        Positioned(
          top: SkotiqTokens.spaceLg,
          left: 0,
          right: 0,
          // topCenter, not the default centre: a Positioned with left/right/top
          // and no height hands its child a BOUNDED height, so a plain Align
          // centres the strip vertically in the whole canvas instead of
          // leaving it at the top.
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SkotiqTokens.spaceLg,
            ),
            child: Align(
              alignment: Alignment.topCenter,
              child: _RegionToolInstructions(step: draft.step),
            ),
          ),
        ),
      ],
    );
  }
}

/// The glass strip that says which rectangle is being asked for, how to
/// finish, and how to get out.
///
/// It carries the whole instruction rather than a label: a drag tool with no
/// prompt is a canvas that silently swallows a pan, and neither the second
/// rectangle nor the fact that both can be adjusted is something an operator
/// guesses.
class _RegionToolInstructions extends ConsumerWidget {
  const _RegionToolInstructions({required this.step});

  final DepthLockRegionStep step;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String message = switch (step) {
      DepthLockRegionStep.structure =>
        'Drag a box over the faint structure you want to reach.',
      DepthLockRegionStep.background =>
        'Now drag a second box over nearby blank sky. It must not overlap '
            'the first.',
      DepthLockRegionStep.ready =>
        'Drag a corner or an edge to resize, drag inside to move. Enter when '
            'they are right.',
    };
    final bool ready = step == DepthLockRegionStep.ready;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            cancelDepthLockRegionTool(ref),
        const SingleActivator(LogicalKeyboardKey.enter): () =>
            commitDepthLockRegion(ref),
        const SingleActivator(LogicalKeyboardKey.numpadEnter): () =>
            commitDepthLockRegion(ref),
      },
      child: Focus(
        autofocus: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // The caption is its OWN glass pill, and the whole pill ignores
            // pointers. Anything hit-testable over the frame is a hole the
            // operator cannot drag through, and this strip sits exactly where
            // a region's top edge usually is: a handle underneath it could not
            // be grabbed at all. Only the buttons beside it capture pointers,
            // which is the smallest area that still works.
            // Flexible so the caption gives way on a narrow canvas rather
            // than pushing the buttons off the edge.
            Flexible(
              child: IgnorePointer(
                child: Glass(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SkotiqTokens.spaceMd,
                    vertical: SkotiqTokens.spaceSm,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: Builder(
                      // Built through a Builder so the ink resolves under the
                      // palette [Glass] installs for its contents — over a
                      // photograph that is the dark ladder, whatever the app
                      // theme is.
                      builder: (BuildContext inner) => Text(
                        message,
                        style: SkotiqTypography.bodySm.copyWith(
                          color: inner.skotiqColors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Glass(
              padding: const EdgeInsets.symmetric(
                horizontal: SkotiqTokens.spaceSm,
                vertical: SkotiqTokens.spaceXs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (ready) ...<Widget>[
                    SkotiqButton(
                      label: 'Use these',
                      icon: SkotiqIcons.check,
                      size: ButtonSize.small,
                      semanticsHint:
                          'Finish the two boxes and open the goal editor',
                      onPressed: () => commitDepthLockRegion(ref),
                    ),
                    const SizedBox(width: SkotiqTokens.spaceXs),
                  ],
                  SkotiqButton(
                    label: 'Cancel',
                    icon: SkotiqIcons.close,
                    size: ButtonSize.small,
                    variant: ButtonVariant.ghost,
                    semanticsHint:
                        'Leave the DepthLock region tool and discard the boxes',
                    onPressed: () => cancelDepthLockRegionTool(ref),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Draws the draft rectangles, their grips, and every saved goal that lands on
/// this frame.
class DepthLockRegionPainter extends CustomPainter {
  DepthLockRegionPainter({
    required this.draft,
    required this.activeRect,
    required this.activeIsBackground,
    required this.showHandles,
    required this.handleSize,
    required this.goals,
    required this.geometry,
    required this.imageSize,
    required this.zoomLevel,
    required this.imageOffset,
    required this.colors,
  });

  final DepthLockRegionDraft draft;

  /// The rectangle under the pointer right now, while one is being drawn.
  final Rect? activeRect;

  /// Whether that rectangle is the background one — it is drawn dashed, the
  /// same way the committed background rectangle is.
  final bool activeIsBackground;

  /// Grips are drawn only while the tool owns the canvas; with the tool shut
  /// the rectangles are a record, not a control.
  final bool showHandles;
  final double handleSize;

  final List<DepthLockGoal> goals;
  final ReferenceGeometry? geometry;
  final Size imageSize;
  final double zoomLevel;
  final Offset imageOffset;
  final SkotiqColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    for (final goal in goals) {
      _paintGoal(canvas, goal);
    }

    final Color draftColor = colors.accent;
    if (draft.structure != null) {
      _paintRect(
        canvas,
        draft.structure!,
        draftColor,
        'Structure',
        dashed: false,
      );
    }
    if (draft.background != null) {
      _paintRect(
        canvas,
        draft.background!,
        draftColor,
        'Background',
        dashed: true,
      );
    }
    if (activeRect != null) {
      _paintRect(
        canvas,
        activeRect!,
        draftColor.withValues(alpha: 0.7),
        activeIsBackground ? 'Background' : 'Structure',
        dashed: activeIsBackground,
        handles: false,
      );
    }
  }

  void _paintGoal(Canvas canvas, DepthLockGoal goal) {
    final solved = geometry;
    if (solved == null) return;
    final region = depthLockRectangleCorners(
      rectangle: goal.definition.measurement.region,
      geometry: solved,
    );
    if (region == null) return;
    // A goal anchored on another target projects far outside this frame, so
    // only the ones that land on it are drawn. The margin is a tenth of the
    // frame: a goal the mount dithered just off the edge is still this
    // target's, and drawing its label at the border says so.
    final double marginX = imageSize.width * 0.1;
    final double marginY = imageSize.height * 0.1;
    final bool onFrame = region.any(
      (corner) =>
          corner.dx >= -marginX &&
          corner.dx <= imageSize.width + marginX &&
          corner.dy >= -marginY &&
          corner.dy <= imageSize.height + marginY,
    );
    if (!onFrame) return;

    final Color color = depthLockStateColor(goal.state, colors);
    _paintPolygon(canvas, region, color, dashed: false);
    final background = depthLockRectangleCorners(
      rectangle: goal.definition.measurement.background,
      geometry: solved,
    );
    if (background != null) {
      _paintPolygon(canvas, background, color, dashed: true);
    }
    final Offset anchor = _toScreen(region.first);
    _paintLabel(
      canvas,
      '${goal.definition.label} · ${goal.definition.filterName} · '
      '${depthLockStateLabel(goal.state)}',
      Offset(anchor.dx, anchor.dy - 16),
      color,
    );
  }

  Offset _toScreen(Offset imagePoint) => imageToViewport(
        imagePoint: imagePoint,
        imageOffset: imageOffset,
        zoomLevel: zoomLevel,
      );

  void _paintRect(
    Canvas canvas,
    Rect imageRect,
    Color color,
    String label, {
    required bool dashed,
    bool handles = true,
  }) {
    final corners = <Offset>[
      imageRect.topLeft,
      imageRect.topRight,
      imageRect.bottomRight,
      imageRect.bottomLeft,
    ];
    _paintPolygon(canvas, corners, color, dashed: dashed);
    if (showHandles && handles) {
      _paintHandles(canvas, imageRect, color);
    }
    final Offset anchor = _toScreen(imageRect.topLeft);
    _paintLabel(canvas, label, Offset(anchor.dx, anchor.dy - 16), color);
  }

  void _paintHandles(Canvas canvas, Rect imageRect, Color color) {
    final fill = Paint()..color = color;
    final edge = Paint()
      ..color = SkotiqColors.dark.background
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final handle in DepthLockHandle.values) {
      final Offset at = _toScreen(
        depthLockHandlePosition(imageRect, handle),
      );
      final Rect grip = Rect.fromCenter(
        center: at,
        width: handleSize,
        height: handleSize,
      );
      canvas.drawRect(grip, fill);
      canvas.drawRect(grip, edge);
    }
  }

  void _paintPolygon(
    Canvas canvas,
    List<Offset> imageCorners,
    Color color, {
    required bool dashed,
  }) {
    if (imageCorners.length < 2) return;
    final screen = imageCorners.map(_toScreen).toList(growable: false);
    final paint = Paint()
      ..color = color.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    for (var i = 0; i < screen.length; i++) {
      final Offset a = screen[i];
      final Offset b = screen[(i + 1) % screen.length];
      if (dashed) {
        _dashedLine(canvas, a, b, paint);
      } else {
        canvas.drawLine(a, b, paint);
      }
    }
  }

  void _dashedLine(Canvas canvas, Offset start, Offset end, Paint paint) {
    final double dx = end.dx - start.dx;
    final double dy = end.dy - start.dy;
    final double length = math.sqrt(dx * dx + dy * dy);
    if (length < 1) return;
    const double dash = 6;
    const double gap = 4;
    final double ux = dx / length;
    final double uy = dy / length;
    double travelled = 0;
    while (travelled < length) {
      final double segment = math.min(dash, length - travelled);
      canvas.drawLine(
        Offset(start.dx + ux * travelled, start.dy + uy * travelled),
        Offset(
          start.dx + ux * (travelled + segment),
          start.dy + uy * (travelled + segment),
        ),
        paint,
      );
      travelled += dash + gap;
    }
  }

  void _paintLabel(Canvas canvas, String text, Offset at, Color color) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: SkotiqTypography.caption.copyWith(color: color),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final Rect plate = Rect.fromLTWH(
      at.dx - 3,
      at.dy - 2,
      painter.width + 6,
      painter.height + 4,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          plate, const Radius.circular(SkotiqTokens.radiusXs)),
      Paint()..color = SkotiqColors.dark.background.withValues(alpha: 0.7),
    );
    painter.paint(canvas, at);
  }

  @override
  bool shouldRepaint(DepthLockRegionPainter oldDelegate) =>
      oldDelegate.draft != draft ||
      oldDelegate.activeRect != activeRect ||
      oldDelegate.activeIsBackground != activeIsBackground ||
      oldDelegate.showHandles != showHandles ||
      oldDelegate.goals != goals ||
      oldDelegate.geometry != geometry ||
      oldDelegate.zoomLevel != zoomLevel ||
      oldDelegate.imageOffset != imageOffset ||
      oldDelegate.colors != colors;
}
