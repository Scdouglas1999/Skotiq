import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../polar_alignment_error_format.dart';

/// Identity for the painted reticle square, so its bounds can be compared with
/// the caption's.
const ValueKey<String> allSkyReticleCanvasKey =
    ValueKey<String>('allSkyReticle.canvas');

/// Radius of the error marker dot. The marker is CLAMPED to the outer ring, so
/// an off-scale error overhangs the ring by exactly this much.
const double _markerRadius = 6.0;

/// Gap between the outer ring and the cardinal labels. Must exceed
/// [_markerRadius] or a clamped marker lands on top of a label.
const double _cardinalGap = 8.0;

/// Inset from the widget edge to the outer ring. Must leave room for a cardinal
/// label — [_cardinalGap] plus the label's own height — or the bottom label
/// ('Dn') is drawn a pixel past the bottom edge.
const double _reticleInset = 24.0;

const TextStyle _cardinalTextStyle = TextStyle(
  fontSize: SkotiqTypography.fontSize10,
  fontWeight: FontWeight.w600,
);

/// The outer-ring radius for a reticle painted at [size].
double allSkyReticleRadius(Size size) =>
    (math.min(size.width, size.height) / 2) - _reticleInset;

/// Where a cardinal label lands for a reticle painted at [size].
///
/// Exposed so the layout invariants the audit caught — a label inside the box
/// and clear of the clamped marker — are assertable instead of eyeballed.
Rect allSkyCardinalLabelRect({
  required Size size,
  required Alignment alignment,
  required String text,
}) {
  final painter = _layOutCardinal(text, const Color(0xFF000000));
  final center = Offset(size.width / 2, size.height / 2);
  final offset = _cardinalOffset(
    center,
    allSkyReticleRadius(size),
    painter.size,
    alignment,
  );
  return offset & painter.size;
}

/// The area the marker dot can reach for a reticle painted at [size]: the ring
/// it is clamped to, grown by the dot's own radius.
Rect allSkyMarkerReach(Size size) => Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: allSkyReticleRadius(size) + _markerRadius,
    );

TextPainter _layOutCardinal(String text, Color color) => TextPainter(
      text: TextSpan(
          text: text, style: _cardinalTextStyle.copyWith(color: color)),
      textDirection: TextDirection.ltr,
    )..layout();

Offset _cardinalOffset(
  Offset center,
  double radius,
  Size textSize,
  Alignment alignment,
) {
  if (alignment == Alignment.topCenter) {
    return Offset(
      center.dx - textSize.width / 2,
      center.dy - radius - textSize.height - _cardinalGap,
    );
  }
  if (alignment == Alignment.bottomCenter) {
    return Offset(
      center.dx - textSize.width / 2,
      center.dy + radius + _cardinalGap,
    );
  }
  if (alignment == Alignment.centerRight) {
    return Offset(
      center.dx + radius + _cardinalGap,
      center.dy - textSize.height / 2,
    );
  }
  return Offset(
    center.dx - radius - textSize.width - _cardinalGap,
    center.dy - textSize.height / 2,
  );
}

/// Live convergence visualization for all-sky polar alignment.
///
/// Renders a target reticle with a moving marker that reflects the
/// instantaneous polar-axis error vector. As the user adjusts the mount's
/// azimuth and altitude bolts, the marker drifts toward the bullseye; when
/// it sits inside the acceptance ring for the hold duration the alignment
/// auto-completes.
///
/// The visualization is intentionally **linear** in the error magnitude:
/// a 60″ error sits at 50% radius if the outer ring is 120″, a 30″ error
/// at 25% radius, etc. Users get a direct mechanical-feedback feel for how
/// much the bolts need to move.
class AllSkyTargetReticle extends StatelessWidget {
  /// Current azimuth error in arcseconds, or null when nothing has been
  /// measured yet. Positive = mechanical pole east of true pole (rotate
  /// azimuth bolt westward).
  ///
  /// Nullable on purpose: substituting zero makes an unmeasured axis
  /// indistinguishable from a perfectly aligned one, and lets the idle screen
  /// claim "Within acceptance" before a single frame exists.
  final double? azimuthErrorArcsec;

  /// Current altitude error in arcseconds, or null when nothing has been
  /// measured yet. Positive = mechanical pole above true pole (lower altitude
  /// bolt).
  final double? altitudeErrorArcsec;

  /// Acceptance threshold in arcseconds. The inner highlighted ring is
  /// drawn at this radius; once the marker is inside it, alignment is
  /// good enough for the user's target imaging precision.
  final double acceptanceThresholdArcsec;

  /// Outer ring scale in arcseconds. Errors beyond this are clamped to the
  /// rim. Default = 4× threshold so coarse adjustment is still readable.
  final double outerScaleArcsec;

  /// Whether this is the first frame (no error data yet). Renders an empty
  /// reticle with a "waiting" overlay.
  final bool waitingForFirstFrame;

