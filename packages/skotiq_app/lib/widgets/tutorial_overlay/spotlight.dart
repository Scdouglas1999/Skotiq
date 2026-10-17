part of '../tutorial_overlay.dart';

class _SpotlightHitTestWidget extends SingleChildRenderObjectWidget {
  final Rect? targetRect;
  final double padding;
  final bool isInteractive;
  final VoidCallback? onSpotlightTapped;

  const _SpotlightHitTestWidget({
    required super.child,
    required this.targetRect,
    required this.padding,
    required this.isInteractive,
    this.onSpotlightTapped,
  });

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _SpotlightHitTestRenderBox(
      targetRect: targetRect,
      padding: padding,
      isInteractive: isInteractive,
      onSpotlightTapped: onSpotlightTapped,
    );
  }

  @override
  void updateRenderObject(
      BuildContext context, _SpotlightHitTestRenderBox renderObject) {
    renderObject
      ..targetRect = targetRect
      ..padding = padding
      ..isInteractive = isInteractive
      ..onSpotlightTapped = onSpotlightTapped;
  }
}

class _SpotlightHitTestRenderBox extends RenderProxyBox {
  Rect? _targetRect;
  double _padding;
  bool _isInteractive;
  VoidCallback? onSpotlightTapped;

  _SpotlightHitTestRenderBox({
    Rect? targetRect,
    required double padding,
    required bool isInteractive,
    this.onSpotlightTapped,
  })  : _targetRect = targetRect,
        _padding = padding,
        _isInteractive = isInteractive;

  Rect? get targetRect => _targetRect;
  set targetRect(Rect? value) {
    if (_targetRect != value) {
      _targetRect = value;
      markNeedsPaint();
    }
  }

  double get padding => _padding;
  set padding(double value) {
    if (_padding != value) {
      _padding = value;
      markNeedsPaint();
    }
  }

  bool get isInteractive => _isInteractive;
  set isInteractive(bool value) {
    if (_isInteractive != value) {
      _isInteractive = value;
      markNeedsPaint();
    }
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // No resolvable target means there is nothing to protect, and absorbing
    // every hit turned an un-anchored coach mark into a modal: a step reading
    // "Click the Connections tab" was drawn over a screen that has none, and
    // the scrim ate the click on the nav entry that would have got the
    // operator there. Let the app underneath stay usable; the tooltip card is
    // its own hit target and still takes Next/Back/Skip.
    if (_targetRect == null) return false;

    if (!_isInteractive) {
      // Still need to add ourselves to absorb the hit
      result.add(BoxHitTestEntry(this, position));
      return true;
    }

    // Check if the hit is within the spotlight hole
    final spotlightRect = _targetRect!.inflate(_padding);
    if (spotlightRect.contains(position)) {
      // Hit is in the spotlight - let it pass through to underlying widget
      // Call the callback if provided
      onSpotlightTapped?.call();
      return false;
    }

    // Hit is in the dim area - absorb it
    result.add(BoxHitTestEntry(this, position));
    return true;
  }
}

class _SpotlightPainter extends CustomPainter {
  final Rect? targetRect;
  final double padding;
  final Color dimColor;
  final SpotlightShape shape;

  _SpotlightPainter({
    this.targetRect,
    this.padding = 8,
    required this.dimColor,
    this.shape = SpotlightShape.roundedRect,
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

    // Draw dim with spotlight cutout based on shape
    final path = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));

    final inflatedRect = target.inflate(padding);

    switch (shape) {
      case SpotlightShape.circle:
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

      case SpotlightShape.pill:
        // Horizontal oval/capsule shape
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

      case SpotlightShape.roundedRect:
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

/// Painter for the expanding ring pulse effect
class _ExpandingRingPainter extends CustomPainter {
  final Rect targetRect;
  final double padding;
  final double ringProgress;
  final double ringOpacity;
  final Color ringColor;
  final SpotlightShape shape;

  _ExpandingRingPainter({
    required this.targetRect,
    required this.padding,
    required this.ringProgress,
    required this.ringOpacity,
    required this.ringColor,
    required this.shape,
  });

  /// Build a positioned widget containing the ring painter
  static Widget buildWidget({
    required Rect targetRect,
    required double padding,
    required double ringProgress,
    required double ringOpacity,
    required Color ringColor,
    required SpotlightShape shape,
  }) {
    // Calculate the maximum expansion distance
    const maxExpansion = 24.0;
    final currentExpansion = maxExpansion * ringProgress;
    final expandedPadding = padding + currentExpansion;

    // Calculate bounds for the ring
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
      case SpotlightShape.circle:
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

      case SpotlightShape.pill:
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

      case SpotlightShape.roundedRect:
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
