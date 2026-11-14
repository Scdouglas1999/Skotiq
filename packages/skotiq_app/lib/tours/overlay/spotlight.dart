part of '../tour_overlay.dart';

/// The cutout drawn around a target, chosen from its proportions.
enum _SpotlightShape { circle, roundedRect, pill }

/// How far the cutout stands off its target.
const double _spotlightPadding = 8;

/// Blocks pointer events on the dimmed area and lets them through the cutout,
/// so the highlighted control can be used while the rest of the app waits.
class _SpotlightScrim extends SingleChildRenderObjectWidget {
  const _SpotlightScrim({required this.target, required super.child});

  final Rect? target;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSpotlightScrim(target);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSpotlightScrim renderObject,
  ) {
    renderObject.target = target;
  }
}

class _RenderSpotlightScrim extends RenderProxyBox {
  _RenderSpotlightScrim(this.target);

  Rect? target;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // With nothing to spotlight there is nothing to protect, and absorbing
    // every hit would turn an un-anchored card into a modal over a screen the
    // user may need to reach. The card is its own hit target.
    final hole = target?.inflate(_spotlightPadding);
    if (hole == null || hole.contains(position)) return false;
    result.add(BoxHitTestEntry(this, position));
    return true;
  }
}

class _SpotlightPainter extends CustomPainter {
  final Rect? targetRect;
  final double padding;
  final Color dimColor;
  final _SpotlightShape shape;

  _SpotlightPainter({
    this.targetRect,
    this.padding = 8,
    required this.dimColor,
    this.shape = _SpotlightShape.roundedRect,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Nothing to spotlight. An un-anchored step is a floating coach mark: the
    // card carries it, and the app stays visible and usable underneath. A
    // full-screen dim here reads as a modal scrim over a screen the step is not
    // about, and the matching hit test would make that appearance true.
    final target = targetRect;
    if (target == null) return;

    final paint = Paint()..color = dimColor;

    final path = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));

    final inflatedRect = target.inflate(padding);

    switch (shape) {
      case _SpotlightShape.circle:
        // Use the larger dimension for radius to ensure entire target is visible
        final radius = math.max(inflatedRect.width, inflatedRect.height) / 2;
        path.addOval(
          Rect.fromCenter(
            center: inflatedRect.center,
            width: radius * 2,
            height: radius * 2,
          ),
        );
        break;

      case _SpotlightShape.pill:
        final verticalRadius = inflatedRect.height / 2;
        final horizontalRadius = inflatedRect.width / 2 + verticalRadius * 0.5;
        path.addRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: inflatedRect.center,
              width: horizontalRadius * 2,
              height: inflatedRect.height,
            ),
            Radius.circular(verticalRadius),
          ),
        );
        break;

      case _SpotlightShape.roundedRect:
        path.addRRect(
          RRect.fromRectAndRadius(
            inflatedRect,
            const Radius.circular(SkotiqTokens.radiusLg),
          ),
        );
        break;
    }

    path.fillType = PathFillType.evenOdd;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SpotlightPainter oldDelegate) {
    return targetRect != oldDelegate.targetRect ||
        dimColor != oldDelegate.dimColor ||
        padding != oldDelegate.padding ||
        shape != oldDelegate.shape;
  }
}

class _ExpandingRingPainter extends CustomPainter {
  final Rect targetRect;
  final double padding;
  final double ringProgress;
  final double ringOpacity;
  final Color ringColor;
  final _SpotlightShape shape;

  _ExpandingRingPainter({
    required this.targetRect,
    required this.padding,
    required this.ringProgress,
    required this.ringOpacity,
    required this.ringColor,
    required this.shape,
  });

  static Widget buildWidget({
    required Rect targetRect,
    required double padding,
    required double ringProgress,
    required double ringOpacity,
    required Color ringColor,
    required _SpotlightShape shape,
  }) {
    const maxExpansion = 24.0;
    final currentExpansion = maxExpansion * ringProgress;
    final expandedPadding = padding + currentExpansion;

    final inflatedRect = targetRect.inflate(expandedPadding + 4);

    return Positioned(
      left: inflatedRect.left,
      top: inflatedRect.top,
      width: inflatedRect.width,
      height: inflatedRect.height,
      child: IgnorePointer(
        child: CustomPaint(
          painter: _ExpandingRingPainter(
            targetRect: Rect.fromLTWH(
              targetRect.left - inflatedRect.left,
              targetRect.top - inflatedRect.top,
              targetRect.width,
              targetRect.height,
            ),
            padding: padding,
            ringProgress: ringProgress,
            ringOpacity: ringOpacity,
            ringColor: ringColor,
            shape: shape,
          ),
        ),
      ),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (ringOpacity <= 0) return;

    const maxExpansion = 24.0;
    final currentExpansion = maxExpansion * ringProgress;

    final paint = Paint()
      ..color = ringColor.withValues(alpha: ringOpacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    final inflatedRect = targetRect.inflate(padding + currentExpansion);

    switch (shape) {
      case _SpotlightShape.circle:
        final radius = math.max(inflatedRect.width, inflatedRect.height) / 2;
        canvas.drawOval(
          Rect.fromCenter(
            center: inflatedRect.center,
            width: radius * 2,
            height: radius * 2,
          ),
          paint,
        );
        break;

      case _SpotlightShape.pill:
        final verticalRadius = inflatedRect.height / 2;
        final horizontalRadius = inflatedRect.width / 2 + verticalRadius * 0.5;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: inflatedRect.center,
              width: horizontalRadius * 2,
              height: inflatedRect.height,
            ),
            Radius.circular(verticalRadius),
          ),
          paint,
        );
        break;

      case _SpotlightShape.roundedRect:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            inflatedRect,
            const Radius.circular(SkotiqTokens.radiusLg),
          ),
          paint,
        );
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _ExpandingRingPainter oldDelegate) {
    return targetRect != oldDelegate.targetRect ||
        padding != oldDelegate.padding ||
        ringProgress != oldDelegate.ringProgress ||
        ringOpacity != oldDelegate.ringOpacity ||
        ringColor != oldDelegate.ringColor ||
        shape != oldDelegate.shape;
  }
}
