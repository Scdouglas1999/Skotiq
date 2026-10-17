import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../utils/preview_transform.dart';

// Delete mode provider — separate from the annotation type tool since
// "delete" is not a CustomAnnotationType value.

/// Whether the delete-annotation tool is active.
final _deleteToolActiveProvider = StateProvider<bool>((ref) => false);

/// Whether the docked drawing palette is open.
///
/// This is the user-facing "enter annotate mode" switch: the off-canvas
/// preview toolbar flips it, and the docked [CustomAnnotationToolbar] only
/// renders while it (or an active tool) is set. Closing it clears any active
/// tool so the canvas returns to plain pan/zoom.
final annotationDrawPaletteOpenProvider = StateProvider<bool>((ref) => false);

/// True whenever the docked drawing palette should be shown — the palette is
/// explicitly open, or a tool/delete mode is currently active (so the palette
/// never vanishes out from under an in-progress draw).
///
/// Exposed publicly so the live-preview layout can gate the docked drawing
/// toolbar's visibility on it, instead of permanently floating it over the
/// image.
final customAnnotationDrawModeActiveProvider = Provider<bool>((ref) {
  final paletteOpen = ref.watch(annotationDrawPaletteOpenProvider);
  final tool = ref.watch(customAnnotationToolProvider);
  final deleteActive = ref.watch(_deleteToolActiveProvider);
  return paletteOpen || tool != null || deleteActive;
});

/// Toggle the docked drawing palette. When closing, any active draw/delete
/// tool is cleared so a stale tool can't keep capturing canvas gestures after
/// the palette is dismissed.
void toggleAnnotationDrawPalette(WidgetRef ref) {
  final open = ref.read(annotationDrawPaletteOpenProvider);
  if (open) {
    ref.read(customAnnotationToolProvider.notifier).state = null;
    ref.read(_deleteToolActiveProvider.notifier).state = false;
  }
  ref.read(annotationDrawPaletteOpenProvider.notifier).state = !open;
}

// Custom annotation painter

/// Renders all user-drawn custom annotations on the image overlay.
///
/// Uses green dashed lines for circles and arrows so that custom annotations
/// are clearly distinct from the blue/yellow catalog annotations.
class CustomAnnotationPainter extends CustomPainter {
  final List<CustomAnnotation> annotations;
  final double zoomLevel;
  final Offset imageOffset;

  /// Optional in-progress annotation being drawn right now.
  final CustomAnnotation? activeAnnotation;

  CustomAnnotationPainter({
    required this.annotations,
    required this.zoomLevel,
    required this.imageOffset,
    this.activeAnnotation,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final annotation in annotations) {
      _drawAnnotation(canvas, annotation, isPreview: false);
    }
    if (activeAnnotation != null) {
      _drawAnnotation(canvas, activeAnnotation!, isPreview: true);
    }
  }

  void _drawAnnotation(
    Canvas canvas,
    CustomAnnotation annotation, {
    required bool isPreview,
  }) {
    final color = Color(annotation.color);
    final alpha = isPreview ? 0.6 : 0.85;

    switch (annotation.type) {
      case CustomAnnotationType.circle:
        _drawCircle(canvas, annotation, color, alpha);
      case CustomAnnotationType.arrow:
        _drawArrow(canvas, annotation, color, alpha);
      case CustomAnnotationType.text:
        _drawTextNote(canvas, annotation, color, alpha);
    }
  }

  Offset _toScreen(double imageX, double imageY) {
    return imageToViewport(
      imagePoint: Offset(imageX, imageY),
      imageOffset: imageOffset,
      zoomLevel: zoomLevel,
    );
  }

  void _drawCircle(
    Canvas canvas,
    CustomAnnotation annotation,
    Color color,
    double alpha,
  ) {
    final center = _toScreen(annotation.x, annotation.y);
    final screenRadius = (annotation.radius ?? 0) * zoomLevel;

    // Dashed circle
    final paint = Paint()
      ..color = color.withValues(alpha: alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;

    _drawDashedCircle(canvas, center, screenRadius, paint);

    // Small filled center dot
    final dotPaint = Paint()
      ..color = color.withValues(alpha: alpha)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 2.5, dotPaint);

    // Label below the circle
    if (annotation.label.isNotEmpty) {
      _drawLabel(
        canvas,
        annotation.label,
        Offset(center.dx, center.dy + screenRadius + 6),
        color,
        alpha,
      );
    }
  }

