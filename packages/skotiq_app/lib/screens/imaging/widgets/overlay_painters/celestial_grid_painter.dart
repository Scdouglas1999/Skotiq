part of '../overlay_painters.dart';

class CelestialGridPainter extends CustomPainter {
  final PlateSolveData plateSolve;
  final double zoomLevel;
  final Offset imageOffset;

  CelestialGridPainter({
    required this.plateSolve,
    required this.zoomLevel,
    required this.imageOffset,
  });

  // Grid spacing candidates in degrees
  static const _wideSpacingsDeg = [30.0, 15.0, 10.0, 5.0, 2.0, 1.0, 0.5];
  // Narrow field spacings in degrees (arcminute-scale)
  static const _narrowSpacingsDeg = [
    0.5, // 30'
    10.0 / 60.0, // 10'
    5.0 / 60.0, // 5'
    2.0 / 60.0, // 2'
    1.0 / 60.0, // 1'
  ];

  static const _gridColor = ImageOverlayColors.coordinateGrid;
  static const _labelColor = ImageOverlayColors.coordinateLabel;
  static const _labelBgColor = ImageOverlayColors.coordinateLabelBackground;
  static const _gridStrokeWidth = 0.8;
  static const _samplesPerLine = 60;

  @override
  void paint(Canvas canvas, Size size) {
    // Determine the visible sky range by transforming the 4 image corners
    // plus midpoints of each edge to handle curved projections
    final corners = <({double ra, double dec})>[];
    final samplePoints = [
      (0.0, 0.0),
      (plateSolve.imageWidth.toDouble(), 0.0),
      (plateSolve.imageWidth.toDouble(), plateSolve.imageHeight.toDouble()),
      (0.0, plateSolve.imageHeight.toDouble()),
      (plateSolve.imageWidth / 2.0, 0.0),
      (plateSolve.imageWidth.toDouble(), plateSolve.imageHeight / 2.0),
      (plateSolve.imageWidth / 2.0, plateSolve.imageHeight.toDouble()),
      (0.0, plateSolve.imageHeight / 2.0),
    ];
    for (final (px, py) in samplePoints) {
      corners.add(plateSolve.pixelToSky(px, py));
    }

    // Find Dec range (straightforward min/max)
    var minDec = corners[0].dec;
    var maxDec = corners[0].dec;
    for (final c in corners) {
      if (c.dec < minDec) minDec = c.dec;
      if (c.dec > maxDec) maxDec = c.dec;
    }

    // Find RA range handling wraparound at 0h/24h
    final raValues = corners.map((c) => c.ra).toList();
    final raRange = _computeRaRange(raValues);
    var minRa = raRange.min;
    var maxRa = raRange.max;

    // Add small padding to ensure edge grid lines are included
    final fovDeg = math.max(plateSolve.fieldWidth, plateSolve.fieldHeight);
    final padding = fovDeg * 0.05;
    minDec -= padding;
    maxDec += padding;
    minRa -= padding;
    maxRa += padding;

    // Clamp Dec to valid range
    minDec = minDec.clamp(-90.0, 90.0);
    maxDec = maxDec.clamp(-90.0, 90.0);

    // Select grid spacing based on FOV
    final spacingDeg = _selectSpacing(fovDeg);

    final linePaint = Paint()
      ..color = _gridColor
      ..strokeWidth = _gridStrokeWidth
      ..style = PaintingStyle.stroke;

    // Clip to canvas bounds
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    // Draw Dec lines (lines of constant declination)
    final firstDec = (minDec / spacingDeg).floor() * spacingDeg;
    for (var dec = firstDec; dec <= maxDec; dec += spacingDeg) {
      if (dec < -90.0 || dec > 90.0) continue;
      _drawDecLine(canvas, size, dec, minRa, maxRa, linePaint);
    }

    // Draw RA lines (lines of constant right ascension)
    // RA spacing: use same spacing but convert to RA hours-equivalent
    // For RA we use the same degree spacing
    final firstRa = (minRa / spacingDeg).floor() * spacingDeg;
    for (var ra = firstRa; ra <= maxRa; ra += spacingDeg) {
      // Normalize RA for display
      var raNorm = ra;
      while (raNorm < 0) {
        raNorm += 360;
      }
      while (raNorm >= 360) {
        raNorm -= 360;
      }
      _drawRaLine(canvas, size, ra, raNorm, minDec, maxDec, linePaint);
    }

    canvas.restore();
  }

