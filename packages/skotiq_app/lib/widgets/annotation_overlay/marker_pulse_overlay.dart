part of '../annotation_overlay.dart';

/// Overlay that shows a pulse animation on a specific marker when triggered
/// from the annotation list panel.
class _MarkerPulseOverlay extends ConsumerStatefulWidget {
  final ImageAnnotation annotation;
  final double zoomLevel;
  final Offset imageOffset;
  final AnnotationMarkerStyle markerStyle;

  const _MarkerPulseOverlay({
    required this.annotation,
    required this.zoomLevel,
    required this.imageOffset,
    required this.markerStyle,
  });

  @override
  ConsumerState<_MarkerPulseOverlay> createState() =>
      _MarkerPulseOverlayState();
}

class _MarkerPulseOverlayState extends ConsumerState<_MarkerPulseOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _opacityAnimation;
  String? _currentPulseId;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );

    _scaleAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 1.5)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 50,
      ),
      TweenSequenceItem(
        tween:
            Tween(begin: 1.5, end: 1.0).chain(CurveTween(curve: Curves.easeIn)),
        weight: 50,
      ),
    ]).animate(_pulseController);

    _opacityAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.0, end: 0.6)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 30,
      ),
      TweenSequenceItem(
        tween: ConstantTween(0.6),
        weight: 40,
      ),
      TweenSequenceItem(
        tween:
            Tween(begin: 0.6, end: 0.0).chain(CurveTween(curve: Curves.easeIn)),
        weight: 30,
      ),
    ]).animate(_pulseController);

    _pulseController.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        // Clear the pulse provider after animation completes
        ref.read(annotationPulseObjectProvider.notifier).state = null;
        setState(() {
          _currentPulseId = null;
        });
      }
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pulseId = ref.watch(annotationPulseObjectProvider);

    // Trigger animation when a new pulse ID arrives
    if (pulseId != null && pulseId != _currentPulseId) {
      _currentPulseId = pulseId;
      _pulseController.forward(from: 0.0);
    }

    if (_currentPulseId == null || !_pulseController.isAnimating) {
      return const SizedBox.shrink();
    }

    // Find the object to pulse
    final object = widget.annotation.objects
        .where((obj) => obj.id == _currentPulseId)
        .firstOrNull;

    if (object == null) return const SizedBox.shrink();

    final screenPos = imageToViewport(
      imagePoint: Offset(object.x, object.y),
      imageOffset: widget.imageOffset,
      zoomLevel: widget.zoomLevel,
    );

    final baseMarkerSize =
        (widget.markerStyle.scaleBySize && object.size != null)
            ? (object.size! * 2.0).clamp(
                  widget.markerStyle.minMarkerSize,
                  widget.markerStyle.maxMarkerSize,
                ) *
                widget.zoomLevel
            : widget.markerStyle.minMarkerSize;

    // Use a SizedBox.expand wrapped with IgnorePointer so the pulse overlay
    // doesn't interfere with pointer events on the annotation overlay.
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _pulseController,
        builder: (context, child) {
          final scale = _scaleAnimation.value;
          final opacity = _opacityAnimation.value;
          final pulseRadius = baseMarkerSize * scale;

          return CustomPaint(
            painter: _PulseCirclePainter(
              center: screenPos,
              radius: pulseRadius,
              opacity: opacity,
            ),
            size: Size.infinite,
          );
        },
      ),
    );
  }
}

/// Painter for the pulse circle highlight on selected annotations
class _PulseCirclePainter extends CustomPainter {
  final Offset center;
  final double radius;
  final double opacity;

  _PulseCirclePainter({
    required this.center,
    required this.radius,
    required this.opacity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0.0 || radius <= 0.0) return;

    // Outer ring
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = Colors.white.withValues(alpha: opacity);
    canvas.drawCircle(center, radius, ringPaint);

    // Glow
    final glowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.0
      ..color = Colors.white.withValues(alpha: opacity * 0.3)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0);
    canvas.drawCircle(center, radius, glowPaint);
  }

  @override
  bool shouldRepaint(covariant _PulseCirclePainter oldDelegate) {
    return oldDelegate.center != center ||
        oldDelegate.radius != radius ||
        oldDelegate.opacity != opacity;
  }
}