  void _drawDashedCircle(
    Canvas canvas,
    Offset center,
    double radius,
    Paint paint,
  ) {
    if (radius < 1) return;
    const dashLength = 6.0;
    const gapLength = 4.0;
    final circumference = 2 * math.pi * radius;
    const totalDashGap = dashLength + gapLength;
    final dashCount = (circumference / totalDashGap).floor();
    if (dashCount <= 0) {
      // Too small for dashes; draw solid
      canvas.drawCircle(center, radius, paint);
      return;
    }

    final anglePerDash = (2 * math.pi) / dashCount;
    final dashAngle = anglePerDash * (dashLength / totalDashGap);

    for (var i = 0; i < dashCount; i++) {
      final startAngle = i * anglePerDash;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        dashAngle,
        false,
        paint,
      );
    }
  }

  void _drawArrow(
    Canvas canvas,
    CustomAnnotation annotation,
    Color color,
    double alpha,
  ) {
    final start = _toScreen(annotation.x, annotation.y);
    final end =
        _toScreen(annotation.x2 ?? annotation.x, annotation.y2 ?? annotation.y);

    final paint = Paint()
      ..color = color.withValues(alpha: alpha)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // Dashed line from start to end
    _drawDashedLine(canvas, start, end, paint);

    // Arrowhead at end
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final angle = math.atan2(dy, dx);
    const headLength = 12.0;
    const headAngle = 0.45; // radians

    final headPaint = Paint()
      ..color = color.withValues(alpha: alpha)
      ..style = PaintingStyle.fill;

    final path = Path()
      ..moveTo(end.dx, end.dy)
      ..lineTo(
        end.dx - headLength * math.cos(angle - headAngle),
        end.dy - headLength * math.sin(angle - headAngle),
      )
      ..lineTo(
        end.dx - headLength * math.cos(angle + headAngle),
        end.dy - headLength * math.sin(angle + headAngle),
      )
      ..close();
    canvas.drawPath(path, headPaint);

    // Label at the midpoint above the line
    if (annotation.label.isNotEmpty) {
      final mid = Offset((start.dx + end.dx) / 2, (start.dy + end.dy) / 2);
      _drawLabel(
          canvas, annotation.label, Offset(mid.dx, mid.dy - 12), color, alpha);
    }
  }

  void _drawDashedLine(
    Canvas canvas,
    Offset start,
    Offset end,
    Paint paint,
  ) {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final totalLength = math.sqrt(dx * dx + dy * dy);
    if (totalLength < 1) return;

    const dashLength = 8.0;
    const gapLength = 4.0;
    final unitDx = dx / totalLength;
    final unitDy = dy / totalLength;

    var drawn = 0.0;
    while (drawn < totalLength) {
      final dashEnd = math.min(drawn + dashLength, totalLength);
      canvas.drawLine(
        Offset(start.dx + unitDx * drawn, start.dy + unitDy * drawn),
        Offset(start.dx + unitDx * dashEnd, start.dy + unitDy * dashEnd),
        paint,
      );
      drawn = dashEnd + gapLength;
    }
  }

  void _drawTextNote(
    Canvas canvas,
    CustomAnnotation annotation,
    Color color,
    double alpha,
  ) {
    final pos = _toScreen(annotation.x, annotation.y);

    if (annotation.label.isEmpty) return;

    // Small pin/marker at the position
    final markerPaint = Paint()
      ..color = color.withValues(alpha: alpha)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(pos, 4.0, markerPaint);

    final borderPaint = Paint()
      // absolute: marker outline over the image canvas
      ..color = Colors.black.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawCircle(pos, 4.0, borderPaint);

    // Text label to the right of the marker
    _drawLabel(
      canvas,
      annotation.label,
      Offset(pos.dx + 8, pos.dy - 6),
      color,
      alpha,
      anchor: TextAlign.left,
    );
  }

  void _drawLabel(
    Canvas canvas,
    String text,
    Offset position,
    Color color,
    double alpha, {
    TextAlign anchor = TextAlign.center,
  }) {
    final textSpan = TextSpan(
      text: text,
      style: SkotiqTypography.caption.copyWith(
          fontWeight: FontWeight.w600,
          color: color.withValues(
              alpha: math.min(
                  1.0,
                  alpha +
                      0.15)), // absolute: label shadows for legibility over the image canvas
          shadows: const [
            Shadow(blurRadius: 4, color: Colors.black, offset: Offset(1, 1)),
            Shadow(blurRadius: 8, color: Colors.black, offset: Offset(0, 0)),
          ]),
    );

    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
      textAlign: anchor,
    )..layout();

    final dx = anchor == TextAlign.center
        ? position.dx - textPainter.width / 2
        : position.dx;

    // Background pill
    const pad = 3.0;
    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        dx - pad,
        position.dy - pad,
        textPainter.width + pad * 2,
        textPainter.height + pad * 2,
      ),
      const Radius.circular(SkotiqTokens.radiusXs),
    );
    canvas.drawRRect(
      bgRect,
      // absolute: label pill background over the image canvas
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );

    textPainter.paint(canvas, Offset(dx, position.dy));
  }

  @override
  bool shouldRepaint(covariant CustomAnnotationPainter oldDelegate) {
    return oldDelegate.annotations != annotations ||
        oldDelegate.zoomLevel != zoomLevel ||
        oldDelegate.imageOffset != imageOffset ||
        oldDelegate.activeAnnotation != activeAnnotation;
  }
}

