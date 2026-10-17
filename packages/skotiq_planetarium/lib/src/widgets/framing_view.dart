import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../coordinate_system.dart';
import '../services/mosaic_planner.dart';
import '../providers/planetarium_providers.dart';

/// Framing view widget for imaging planning
class FramingView extends ConsumerStatefulWidget {
  /// Target coordinates
  final CelestialCoordinate? target;

  /// Callback when target changes
  final ValueChanged<CelestialCoordinate>? onTargetChanged;

  /// Callback when rotation changes
  final ValueChanged<double>? onRotationChanged;

  /// Whether mosaic mode is enabled
  final bool showMosaic;
  final bool showCrosshair;

  const FramingView({
    super.key,
    this.target,
    this.onTargetChanged,
    this.onRotationChanged,
    this.showMosaic = false,
    this.showCrosshair = false,
  });

  @override
  ConsumerState<FramingView> createState() => _FramingViewState();
}

class _FramingViewState extends ConsumerState<FramingView> {
  double _zoom = 1.0;
  Offset _pan = Offset.zero;
  bool _isDraggingFOV = false;
  bool _isRotatingFOV = false;

  @override
  Widget build(BuildContext context) {
    final equipmentFOV = ref.watch(equipmentFOVProvider);
    final mosaicPlan = ref.watch(mosaicPlanProvider);

    return Stack(
      children: [
        // Background with survey loading state
        _buildBackground(),

        // Grid overlay
        CustomPaint(
          painter: _GridPainter(zoom: _zoom, pan: _pan),
          size: Size.infinite,
        ),

        // FOV indicator
        if (equipmentFOV.fov != null)
          Center(
            child: GestureDetector(
              onPanStart: (details) {
                // Check if we're dragging the rotation handle
                final center = Offset(
                  MediaQuery.sizeOf(context).width / 2 + _pan.dx,
                  MediaQuery.sizeOf(context).height / 2 + _pan.dy,
                );
                final fovSize = equipmentFOV.fov;
                final fovH = fovSize != null ? fovSize.$2 * 50 * _zoom : 0.0;
                final handlePos = center - Offset(0, fovH / 2 + 20);

                if ((details.localPosition - handlePos).distance < 20) {
                  _isRotatingFOV = true;
                } else {
                  _isDraggingFOV = true;
                }
              },
              onPanUpdate: (details) {
                if (_isRotatingFOV) {
                  // Calculate rotation from drag
                  final center = Offset(
                    MediaQuery.sizeOf(context).width / 2 + _pan.dx,
                    MediaQuery.sizeOf(context).height / 2 + _pan.dy,
                  );
                  final angle = math.atan2(
                    details.localPosition.dx - center.dx,
                    -(details.localPosition.dy - center.dy),
                  );
                  final newRotation = angle * 180 / math.pi;
                  ref
                      .read(equipmentFOVProvider.notifier)
                      .setRotation(newRotation);
                  widget.onRotationChanged?.call(newRotation);
                } else if (_isDraggingFOV) {
                  setState(() {
                    _pan += details.delta;
                  });
                }
              },
              onPanEnd: (_) {
                _isDraggingFOV = false;
                _isRotatingFOV = false;
              },
              child: CustomPaint(
                painter: _FOVPainter(
                  fovWidth: equipmentFOV.fov!.$1,
                  fovHeight: equipmentFOV.fov!.$2,
                  rotation: equipmentFOV.rotation,
                  zoom: _zoom,
                  pan: _pan,
                ),
                size: Size.infinite,
              ),
            ),
          ),

        // Mosaic panels
        if (widget.showMosaic && mosaicPlan.plan != null)
          CustomPaint(
            painter: _MosaicOverlayPainter(
              plan: mosaicPlan.plan!,
              zoom: _zoom,
              pan: _pan,
            ),
            size: Size.infinite,
          ),

        // Center crosshair
        if (widget.showCrosshair)
          Center(
            child: CustomPaint(
              painter: _CrosshairPainter(),
              size: const Size(60, 60),
            ),
          ),

        // Zoom controls
        Positioned(
          right: 16,
          bottom: 16,
          child: _ZoomControls(
            zoom: _zoom,
            onZoomIn: () =>
                setState(() => _zoom = (_zoom * 1.5).clamp(0.25, 4.0)),
            onZoomOut: () =>
                setState(() => _zoom = (_zoom / 1.5).clamp(0.25, 4.0)),
            onReset: () => setState(() {
              _zoom = 1.0;
              _pan = Offset.zero;
            }),
          ),
        ),

        // Scale indicator
        Positioned(left: 16, bottom: 16, child: _ScaleIndicator(zoom: _zoom)),
      ],
    );
  }

  Widget _buildBackground() {
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.center,
          radius: 1.5,
          colors: [Color(0xFF15151F), Color(0xFF0A0A12)],
        ),
      ),
      child: CustomPaint(
        painter: _StarFieldPainter(zoom: _zoom),
        size: Size.infinite,
      ),
    );
  }
}

class _StarFieldPainter extends CustomPainter {
  final double zoom;