  /// Total side length in pixels (square widget).
  final double size;

  const AllSkyTargetReticle({
    super.key,
    required this.azimuthErrorArcsec,
    required this.altitudeErrorArcsec,
    required this.acceptanceThresholdArcsec,
    this.outerScaleArcsec = 0.0,
    this.waitingForFirstFrame = false,
    this.size = 280.0,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    // Default outer scale: 4× the acceptance threshold, but ensure a
    // sensible floor so a sub-arcsec threshold still renders cleanly.
    final outer = outerScaleArcsec > 0
        ? outerScaleArcsec
        : math.max(acceptanceThresholdArcsec * 4.0, 60.0);

    final az = azimuthErrorArcsec;
    final alt = altitudeErrorArcsec;
    final measured = az != null && alt != null;
    final totalError = measured ? math.sqrt(az * az + alt * alt) : null;
    final withinThreshold =
        totalError != null && totalError <= acceptanceThresholdArcsec;

    // The numeric caption lives BELOW the reticle box, never inside it. Drawn
    // inside, it landed in the same ~30px band as the bottom compass label and
    // as an altitude-dominated marker clamped to the bottom of the rim — three
    // elements stacked on each other with no guard.
    final caption = Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            totalError == null ? '—' : formatPolarError(totalError),
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize22,
              fontWeight: FontWeight.w700,
              color: withinThreshold ? colors.success : colors.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            textAlign: TextAlign.center,
          ),
          Text(
            !measured
                ? 'Not measured'
                : withinThreshold
                    ? 'Within acceptance — hold steady'
                    : 'Az ${_formatSigned(az)}   '
                        'Alt ${_formatSigned(alt)}',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize11,
              color: colors.textMuted,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );

    return SizedBox(
      width: size,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Flexible + AspectRatio, not a fixed square: this panel is squeezed
          // to ~160px on a short viewport, and the reticle has to give way
          // there rather than push the numbers off the bottom.
          Flexible(
            child: AspectRatio(
              aspectRatio: 1,
              child: Stack(
                children: [
                  CustomPaint(
                    key: allSkyReticleCanvasKey,
                    size: Size(size, size),
                    painter: _ReticlePainter(
                      azimuthErrorArcsec: azimuthErrorArcsec,
                      altitudeErrorArcsec: altitudeErrorArcsec,
                      acceptanceThresholdArcsec: acceptanceThresholdArcsec,
                      outerScaleArcsec: outer,
                      waitingForFirstFrame: waitingForFirstFrame,
                      colors: colors,
                    ),
                  ),
                  if (waitingForFirstFrame)
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 36,
                            height: 36,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: colors.primary,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Waiting for first plate solve...',
                            style: TextStyle(
                              fontSize: SkotiqTypography.fontSize13,
                              color: colors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (!waitingForFirstFrame) caption,
        ],
      ),
    );
  }

  /// Explicit-sign az/alt caption. The magnitude goes through
  /// [formatPolarError] so a 3-degree residual reads "3° 20' 15\"" rather than
  /// the 12005.0 the raw arcsecond count would print.
  static String _formatSigned(double value) {
    final sign = value >= 0 ? '+' : '−';
    return '$sign${formatPolarError(value.abs())}';
  }
}

class _ReticlePainter extends CustomPainter {
  final double? azimuthErrorArcsec;
  final double? altitudeErrorArcsec;
  final double acceptanceThresholdArcsec;
  final double outerScaleArcsec;
  final bool waitingForFirstFrame;
  final SkotiqColors colors;

  _ReticlePainter({
    required this.azimuthErrorArcsec,
    required this.altitudeErrorArcsec,
    required this.acceptanceThresholdArcsec,
    required this.outerScaleArcsec,
    required this.waitingForFirstFrame,
    required this.colors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = allSkyReticleRadius(size);
    final acceptanceRadius =
        maxRadius * (acceptanceThresholdArcsec / outerScaleArcsec);

    // Outer ring
    final outerPaint = Paint()
      ..color = colors.border
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(center, maxRadius, outerPaint);

    // Mid ring (50% scale)
    canvas.drawCircle(center, maxRadius * 0.5, outerPaint);

    // Acceptance threshold ring — highlighted
    final acceptancePaint = Paint()
      ..color = colors.success.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(center, acceptanceRadius, acceptancePaint);

    // Crosshair lines
    final crosshairPaint = Paint()
      ..color = colors.border
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(center.dx - maxRadius, center.dy),
      Offset(center.dx + maxRadius, center.dy),
      crosshairPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - maxRadius),
      Offset(center.dx, center.dy + maxRadius),
      crosshairPaint,
    );

    // Labels: N/S/E/W mark the cardinal bolt-direction hints
    _drawCardinal(canvas, center, maxRadius, 'Up', Alignment.topCenter);
    _drawCardinal(canvas, center, maxRadius, 'Dn', Alignment.bottomCenter);
    _drawCardinal(canvas, center, maxRadius, 'E', Alignment.centerRight);
    _drawCardinal(canvas, center, maxRadius, 'W', Alignment.centerLeft);

    // No marker without a measurement: a dot on the bullseye is a claim of
    // perfect alignment, which a null-coalesced 0 would assert while idle.
    final az = azimuthErrorArcsec;
    final alt = altitudeErrorArcsec;
    if (waitingForFirstFrame || az == null || alt == null) {
      return;
    }

    // Convert (az, alt) error in arcseconds into pixel offset from center.
    // Sign convention from PolarMisalignment:
    //   * azimuth_error > 0 → mechanical pole sits east of true pole.
    //     Render the marker on the EAST side of the reticle (positive X).
    //   * altitude_error > 0 → mechanical pole sits above true pole.
    //     Render the marker on the TOP side (negative Y, since screen Y
    //     grows downward).
    // Both denominators can legitimately be zero: `outerScaleArcsec` before a
    // first solve populates it, and `maxRadius` whenever the panel is squeezed
    // (this reticle sits in a Column that overflows on a short viewport). A
    // zero scale makes the division infinite, the clamp below then computes
    // `maxRadius / infinity == 0`, and `infinity * 0` is NaN — which reaches
    // `canvas.drawCircle` and throws "Offset argument contained a NaN value",
    // taking down the whole polar-alignment screen rather than degrading.
    // Substituting finite fallbacks keeps the marker at the centre, which is
    // the honest rendering when there is no scale or no room to plot against.
    final safeScale = outerScaleArcsec.isFinite && outerScaleArcsec > 0
        ? outerScaleArcsec
        : 1.0;
    final safeRadius = maxRadius.isFinite && maxRadius > 0 ? maxRadius : 0.0;
    final dx = (az / safeScale) * safeRadius;
    final dy = -(alt / safeScale) * safeRadius;

    // Clamp the marker to the rim so off-scale errors are still visible.
    final magnitude = math.sqrt(dx * dx + dy * dy);
    final double clampedDx;
    final double clampedDy;
    if (magnitude > safeRadius && magnitude > 0) {
      final scale = safeRadius / magnitude;
      clampedDx = dx * scale;
      clampedDy = dy * scale;
    } else {
      clampedDx = dx;
      clampedDy = dy;
    }

    final markerCenter = Offset(center.dx + clampedDx, center.dy + clampedDy);

    final totalError = math.sqrt(az * az + alt * alt);
    final withinThreshold = totalError <= acceptanceThresholdArcsec;

    // Draw a guide arrow from the center to the marker indicating the
    // direction the mechanical pole is offset.
    if (totalError > 1.0) {
      final arrowPaint = Paint()
        ..color = withinThreshold
            ? colors.success.withValues(alpha: 0.4)
            : colors.warning.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;
      canvas.drawLine(center, markerCenter, arrowPaint);

      // Arrowhead
      final angle = math.atan2(clampedDy, clampedDx);
      const headSize = 8.0;
      final head1 = Offset(
        markerCenter.dx - headSize * math.cos(angle - math.pi / 6),
        markerCenter.dy - headSize * math.sin(angle - math.pi / 6),
      );
      final head2 = Offset(
        markerCenter.dx - headSize * math.cos(angle + math.pi / 6),
        markerCenter.dy - headSize * math.sin(angle + math.pi / 6),
      );
      canvas.drawLine(markerCenter, head1, arrowPaint);
      canvas.drawLine(markerCenter, head2, arrowPaint);
    }

    // Marker dot
    final markerPaint = Paint()
      ..color = withinThreshold ? colors.success : colors.error
      ..style = PaintingStyle.fill;
    canvas.drawCircle(markerCenter, _markerRadius, markerPaint);

    final markerOutline = Paint()
      ..color = colors.background
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(markerCenter, _markerRadius, markerOutline);

    // Center bullseye
    final bullseyePaint = Paint()
      ..color = colors.primary
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 3.0, bullseyePaint);
  }

  void _drawCardinal(
    Canvas canvas,
    Offset center,
    double radius,
    String text,
    Alignment alignment,
  ) {
    final textPainter = _layOutCardinal(text, colors.textMuted);
    textPainter.paint(
      canvas,
      _cardinalOffset(center, radius, textPainter.size, alignment),
    );
  }

  @override
  bool shouldRepaint(_ReticlePainter old) =>
      old.azimuthErrorArcsec != azimuthErrorArcsec ||
      old.altitudeErrorArcsec != altitudeErrorArcsec ||
      old.acceptanceThresholdArcsec != acceptanceThresholdArcsec ||
      old.outerScaleArcsec != outerScaleArcsec ||
      old.waitingForFirstFrame != waitingForFirstFrame;
}