// Drawing gesture layer

/// Transparent overlay that captures drawing gestures when a tool is active.
///
/// Sits on top of the image in the stack. When no drawing tool is selected
/// it passes all events through ([IgnorePointer]).
class CustomAnnotationDrawingLayer extends ConsumerStatefulWidget {
  final double zoomLevel;
  final Offset imageOffset;
  final Size imageSize;

  const CustomAnnotationDrawingLayer({
    super.key,
    required this.zoomLevel,
    required this.imageOffset,
    required this.imageSize,
  });

  @override
  ConsumerState<CustomAnnotationDrawingLayer> createState() =>
      _CustomAnnotationDrawingLayerState();
}

class _CustomAnnotationDrawingLayerState
    extends ConsumerState<CustomAnnotationDrawingLayer> {
  /// Annotation being drawn right now (live preview while dragging).
  CustomAnnotation? _activeAnnotation;

  /// Converts a viewport (screen) point to image pixel coordinates.
  Offset _toImage(Offset viewportPoint) {
    return viewportToImage(
      viewportPoint: viewportPoint,
      imageOffset: widget.imageOffset,
      zoomLevel: widget.zoomLevel,
    );
  }

  String _nextId() => 'custom_${DateTime.now().microsecondsSinceEpoch}';

  // Circle drawing

  void _onCirclePanStart(DragStartDetails details) {
    final center = _toImage(details.localPosition);
    setState(() {
      _activeAnnotation = CustomAnnotation(
        id: _nextId(),
        type: CustomAnnotationType.circle,
        x: center.dx,
        y: center.dy,
        radius: 0,
      );
    });
  }

  void _onCirclePanUpdate(DragUpdateDetails details) {
    if (_activeAnnotation == null) return;
    final current = _toImage(details.localPosition);
    final dx = current.dx - _activeAnnotation!.x;
    final dy = current.dy - _activeAnnotation!.y;
    final radius = math.sqrt(dx * dx + dy * dy);
    setState(() {
      _activeAnnotation = _activeAnnotation!.copyWith(radius: radius);
    });
  }

  void _onCirclePanEnd(DragEndDetails details) {
    if (_activeAnnotation == null) return;
    if ((_activeAnnotation!.radius ?? 0) < 3) {
      // Too small, discard
      setState(() => _activeAnnotation = null);
      return;
    }
    final annotation = _activeAnnotation!;
    setState(() => _activeAnnotation = null);
    _showLabelDialog(annotation);
  }

  // Arrow drawing

  void _onArrowPanStart(DragStartDetails details) {
    final start = _toImage(details.localPosition);
    setState(() {
      _activeAnnotation = CustomAnnotation(
        id: _nextId(),
        type: CustomAnnotationType.arrow,
        x: start.dx,
        y: start.dy,
        x2: start.dx,
        y2: start.dy,
      );
    });
  }

  void _onArrowPanUpdate(DragUpdateDetails details) {
    if (_activeAnnotation == null) return;
    final current = _toImage(details.localPosition);
    setState(() {
      _activeAnnotation = _activeAnnotation!.copyWith(
        x2: current.dx,
        y2: current.dy,
      );
    });
  }

  void _onArrowPanEnd(DragEndDetails details) {
    if (_activeAnnotation == null) return;
    final dx =
        (_activeAnnotation!.x2 ?? _activeAnnotation!.x) - _activeAnnotation!.x;
    final dy =
        (_activeAnnotation!.y2 ?? _activeAnnotation!.y) - _activeAnnotation!.y;
    if (math.sqrt(dx * dx + dy * dy) < 5) {
      // Too short, discard
      setState(() => _activeAnnotation = null);
      return;
    }
    final annotation = _activeAnnotation!;
    setState(() => _activeAnnotation = null);
    _showLabelDialog(annotation);
  }

  // Text tool

  void _onTextTapDown(TapDownDetails details) {
    final pos = _toImage(details.localPosition);
    final annotation = CustomAnnotation(
      id: _nextId(),
      type: CustomAnnotationType.text,
      x: pos.dx,
      y: pos.dy,
    );
    _showLabelDialog(annotation, required: true);
  }

  // Delete tool

  void _onDeleteTapDown(TapDownDetails details) {
    final tapImage = _toImage(details.localPosition);
    final annotations = ref.read(customAnnotationsProvider);

    // Find the closest annotation within a reasonable hit radius
    const hitRadiusPixels = 20.0;
    String? closestId;
    double closestDist = double.infinity;

    for (final a in annotations) {
      double dist;
      switch (a.type) {
        case CustomAnnotationType.circle:
          // Distance from tap to circle edge
          final dx = tapImage.dx - a.x;
          final dy = tapImage.dy - a.y;
          final distToCenter = math.sqrt(dx * dx + dy * dy);
          dist = (distToCenter - (a.radius ?? 0)).abs();
          // Also check if tapping inside the circle (distance to center)
          if (distToCenter < (a.radius ?? 0)) dist = 0;
        case CustomAnnotationType.arrow:
          dist = _distanceToLineSegment(
            tapImage,
            Offset(a.x, a.y),
            Offset(a.x2 ?? a.x, a.y2 ?? a.y),
          );
        case CustomAnnotationType.text:
          final dx = tapImage.dx - a.x;
          final dy = tapImage.dy - a.y;
          dist = math.sqrt(dx * dx + dy * dy);
      }
      if (dist < closestDist) {
        closestDist = dist;
        closestId = a.id;
      }
    }

    if (closestId != null && closestDist <= hitRadiusPixels) {
      ref.read(customAnnotationsProvider.notifier).remove(closestId);
    }
  }

  double _distanceToLineSegment(Offset point, Offset a, Offset b) {
    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    final lengthSq = dx * dx + dy * dy;
    if (lengthSq < 1e-6) {
      final px = point.dx - a.dx;
      final py = point.dy - a.dy;
      return math.sqrt(px * px + py * py);
    }
    var t = ((point.dx - a.dx) * dx + (point.dy - a.dy) * dy) / lengthSq;
    t = t.clamp(0.0, 1.0);
    final projX = a.dx + t * dx;
    final projY = a.dy + t * dy;
    final px = point.dx - projX;
    final py = point.dy - projY;
    return math.sqrt(px * px + py * py);
  }

  // Label dialog

  Future<void> _showLabelDialog(
    CustomAnnotation annotation, {
    bool required = false,
  }) async {
    final controller = TextEditingController();
    final title = switch (annotation.type) {
      CustomAnnotationType.circle => 'Circle Label',
      CustomAnnotationType.arrow => 'Arrow Label',
      CustomAnnotationType.text => 'Text Note',
    };
    // Built on SkotiqDialog like every other dialog on this screen, so the
    // primary action is the Skotiq accent rather than Material's saturated
    // greenAccent — the brightest thing on a dark-adapted display at 2 a.m.
    final label = await showDialog<String>(
      context: context,
      barrierDismissible: !required,
      builder: (ctx) {
        return SkotiqDialog(
          title: title,
          icon: annotation.type == CustomAnnotationType.text
              ? SkotiqIcons.edit
              : SkotiqIcons.target,
          width: 420,
          showCloseButton: !required,
          onClose: () => Navigator.of(ctx).pop(null),
          scrollableBody: false,
          actions: [
            SkotiqButton(
              label: 'Cancel',
              variant: ButtonVariant.ghost,
              onPressed: () => Navigator.of(ctx).pop(null),
            ),
            SkotiqButton(
              label: 'Add',
              variant: ButtonVariant.primary,
              onPressed: () => Navigator.of(ctx).pop(controller.text),
            ),
          ],
          child: ConstrainedBox(
            constraints: AdaptiveDialogConstraints.hybrid(
              context,
              designMaxWidth: 400,
            ),
            child: SkotiqTextField(
              controller: controller,
              autofocus: true,
              hint: required ? 'Enter text…' : 'Optional label…',
              onSubmitted: (value) => Navigator.of(ctx).pop(value),
            ),
          ),
        );
      },
    );

    if (label == null) return; // Cancelled
    if (required && label.trim().isEmpty) return; // Text tool needs text

    final finalAnnotation = annotation.copyWith(
      id: 'custom_${DateTime.now().microsecondsSinceEpoch}',
      label: label.trim(),
    );
    ref.read(customAnnotationsProvider.notifier).add(finalAnnotation);
  }

  @override
  Widget build(BuildContext context) {
    final tool = ref.watch(customAnnotationToolProvider);
    final deleteTool = ref.watch(_deleteToolActiveProvider);
    final annotations = ref.watch(customAnnotationsProvider);

    final isDrawingActive = tool != null || deleteTool;

    // Always paint custom annotations even when no tool is active
    final painter = CustomAnnotationPainter(
      annotations: annotations,
      zoomLevel: widget.zoomLevel,
      imageOffset: widget.imageOffset,
      activeAnnotation: _activeAnnotation,
    );

    if (!isDrawingActive) {
      // No drawing tool active — just render existing annotations, pass
      // through all pointer events.
      return IgnorePointer(
        child: CustomPaint(
          painter: painter,
          size: Size.infinite,
        ),
      );
    }

    // A tool is active — capture gestures.
    Widget gestureChild = CustomPaint(
      painter: painter,
      size: Size.infinite,
    );

    if (deleteTool) {
      gestureChild = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: _onDeleteTapDown,
        child: gestureChild,
      );
    } else {
      switch (tool!) {
        case CustomAnnotationType.circle:
          gestureChild = GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: _onCirclePanStart,
            onPanUpdate: _onCirclePanUpdate,
            onPanEnd: _onCirclePanEnd,
            child: gestureChild,
          );
        case CustomAnnotationType.arrow:
          gestureChild = GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: _onArrowPanStart,
            onPanUpdate: _onArrowPanUpdate,
            onPanEnd: _onArrowPanEnd,
            child: gestureChild,
          );
        case CustomAnnotationType.text:
          gestureChild = GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapDown: _onTextTapDown,
            child: gestureChild,
          );
      }
    }

    // Show a custom cursor to indicate drawing mode
    return MouseRegion(
      cursor:
          deleteTool ? SystemMouseCursors.click : SystemMouseCursors.precise,
      child: gestureChild,
    );
  }
}