  /// Draw a line of constant Dec across the visible RA range
  void _drawDecLine(
    Canvas canvas,
    Size size,
    double dec,
    double minRa,
    double maxRa,
    Paint paint,
  ) {
    final path = ui.Path();
    var started = false;
    Offset? firstVisiblePoint;

    for (var i = 0; i <= _samplesPerLine; i++) {
      final t = i / _samplesPerLine;
      final ra = minRa + t * (maxRa - minRa);

      // Normalize RA for skyToPixel
      var raNorm = ra;
      while (raNorm < 0) {
        raNorm += 360;
      }
      while (raNorm >= 360) {
        raNorm -= 360;
      }

      final pixel = plateSolve.skyToPixelUnclamped(raNorm, dec);
      if (pixel == null) {
        started = false;
        continue;
      }

      final screenX = pixel.x * zoomLevel + imageOffset.dx;
      final screenY = pixel.y * zoomLevel + imageOffset.dy;
      final point = Offset(screenX, screenY);

      if (!started) {
        path.moveTo(screenX, screenY);
        started = true;
        firstVisiblePoint ??= point;
      } else {
        path.lineTo(screenX, screenY);
      }
    }

    if (firstVisiblePoint != null) {
      canvas.drawPath(path, paint);

      // Label at the left edge of the line
      final label = _formatDec(dec);
      _drawLabel(canvas, size, firstVisiblePoint, label,
          alignment: _LabelEdge.left);
    }
  }

  /// Draw a line of constant RA across the visible Dec range
  void _drawRaLine(
    Canvas canvas,
    Size size,
    double ra,
    double raNorm,
    double minDec,
    double maxDec,
    Paint paint,
  ) {
    final path = ui.Path();
    var started = false;
    Offset? firstVisiblePoint;

    for (var i = 0; i <= _samplesPerLine; i++) {
      final t = i / _samplesPerLine;
      final dec = minDec + t * (maxDec - minDec);

      final pixel = plateSolve.skyToPixelUnclamped(raNorm, dec);
      if (pixel == null) {
        started = false;
        continue;
      }

      final screenX = pixel.x * zoomLevel + imageOffset.dx;
      final screenY = pixel.y * zoomLevel + imageOffset.dy;
      final point = Offset(screenX, screenY);

      if (!started) {
        path.moveTo(screenX, screenY);
        started = true;
        firstVisiblePoint ??= point;
      } else {
        path.lineTo(screenX, screenY);
      }
    }

    if (firstVisiblePoint != null) {
      canvas.drawPath(path, paint);

      // Label at the top edge of the line
      final label = _formatRa(raNorm);
      _drawLabel(canvas, size, firstVisiblePoint, label,
          alignment: _LabelEdge.top);
    }
  }

  /// Draw a text label with a semi-transparent background at a given position
  void _drawLabel(
    Canvas canvas,
    Size size,
    Offset position,
    String text, {
    required _LabelEdge alignment,
  }) {
    final textStyle = ui.TextStyle(
      color: _labelColor,
      fontSize: SkotiqTypography.fontSize9,
      fontFamily: SkotiqTypography.fontFamilyMono,
    );
    final paragraphBuilder = ui.ParagraphBuilder(ui.ParagraphStyle(
      textAlign: TextAlign.center,
      maxLines: 1,
    ))
      ..pushStyle(textStyle)
      ..addText(text);
    final paragraph = paragraphBuilder.build()
      ..layout(const ui.ParagraphConstraints(width: 80));

    final textWidth = paragraph.longestLine;
    final textHeight = paragraph.height;
    const padding = 2.0;

    // Position label near the edge. A label wider (or taller) than the canvas
    // minus its padding would push the far bound under the 2.0 near bound and
    // throw out of paint(), taking the whole overlay down; floor the far bound
    // so an oversized label starts on canvas and clips instead.
    final maxLabelX = math.max(2.0, size.width - textWidth - padding * 2);
    final maxLabelY = math.max(2.0, size.height - textHeight - padding * 2);
    double labelX;
    double labelY;

    switch (alignment) {
      case _LabelEdge.left:
        // Clamp to left edge, vertically at the point
        labelX = position.dx.clamp(2.0, maxLabelX);
        labelY = (position.dy - textHeight / 2).clamp(2.0, maxLabelY);
      case _LabelEdge.top:
        // Horizontally at the point, clamp to top edge
        labelX = (position.dx - textWidth / 2).clamp(2.0, maxLabelX);
        labelY = position.dy.clamp(2.0, maxLabelY);
    }

    // Draw background
    final bgRect = Rect.fromLTWH(
      labelX - padding,
      labelY - padding,
      textWidth + padding * 2,
      textHeight + padding * 2,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          bgRect, const Radius.circular(SkotiqTokens.radiusInline2)),
      Paint()..color = _labelBgColor,
    );

