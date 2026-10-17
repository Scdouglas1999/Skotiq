part of '../diagnostics_screen.dart';

class _TiltDirectionPainter extends CustomPainter {
  final String direction;
  final double magnitude;
  final Color arrowColor;
  final Color ringColor;
  final Color textColor;

  _TiltDirectionPainter({
    required this.direction,
    required this.magnitude,
    required this.arrowColor,
    required this.ringColor,
    required this.textColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 8;

    // Draw outer ring
    final ringPaint = Paint()
      ..color = ringColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(center, radius, ringPaint);

    // Draw inner dot (center reference)
    final dotPaint = Paint()
      ..color = ringColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 3, dotPaint);

    // Draw cardinal labels
    final textStyle =
        TextStyle(fontSize: SkotiqTypography.fontSize9, color: textColor);
    _drawLabel(
        canvas, 'T', Offset(center.dx, center.dy - radius - 2), textStyle);
    _drawLabel(
        canvas, 'B', Offset(center.dx, center.dy + radius + 2), textStyle);
    _drawLabel(
        canvas, 'L', Offset(center.dx - radius - 2, center.dy), textStyle);
    _drawLabel(
        canvas, 'R', Offset(center.dx + radius + 2, center.dy), textStyle);

    // Draw arrow toward dominant direction
    if (direction == 'unknown') return;

    final angle = _directionToAngle(direction);
    final arrowLength = (magnitude / 100.0).clamp(0.1, 0.9) * radius;
    final arrowEnd = Offset(
      center.dx + arrowLength * math.cos(angle),
      center.dy + arrowLength * math.sin(angle),
    );

    final arrowPaint = Paint()
      ..color = arrowColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(center, arrowEnd, arrowPaint);

    // Arrowhead
    const headLength = 8.0;
    final headAngle1 = angle + math.pi * 0.8;
    final headAngle2 = angle - math.pi * 0.8;
    canvas.drawLine(
      arrowEnd,
      Offset(
        arrowEnd.dx + headLength * math.cos(headAngle1),
        arrowEnd.dy + headLength * math.sin(headAngle1),
      ),
      arrowPaint,
    );
    canvas.drawLine(
      arrowEnd,
      Offset(
        arrowEnd.dx + headLength * math.cos(headAngle2),
        arrowEnd.dy + headLength * math.sin(headAngle2),
      ),
      arrowPaint,
    );
  }

  double _directionToAngle(String dir) {
    switch (dir) {
      case 'top edge':
        return -math.pi / 2; // Up
      case 'bottom edge':
        return math.pi / 2; // Down
      case 'left edge':
        return math.pi; // Left
      case 'right edge':
        return 0; // Right
      default:
        return 0;
    }
  }

  void _drawLabel(
      Canvas canvas, String text, Offset position, TextStyle style) {
    final span = TextSpan(text: text, style: style);
    final painter = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset(position.dx - painter.width / 2, position.dy - painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _TiltDirectionPainter old) =>
      direction != old.direction ||
      magnitude != old.magnitude ||
      arrowColor != old.arrowColor;
}

// Collimation card

class _CollimationCard extends StatelessWidget {
  final OpticalTrainDiagnostics diagnostics;
  final SkotiqColors colors;

  const _CollimationCard({
    required this.diagnostics,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final score = diagnostics.collimationScore;
    // With no astrometric residuals on both sides of the edge/centre split the
    // ratio is 0 — arithmetically the best score there is — so this card badged
    // "Centered" and stated "Center and edge behavior look balanced" for a
    // session with zero residual vectors. See [OpticalTrainDiagnostics].
    final measured = diagnostics.collimationMeasured;
    final severity = !measured
        ? 'Not measured'
        : score >= 25
            ? 'Off-center'
            : score >= 15
                ? 'Slight offset'
                : 'Centered';
    final severityColor = !measured
        ? colors.textMuted
        : score >= 25
            ? colors.error
            : score >= 15
                ? colors.warning
                : colors.success;

    return _DiagCard(
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.target, size: 16, color: colors.primary),
              const SizedBox(width: 8),
              // Expanded, not Spacer: this card sits in a 320 px column and
              // the widest badge ("Not measured") pushed the fixed-width title
              // past the edge.
              Expanded(
                child: Text(
                  'Collimation',
                  overflow: TextOverflow.ellipsis,
                  style: SkotiqTypography.h5
                      .copyWith(color: colors.textPrimary),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: severityColor.withValues(alpha: 0.15),
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline4),
                ),
                child: Text(
                  severity,
                  style: SkotiqTypography.labelStrongSm
                      .copyWith(color: severityColor),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Collimation visualizer: concentric rings with off-center indicator
          Center(
            child: SizedBox(
              width: 100,
              height: 100,
              child: CustomPaint(
                painter: _CollimationPainter(
                  score: score,
                  statusColor: severityColor,
                  ringColor: colors.border,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              measured
                  ? 'Lower is better. Edge/center residual ratio: ${score.toStringAsFixed(1)}'
                  : 'Lower is better. Edge/center residual ratio: —',
              style: TextStyle(
                  fontSize: SkotiqTypography.fontSize12,
                  color: colors.textSecondary),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              !measured
                  ? 'No astrometric residuals on both sides of the field, so '
                      'collimation was not measured. Needs plate-solved frames '
                      'with residual vectors.'
                  : score >= 25
                      ? 'A strong offset usually points to spacing or alignment that needs attention.'
                      : score >= 15
                          ? 'A mild offset is present. Recheck spacing before making larger adjustments.'
                          : 'Center and edge behavior look balanced for this session.',
              style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: colors.textMuted),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

class _CollimationPainter extends CustomPainter {
  final double score;
  final Color statusColor;
  final Color ringColor;

  _CollimationPainter({
    required this.score,
    required this.statusColor,
    required this.ringColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2 - 4;

    final ringPaint = Paint()
      ..color = ringColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    // Draw concentric rings
    for (int i = 1; i <= 4; i++) {
      canvas.drawCircle(center, maxRadius * i / 4, ringPaint);
    }

    // Draw crosshair
    final crossPaint = Paint()
      ..color = ringColor.withValues(alpha: 0.5)
      ..strokeWidth = 0.5;
    canvas.drawLine(
      Offset(center.dx - maxRadius, center.dy),
      Offset(center.dx + maxRadius, center.dy),
      crossPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - maxRadius),
      Offset(center.dx, center.dy + maxRadius),
      crossPaint,
    );

    // Draw offset indicator dot — the further off-center, the worse the collimation
    final offsetFraction = (score / 100.0).clamp(0.0, 0.8);
    final offsetDot = Offset(
      center.dx + offsetFraction * maxRadius * 0.5,
      center.dy - offsetFraction * maxRadius * 0.3,
    );
    final dotPaint = Paint()
      ..color = statusColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(offsetDot, 5, dotPaint);
  }

  @override
  bool shouldRepaint(covariant _CollimationPainter old) =>
      score != old.score || statusColor != old.statusColor;
}

// PSF field map card
