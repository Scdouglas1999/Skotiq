import 'dart:async';

import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Marker showing user's observation location on the weather radar map.
///
/// Displays as a dot with an outer ring to indicate the current observing
/// location. It pulses a few times on arrival to draw the eye to the user's
/// position, then settles: the location does not move, so a permanent
/// animation carries no information and would hold the whole app at 60fps for
/// as long as the radar is on screen.
class LocationMarker extends StatefulWidget {
  /// Theme colors for styling the marker
  final SkotiqColors colors;

  const LocationMarker({
    super.key,
    required this.colors,
  });

  @override
  State<LocationMarker> createState() => _LocationMarkerState();
}

class _LocationMarkerState extends State<LocationMarker>
    with SingleTickerProviderStateMixin {
  /// One pulse cycle. Also the period the gate repeats on.
  static const Duration _pulsePeriod = Duration(milliseconds: 1500);

  /// How long the marker pulses for before settling — three cycles, matching
  /// the attention pulse on [TransientAlertBadge].
  static const Duration _attentionSpan = Duration(milliseconds: 4500);

  /// Midpoint of the tween, so the settled marker keeps its normal size.
  static const double _restingValue = 0.5;

  late AnimationController _controller;
  late Animation<double> _pulseAnimation;
  Timer? _settleTimer;
  bool _pulsing = true;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: _pulsePeriod,
      vsync: this,
    );

    _pulseAnimation = Tween<double>(
      begin: 0.8,
      end: 1.2,
    ).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeInOut,
      ),
    );

    // The pulse is started by the OnScreenAnimationGate in build(), not here: a
    // repeat that outlives visibility schedules a frame on every vsync and
    // stops the whole app from idling.
    _settleTimer = Timer(_attentionSpan, _settle);
  }

  /// Ends the attention pulse and parks the marker at its resting size.
  void _settle() {
    if (!mounted) {
      return;
    }
    // Clearing `repeating` is what stops the controller: the gate owns the
    // repeat it started, and stopping it here instead would let the next
    // rebuild start it again.
    setState(() => _pulsing = false);
    _controller.value = _restingValue;
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final highlightColor = Theme.of(context).colorScheme.onPrimary;

    // The marker sits in flutter_map's marker layer, which carries no repaint
    // boundaries of its own, so without this one the 40x40 pulse dirties the
    // layer holding every radar and base tile beneath it and the whole map
    // re-rasterises on each vsync instead of just the dot.
    //
    // The boundary has to stay OUTSIDE the gate: the gate decides the animation
    // is invisible when its paint observer stops painting, and a boundary
    // between the two would confine every repaint below the observer and stall
    // the pulse after two ticks.
    return RepaintBoundary(
      child: OnScreenAnimationGate(
        controller: _controller,
        repeating: _pulsing,
        reverse: true,
        // The pulse drives the painter through `repaint:` rather than an
        // AnimatedBuilder. Rebuilding the marker widget each frame invalidates
        // layout up into the map's LayoutBuilder, which rebuilds every tile and
        // marker layer at vsync; repainting a painter skips build and layout.
        child: CustomPaint(
          painter: _LocationMarkerPainter(
            colors: widget.colors,
            highlightColor: highlightColor,
            pulse: _pulseAnimation,
          ),
          size: const Size(40, 40),
        ),
      ),
    );
  }
}

/// Custom painter for the location marker
class _LocationMarkerPainter extends CustomPainter {
  final SkotiqColors colors;
  final Color highlightColor;
  final Animation<double> pulse;

  _LocationMarkerPainter({
    required this.colors,
    required this.highlightColor,
    required this.pulse,
  }) : super(repaint: pulse);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final baseRadius = size.width / 6;
    final pulseScale = pulse.value;

    // Outer pulsing ring
    final outerRingPaint = Paint()
      ..color = colors.primary.withValues(alpha: 0.3 * (2.0 - pulseScale))
      ..style = PaintingStyle.fill;

    canvas.drawCircle(
      center,
      baseRadius * 2.5 * pulseScale,
      outerRingPaint,
    );

    // Middle ring (static)
    final middleRingPaint = Paint()
      ..color = colors.primary.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    canvas.drawCircle(
      center,
      baseRadius * 2.0,
      middleRingPaint,
    );

    // Inner dot (solid)
    final innerDotPaint = Paint()
      ..color = colors.primary
      ..style = PaintingStyle.fill;

    canvas.drawCircle(
      center,
      baseRadius,
      innerDotPaint,
    );

    // Center highlight (white dot)
    final highlightPaint = Paint()
      ..color = highlightColor
      ..style = PaintingStyle.fill;

    canvas.drawCircle(
      center,
      baseRadius * 0.4,
      highlightPaint,
    );
  }

  @override
  bool shouldRepaint(_LocationMarkerPainter oldDelegate) {
    // The pulse repaints through `repaint:`, so only the static inputs matter.
    return oldDelegate.highlightColor != highlightColor ||
        oldDelegate.colors != colors ||
        oldDelegate.pulse != pulse;
  }
}
