part of '../overlay_painters.dart';

/// Bottom space the canvas's corner HUD panels occupy, so the painters
/// anchored to the same corners stay off them.
///
/// Each is the panel's 14px anchor plus its height plus a gap. Bottom-left is
/// the at-a-glance quality stack (frame science chip, sub-quality badge,
/// guiding indicator); bottom-right is the histogram glass — an eyebrow, 44px
/// of bars and a caption inside 10px padding, which measures 104px at the
/// shipped type scale. Both are pinned by a layout test that measures the real
/// widgets, so a panel that grows fails that test rather than silently
/// colliding again.
abstract final class PreviewReadoutInsets {
  /// Clearance for the bottom-LEFT quality stack.
  static const double bottomLeft = 14 + 80 + 8;

  /// Clearance for the bottom-RIGHT histogram glass.
  static const double bottomRight = 14 + 104 + 8;
}

/// Ink for text painted directly onto the frame.
///
/// image-anchored: painted over the frame, theme-blind by design (05 §14).
/// The same rule that makes glass borrow the dark palette applies to a label
/// drawn straight onto a photograph — there is no surface behind it to take a
/// colour from.
const Color _overlayInk = Colors.white;

/// The drop shadow that keeps [_overlayInk] legible over a bright nebula.
///
/// image-anchored: painted over the frame, theme-blind by design (05 §14).
const Color _overlayShadow = Colors.black;

/// Compass rose: the North axis.
@visibleForTesting
const Color namedCompassNorth = Color(0xFFFF4444);

/// Compass rose: the East axis.
@visibleForTesting
const Color namedCompassEast = Color(0xFF44AAFF);

class CompassOverlayPainter extends CustomPainter {
  /// WCS rotation angle in degrees, as the solver reports it. Only used when
  /// [axes] is null, and then read with the sky's own parity.
  final double rotationDegrees;

  /// North and east on the image as unit vectors in pixel coordinates (+y
  /// along the stored row order, which is screen-down), from the frame's CD
  /// matrix. A scalar rotation cannot carry the parity of a mirrored frame.
  final ({double northX, double northY, double eastX, double eastY})? axes;

  /// Radius of the compass circle in logical pixels.
  final double radius;

  /// Margin from the corner of the canvas.
  final double margin;

  /// Space to leave at the bottom of the canvas, when the corner it anchors to
  /// is already occupied. Defaults to [margin].
  final double? bottomMargin;

  /// Axis hues resolved for the active theme at construction.
  ///
  /// The two arrows are a categorical series encoded in HUE, so painted raw the
  /// East arrow and its label drew #44AAFF — a bright blue — over a red-night
  /// preview, undoing the dark adaptation the mode exists to protect. In red
  /// night the two separate by lightness instead, and the N/E glyphs at the
  /// tips carry the rest of the distinction.
  final Color northColor;
  final Color eastColor;

  CompassOverlayPainter({
    required this.rotationDegrees,
    required SkotiqColors colors,
    this.axes,
    this.radius = 60.0,
    this.margin = 20.0,
    this.bottomMargin,
  })  : northColor = SkotiqChartColors.forTheme(namedCompassNorth, colors),
        eastColor = SkotiqChartColors.forTheme(namedCompassEast, colors);

  /// The circle this painter will draw on a canvas of [size].
  ///
  /// Exposed so a layout test can prove the rose does not land under the
  /// bottom-right stats readout — a separately-anchored sibling in the same
  /// stack, which nothing else constrains it against.
  Rect boundsIn(Size size) {
    final center = _centerIn(size);
    return Rect.fromCircle(center: center, radius: radius);
  }

  Offset _centerIn(Size size) => Offset(
        size.width - margin - radius,
        size.height - (bottomMargin ?? margin) - radius,
      );

  @override
  void paint(Canvas canvas, Size size) {
    // Position in bottom-right corner
    final center = _centerIn(size);
    final centerX = center.dx;
    final centerY = center.dy;

    // Semi-transparent background circle
    final bgPaint = Paint()
      ..color = const Color(0xAA000000)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius, bgPaint);