  _StarFieldPainter({required this.zoom});

  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(42);
    final paint = Paint();

    // Draw random stars
    for (var i = 0; i < 300; i++) {
      final x = random.nextDouble() * size.width;
      final y = random.nextDouble() * size.height;
      final brightness = random.nextDouble() * 0.5 + 0.2;
      final radius = (random.nextDouble() * 1.5 + 0.3) * math.sqrt(zoom);

      paint.color = Colors.white.withValues(alpha: brightness);
      canvas.drawCircle(Offset(x, y), radius, paint);
    }

    // Draw a faint "DSO" in center
    final center = size.center(Offset.zero);
    final gradient = RadialGradient(
      colors: [
        Colors.pinkAccent.withValues(alpha: 0.15),
        Colors.pinkAccent.withValues(alpha: 0.05),
        Colors.transparent,
      ],
    );
    final rect = Rect.fromCircle(center: center, radius: 80 * zoom);
    paint.shader = gradient.createShader(rect);
    canvas.drawCircle(center, 80 * zoom, paint);
  }

  @override
  bool shouldRepaint(covariant _StarFieldPainter oldDelegate) {
    return zoom != oldDelegate.zoom;
  }
}

class _GridPainter extends CustomPainter {
  final double zoom;
  final Offset pan;

  _GridPainter({required this.zoom, required this.pan});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.1)
      ..strokeWidth = 0.5;

    final center = size.center(Offset.zero) + pan;
    final spacing = 50.0 * zoom;

    // Draw vertical lines
    for (var x = center.dx % spacing; x < size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }

    // Draw horizontal lines
    for (var y = center.dy % spacing; y < size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }

    // Draw center lines
    paint.color = Colors.white.withValues(alpha: 0.2);
    canvas.drawLine(
      Offset(center.dx, 0),
      Offset(center.dx, size.height),
      paint,
    );
    canvas.drawLine(Offset(0, center.dy), Offset(size.width, center.dy), paint);
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) {
    return zoom != oldDelegate.zoom || pan != oldDelegate.pan;
  }
}

class _FOVPainter extends CustomPainter {
  final double fovWidth;
  final double fovHeight;
  final double rotation;
  final double zoom;
  final Offset pan;

  _FOVPainter({
    required this.fovWidth,
    required this.fovHeight,
    required this.rotation,
    required this.zoom,
    required this.pan,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero) + pan;

    // Convert FOV to screen pixels
    final rectWidth = fovWidth * 50 * zoom;
    final rectHeight = fovHeight * 50 * zoom;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rotation * math.pi / 180);

    final rect = Rect.fromCenter(
      center: Offset.zero,
      width: rectWidth,
      height: rectHeight,
    );

    // Fill with semi-transparent color
    final fillPaint = Paint()
      ..color = const Color(0x1A00E676)
      ..style = PaintingStyle.fill;
    canvas.drawRect(rect, fillPaint);

    // Draw border
    final borderPaint = Paint()
      ..color = const Color(0xFF00E676)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawRect(rect, borderPaint);

    // Draw corner indicators
    _drawCorners(canvas, rect, borderPaint);

    // Draw rotation handle
    final handlePaint = Paint()
      ..color = const Color(0xFF00E676)
      ..style = PaintingStyle.fill;

    final handleY = -rectHeight / 2 - 15;
    canvas.drawCircle(Offset(0, handleY), 8, handlePaint);
    canvas.drawLine(
      Offset(0, -rectHeight / 2),
      Offset(0, handleY + 8),
      borderPaint,
    );

    // Draw cardinal directions
    _drawCardinalLabels(canvas, rect);

    canvas.restore();