    // Draw text
    canvas.drawParagraph(paragraph, Offset(labelX, labelY));
  }

  /// Select appropriate grid spacing for the given FOV
  double _selectSpacing(double fovDeg) {
    // Target 5-8 grid lines across the image
    const targetLines = 6.0;

    // For narrow fields (< 1 degree), use arcminute-scale spacings
    if (fovDeg < 1.0) {
      for (final spacing in _narrowSpacingsDeg) {
        final lines = fovDeg / spacing;
        if (lines >= 4 && lines <= 10) return spacing;
      }
      // Fallback: pick the spacing giving closest to target lines
      var bestSpacing = _narrowSpacingsDeg.last;
      var bestDiff = double.infinity;
      for (final spacing in _narrowSpacingsDeg) {
        final diff = ((fovDeg / spacing) - targetLines).abs();
        if (diff < bestDiff) {
          bestDiff = diff;
          bestSpacing = spacing;
        }
      }
      return bestSpacing;
    }

    // For wider fields, use degree-scale spacings
    for (final spacing in _wideSpacingsDeg) {
      final lines = fovDeg / spacing;
      if (lines >= 4 && lines <= 10) return spacing;
    }

    // Fallback: pick the spacing giving closest to target lines
    var bestSpacing = _wideSpacingsDeg.last;
    var bestDiff = double.infinity;
    for (final spacing in _wideSpacingsDeg) {
      final diff = ((fovDeg / spacing) - targetLines).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        bestSpacing = spacing;
      }
    }
    return bestSpacing;
  }

  /// Compute the RA range handling the 0h/24h wraparound.
  /// Returns (min, max) where max may exceed 360 if the range wraps.
  ({double min, double max}) _computeRaRange(List<double> raValues) {
    if (raValues.isEmpty) return (min: 0.0, max: 360.0);

    // Sort RA values
    final sorted = List<double>.from(raValues)..sort();

    // Find the largest gap between consecutive RA values
    var maxGap = 0.0;
    var gapEnd = 0;
    for (var i = 0; i < sorted.length; i++) {
      final next = (i + 1) % sorted.length;
      var gap = sorted[next] - sorted[i];
      if (next == 0) gap = (360.0 - sorted[i]) + sorted[0];
      if (gap > maxGap) {
        maxGap = gap;
        gapEnd = next;
      }
    }

    // The range starts at the end of the largest gap
    final minRa = sorted[gapEnd];
    final lastIdx = (gapEnd - 1 + sorted.length) % sorted.length;
    var maxRa = sorted[lastIdx];

    // If the range wraps around 0, adjust maxRa
    if (maxRa < minRa) {
      maxRa += 360.0;
    }

    return (min: minRa, max: maxRa);
  }

  /// Format RA (degrees) as HH:MM
  String _formatRa(double raDeg) => CoordinateFormat.raHmFromDegrees(
        raDeg,
        style: SexagesimalStyle.compactLetters,
        minutes: MinutesPrecision.rounded,
      );

  /// Format Dec (degrees) as +/-DD°MM'
  String _formatDec(double decDeg) => CoordinateFormat.decDm(
        decDeg,
        style: SexagesimalStyle.compactLetters,
        minutes: MinutesPrecision.rounded,
      );

  @override
  bool shouldRepaint(covariant CelestialGridPainter oldDelegate) {
    return oldDelegate.plateSolve != plateSolve ||
        oldDelegate.zoomLevel != zoomLevel ||
        oldDelegate.imageOffset != imageOffset;
  }
}

enum _LabelEdge { left, top }