    // Border
    final borderPaint = Paint()
      ..color = const Color(0x55FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawCircle(center, radius, borderPaint);

    final dirs = axes ?? _axesFromRotation(rotationDegrees);

    // Arrow length: slightly shorter than radius to leave room for labels
    final arrowLength = radius * 0.65;
    const arrowHeadSize = 8.0;

    final nTip = Offset(
      centerX + dirs.northX * arrowLength,
      centerY + dirs.northY * arrowLength,
    );

    final nPaint = Paint()
      ..color = northColor
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(center, nTip, nPaint);
    _drawArrowHead(canvas, center, nTip, arrowHeadSize, nPaint);
    _drawLabel(canvas, 'N', nTip, Offset(dirs.northX, dirs.northY), northColor);

    final eTip = Offset(
      centerX + dirs.eastX * arrowLength,
      centerY + dirs.eastY * arrowLength,
    );

    final ePaint = Paint()
      ..color = eastColor
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(center, eTip, ePaint);
    _drawArrowHead(canvas, center, eTip, arrowHeadSize, ePaint);

    _drawLabel(canvas, 'E', eTip, Offset(dirs.eastX, dirs.eastY), eastColor);
  }

  static ({double northX, double northY, double eastX, double eastY})
      _axesFromRotation(double rotationDegrees) => GnomonicProjection(
            SolvedWcs(
              raHours: 0,
              decDegrees: 0,
              rotationDeg: rotationDegrees,
              pixelScaleArcsec: 1,
              imageWidth: 100,
              imageHeight: 100,
            ),
          ).skyAxesOnImage;

  void _drawArrowHead(
      Canvas canvas, Offset from, Offset to, double headSize, Paint paint) {
    final dx = to.dx - from.dx;
    final dy = to.dy - from.dy;
    final angle = math.atan2(dy, dx);

    final arrowPaint = Paint()
      ..color = paint.color
      ..style = PaintingStyle.fill;

    final path = Path();
    path.moveTo(to.dx, to.dy);
    path.lineTo(
      to.dx - headSize * math.cos(angle - 0.45),
      to.dy - headSize * math.sin(angle - 0.45),
    );
    path.lineTo(
      to.dx - headSize * math.cos(angle + 0.45),
      to.dy - headSize * math.sin(angle + 0.45),
    );
    path.close();
    canvas.drawPath(path, arrowPaint);
  }