// Drawing toolbar

/// A small floating toolbar for selecting annotation drawing tools.
///
/// Positioned at the bottom-center of the image area. Shows circle, arrow,
/// text, and delete tool icons, plus a "Clear All" button.
class CustomAnnotationToolbar extends ConsumerWidget {
  final SkotiqColors colors;

  const CustomAnnotationToolbar({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeTool = ref.watch(customAnnotationToolProvider);
    final deleteTool = ref.watch(_deleteToolActiveProvider);
    final annotationCount = ref.watch(customAnnotationsProvider).length;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        // absolute: drawing toolbar is a fixed-palette overlay on the image canvas
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ToolButton(
            icon: SkotiqIcons.circle,
            tooltip: 'Draw Circle',
            isActive: activeTool == CustomAnnotationType.circle,
            colors: colors,
            onTap: () {
              ref.read(_deleteToolActiveProvider.notifier).state = false;
              _toggleAnnotationTool(ref, CustomAnnotationType.circle);
            },
          ),
          _ToolButton(
            icon: LucideIcons.arrowUpRight,
            tooltip: 'Draw Arrow',
            isActive: activeTool == CustomAnnotationType.arrow,
            colors: colors,
            onTap: () {
              ref.read(_deleteToolActiveProvider.notifier).state = false;
              _toggleAnnotationTool(ref, CustomAnnotationType.arrow);
            },
          ),
          _ToolButton(
            icon: LucideIcons.type,
            tooltip: 'Add Text Note',
            isActive: activeTool == CustomAnnotationType.text,
            colors: colors,
            onTap: () {
              ref.read(_deleteToolActiveProvider.notifier).state = false;
              _toggleAnnotationTool(ref, CustomAnnotationType.text);
            },
          ),
          Container(
            width: 1,
            height: 20,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            // absolute: divider in fixed-palette overlay toolbar
            color: Colors.white.withValues(alpha: 0.2),
          ),
          _ToolButton(
            icon: SkotiqIcons.delete,
            tooltip: 'Delete Annotation',
            isActive: deleteTool,
            colors: colors,
            onTap: () {
              ref.read(customAnnotationToolProvider.notifier).state = null;
              ref.read(_deleteToolActiveProvider.notifier).state = !deleteTool;
            },
          ),
          if (annotationCount > 0) ...[
            Container(
              width: 1,
              height: 20,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              // absolute: divider in fixed-palette overlay toolbar
              color: Colors.white.withValues(alpha: 0.2),
            ),
            _ToolButton(
              icon: SkotiqIcons.error,
              tooltip: 'Clear All ($annotationCount)',
              isActive: false,
              colors: colors,
              onTap: () => _confirmClearAll(context, ref),
            ),
          ],
        ],
      ),
    );
  }

  void _toggleAnnotationTool(WidgetRef ref, CustomAnnotationType tool) {
    final current = ref.read(customAnnotationToolProvider);
    ref.read(customAnnotationToolProvider.notifier).state =
        current == tool ? null : tool;
  }

  void _confirmClearAll(BuildContext context, WidgetRef ref) {
    showDialog<bool>(
      context: context,
      // absolute: fixed-palette annotation dialog (matches the image-overlay tool)
      builder: (ctx) => AlertDialog(
        backgroundColor: context.skotiqColors.surfaceOverlay,
        title: Text(
          'Clear all annotations?',
          style: SkotiqTypography.sectionTitle.copyWith(
            color: context.skotiqColors.textPrimary,
          ),
        ),
        content: Text(
          'This removes every annotation you have drawn on this frame.',
          style: SkotiqTypography.bodySm.copyWith(
            color: context.skotiqColors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Cancel',
              style: SkotiqTypography.button.copyWith(
                color: context.skotiqColors.textSecondary,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              'Clear all',
              style: SkotiqTypography.button.copyWith(
                color: context.skotiqColors.error,
              ),
            ),
          ),
        ],
      ),
    ).then((confirmed) {
      if (confirmed == true) {
        ref.read(customAnnotationsProvider.notifier).clear();
        ref.read(customAnnotationToolProvider.notifier).state = null;
        ref.read(_deleteToolActiveProvider.notifier).state = false;
      }
    });
  }
}

class _ToolButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final bool isActive;
  final SkotiqColors colors;
  final VoidCallback onTap;

  const _ToolButton({
    required this.icon,
    required this.tooltip,
    required this.isActive,
    required this.colors,
    required this.onTap,
  });

  @override
  State<_ToolButton> createState() => _ToolButtonState();
}

class _ToolButtonState extends State<_ToolButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return SkotiqTooltip(
      message: widget.tooltip,
      position: SkotiqTooltipPosition.bottom,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              // absolute: fixed-palette tool button over the image canvas
              color: widget.isActive
                  ? const Color(0xFF00E676).withValues(alpha: 0.25)
                  : _hovered
                      ? Colors.white.withValues(alpha: 0.12)
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
              border: widget.isActive
                  ? Border.all(
                      color: const Color(0xFF00E676).withValues(alpha: 0.5))
                  : null,
            ),
            child: Icon(
              widget.icon,
              size: 16,
              // absolute: fixed-palette tool icon over the image canvas
              color: widget.isActive
                  ? const Color(0xFF00E676)
                  : _hovered
                      ? Colors.white
                      : Colors.white70,
            ),
          ),
        ),
      ),
    );
  }
}