    // Draw FOV label below
    final fovText =
        '${fovWidth.toStringAsFixed(2)}° × ${fovHeight.toStringAsFixed(2)}°';
    final textPainter = TextPainter(
      text: TextSpan(
        text: fovText,
        style: const TextStyle(
          color: Color(0xFF00E676),
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(
        center.dx - textPainter.width / 2,
        center.dy + rectHeight / 2 * math.cos(rotation * math.pi / 180) + 20,
      ),
    );
  }

  void _drawCorners(Canvas canvas, Rect rect, Paint paint) {
    final cornerLength = math.min(rect.width, rect.height) * 0.1;

    // Top-left
    canvas.drawLine(
      Offset(rect.left, rect.top + cornerLength),
      Offset(rect.left, rect.top),
      paint,
    );
    canvas.drawLine(
      Offset(rect.left, rect.top),
      Offset(rect.left + cornerLength, rect.top),
      paint,
    );

    // Top-right
    canvas.drawLine(
      Offset(rect.right - cornerLength, rect.top),
      Offset(rect.right, rect.top),
      paint,
    );
    canvas.drawLine(
      Offset(rect.right, rect.top),
      Offset(rect.right, rect.top + cornerLength),
      paint,
    );

    // Bottom-right
    canvas.drawLine(
      Offset(rect.right, rect.bottom - cornerLength),
      Offset(rect.right, rect.bottom),
      paint,
    );
    canvas.drawLine(
      Offset(rect.right, rect.bottom),
      Offset(rect.right - cornerLength, rect.bottom),
      paint,
    );

    // Bottom-left
    canvas.drawLine(
      Offset(rect.left + cornerLength, rect.bottom),
      Offset(rect.left, rect.bottom),
      paint,
    );
    canvas.drawLine(
      Offset(rect.left, rect.bottom),
      Offset(rect.left, rect.bottom - cornerLength),
      paint,
    );
  }

  void _drawCardinalLabels(Canvas canvas, Rect rect) {
    final style = TextStyle(
      color: Colors.white.withValues(alpha: 0.5),
      fontSize: 9,
    );

    final labels = ['N', 'E', 'S', 'W'];
    final positions = [
      Offset(0, rect.top + 8),
      Offset(rect.right - 12, 0),
      Offset(0, rect.bottom - 14),
      Offset(rect.left + 4, 0),
    ];

    for (var i = 0; i < 4; i++) {
      final textPainter = TextPainter(
        text: TextSpan(text: labels[i], style: style),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        positions[i] - Offset(textPainter.width / 2, textPainter.height / 2),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FOVPainter oldDelegate) {
    return fovWidth != oldDelegate.fovWidth ||
        fovHeight != oldDelegate.fovHeight ||
        rotation != oldDelegate.rotation ||
        zoom != oldDelegate.zoom ||
        pan != oldDelegate.pan;
  }
}

class _MosaicOverlayPainter extends CustomPainter {
  final MosaicPlan plan;
  final double zoom;
  final Offset pan;

  _MosaicOverlayPainter({
    required this.plan,
    required this.zoom,
    required this.pan,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero) + pan;
    final scale = 50.0 * zoom;

    final borderPaint = Paint()
      ..color = const Color(0xFF2196F3).withValues(alpha: 0.8)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final fillPaint = Paint()
      ..color = const Color(0xFF2196F3).withValues(alpha: 0.1)
      ..style = PaintingStyle.fill;

    for (final panel in plan.panels) {
      // Calculate panel position relative to center
      final dx = (panel.center.ra - plan.center.ra) * 15 * scale;
      final dy = -(panel.center.dec - plan.center.dec) * scale;

      final panelCenter = center + Offset(dx, dy);
      final panelWidth = panel.fovWidth * scale;
      final panelHeight = panel.fovHeight * scale;

      canvas.save();
      canvas.translate(panelCenter.dx, panelCenter.dy);
      canvas.rotate(panel.rotation * math.pi / 180);

      final rect = Rect.fromCenter(
        center: Offset.zero,
        width: panelWidth,
        height: panelHeight,
      );

      canvas.drawRect(rect, fillPaint);
      canvas.drawRect(rect, borderPaint);

      // Draw panel number
      final textPainter = TextPainter(
        text: TextSpan(
          text: panel.name,
          style: const TextStyle(
            color: Color(0xFF2196F3),
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(-textPainter.width / 2, -textPainter.height / 2),
      );

      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _MosaicOverlayPainter oldDelegate) {
    return plan != oldDelegate.plan ||
        zoom != oldDelegate.zoom ||
        pan != oldDelegate.pan;
  }
}

class _CrosshairPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final paint = Paint()
      ..color = const Color(0xFFFF5722)
      ..strokeWidth = 1;

    // Draw crosshair
    canvas.drawLine(Offset(0, center.dy), Offset(size.width, center.dy), paint);
    canvas.drawLine(
      Offset(center.dx, 0),
      Offset(center.dx, size.height),
      paint,
    );

    // Draw center circle
    paint.style = PaintingStyle.stroke;
    canvas.drawCircle(center, 5, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ZoomControls extends StatelessWidget {
  final double zoom;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;

  const _ZoomControls({
    required this.zoom,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ZoomButton(icon: Icons.add, onTap: onZoomIn),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
            child: Text(
              '${(zoom * 100).round()}%',
              style: const TextStyle(color: Colors.white70, fontSize: 10),
            ),
          ),
          _ZoomButton(icon: Icons.remove, onTap: onZoomOut),
          const Divider(height: 1, color: Colors.white24),
          _ZoomButton(icon: Icons.center_focus_strong, onTap: onReset),
        ],
      ),
    );
  }
}

class _ZoomButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _ZoomButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(icon, color: Colors.white70, size: 18),
      ),
    );
  }
}

class _ScaleIndicator extends StatelessWidget {
  final double zoom;

  const _ScaleIndicator({required this.zoom});

  @override
  Widget build(BuildContext context) {
    // Calculate scale bar length (10 arcminutes)
    final barLength = 10 / 60 * 50 * zoom;

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Scale',
            style: TextStyle(color: Colors.white54, fontSize: 9),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: barLength.clamp(30.0, 100.0),
                height: 2,
                color: Colors.white,
              ),
              const SizedBox(width: 4),
              const Text(
                "10'",
                style: TextStyle(color: Colors.white70, fontSize: 10),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