  void _drawLabel(Canvas canvas, String text, Offset tipPosition,
      Offset direction, Color color) {
    final textSpan = TextSpan(
      text: text,
      style: SkotiqTypography.bodySm
          .copyWith(fontWeight: FontWeight.w700, color: color, shadows: const [
        Shadow(blurRadius: 4, color: _overlayShadow, offset: Offset(0, 0)),
        Shadow(blurRadius: 2, color: _overlayShadow, offset: Offset(1, 1)),
      ]),
    );
    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();

    // Place label just beyond the arrow tip, pushed outward along the arrow direction
    const labelOffset = 10.0;
    final labelDx = direction.dx * labelOffset;
    final labelDy = direction.dy * labelOffset;

    textPainter.paint(
      canvas,
      Offset(
        tipPosition.dx + labelDx - textPainter.width / 2,
        tipPosition.dy + labelDy - textPainter.height / 2,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant CompassOverlayPainter oldDelegate) {
    return oldDelegate.rotationDegrees != rotationDegrees ||
        oldDelegate.axes != axes ||
        oldDelegate.radius != radius ||
        oldDelegate.margin != margin ||
        oldDelegate.bottomMargin != bottomMargin;
  }
}

/// Scale bar overlay showing angular size reference based on plate solve pixel scale.
///
/// Draws a horizontal bar with tick marks and a label showing the angular extent
/// (e.g. "5'" or "1°"), positioned at the bottom-left of the canvas. The bar
/// length is chosen to be a "nice" angular value that fills roughly 15-25% of
/// the image width.
class ScaleBarPainter extends CustomPainter {
  /// Pixel scale from plate solve in arcseconds per pixel.
  final double pixelScaleArcsecPerPixel;

  /// Width of the image in pixels (at native resolution).
  final double imageWidthPixels;

  /// Current zoom level applied to the image.
  final double zoomLevel;

  /// Margin from the corner of the canvas.
  final double margin;

  /// Space to leave at the bottom of the canvas, when the corner it anchors to
  /// is already occupied. Defaults to [margin].
  final double? bottomMargin;

  ScaleBarPainter({
    required this.pixelScaleArcsecPerPixel,
    required this.imageWidthPixels,
    required this.zoomLevel,
    this.margin = 20.0,
    this.bottomMargin,
  });

  /// Y of the bar itself on a canvas of [size]. The label sits below it and the
  /// background plate extends ~8px above; exposed so a layout test can prove the
  /// bar clears the bottom-left histogram card it shares the stack with.
  double barBaselineIn(Size size) =>
      size.height - (bottomMargin ?? margin) - 12;

  // "Nice" angular values in arcseconds with their human-readable labels.
  static const List<(double arcsec, String label)> _niceScales = [
    (1.0, '1"'),
    (2.0, '2"'),
    (5.0, '5"'),
    (10.0, '10"'),
    (30.0, '30"'),
    (60.0, "1'"),
    (120.0, "2'"),
    (300.0, "5'"),
    (600.0, "10'"),
    (900.0, "15'"),
    (1800.0, "30'"),
    (3600.0, '1\u00B0'),
    (7200.0, '2\u00B0'),
    (18000.0, '5\u00B0'),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (pixelScaleArcsecPerPixel <= 0 || imageWidthPixels <= 0) return;

    // The viewport width of the image is imageWidthPixels * zoomLevel.
    // We want the bar to be roughly 15-25% of the viewport image width.
    final viewportImageWidth = imageWidthPixels * zoomLevel;
    final targetBarPixels = viewportImageWidth * 0.20;
    // Target angular size in arcseconds that would produce this bar length
    final targetArcsec = targetBarPixels * pixelScaleArcsecPerPixel / zoomLevel;

    // Find the "nice" scale closest to targetArcsec
    String bestLabel = _niceScales.first.$2;
    double bestArcsec = _niceScales.first.$1;
    double bestDiff = (targetArcsec - bestArcsec).abs();

    for (final (arcsec, label) in _niceScales) {
      final diff = (targetArcsec - arcsec).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        bestArcsec = arcsec;
        bestLabel = label;
      }
    }

    // Convert chosen angular size to viewport pixels
    final barLengthPixels = (bestArcsec / pixelScaleArcsecPerPixel) * zoomLevel;

    // Clamp to reasonable range to avoid tiny or huge bars
    if (barLengthPixels < 20 || barLengthPixels > size.width * 0.8) return;

    // Position at bottom-left
    final barY = barBaselineIn(size);
    final barX = margin;

    // Semi-transparent background behind the bar and label
    const bgPadding = 8.0;
    const tickHeight = 8.0;

    // Measure text first so we can size the background
    final textSpan = TextSpan(
      text: bestLabel,
      style: SkotiqTypography.caption
          .copyWith(fontWeight: FontWeight.w600, color: _overlayInk, shadows: [
        Shadow(blurRadius: 4, color: _overlayShadow, offset: Offset(0, 0)),
        Shadow(blurRadius: 2, color: _overlayShadow, offset: Offset(1, 1)),
      ]),
    );
    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();

    final bgWidth =
        math.max(barLengthPixels, textPainter.width) + bgPadding * 2;
    final bgHeight = tickHeight + 4 + textPainter.height + bgPadding * 2;
    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        barX - bgPadding,
        barY - tickHeight - bgPadding,
        bgWidth,
        bgHeight,
      ),
      const Radius.circular(SkotiqTokens.radiusInline4),
    );
    final bgPaint = Paint()
      ..color = const Color(0xAA000000)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(bgRect, bgPaint);

    // Draw the horizontal bar
    final barPaint = Paint()
      ..color = _overlayInk
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square;

    canvas.drawLine(
      Offset(barX, barY),
      Offset(barX + barLengthPixels, barY),
      barPaint,
    );

    // Tick marks at each end
    canvas.drawLine(
      Offset(barX, barY - tickHeight),
      Offset(barX, barY),
      barPaint,
    );
    canvas.drawLine(
      Offset(barX + barLengthPixels, barY - tickHeight),
      Offset(barX + barLengthPixels, barY),
      barPaint,
    );

    // Label centered below the bar
    textPainter.paint(
      canvas,
      Offset(
        barX + (barLengthPixels - textPainter.width) / 2,
        barY + 4,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant ScaleBarPainter oldDelegate) {
    return oldDelegate.pixelScaleArcsecPerPixel != pixelScaleArcsecPerPixel ||
        oldDelegate.imageWidthPixels != imageWidthPixels ||
        oldDelegate.zoomLevel != zoomLevel ||
        oldDelegate.margin != margin ||
        oldDelegate.bottomMargin != bottomMargin;
  }
}

/// Celestial coordinate grid overlay that renders RA/Dec grid lines
/// projected onto the image using plate solve WCS data.
///
/// Grid spacing is automatically selected based on the field of view to
/// produce approximately 5-8 grid lines across the image. Lines of constant
/// RA appear as curves (due to gnomonic projection) and are labeled in
