part of '../node_progress_panels.dart';

class _StarZoomPanel extends StatelessWidget {
  final SkotiqColors colors;
  final List<StarCrop> starCrops;
  final int currentIndex;
  final bool isRefreshing;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onRefresh;

  const _StarZoomPanel({
    required this.colors,
    required this.starCrops,
    required this.currentIndex,
    this.isRefreshing = false,
    required this.onPrevious,
    required this.onNext,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final crop = starCrops.isNotEmpty && currentIndex < starCrops.length
        ? starCrops[currentIndex]
        : null;

    return Container(
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
        border: Border.all(color: colors.border),
        boxShadow: [
          BoxShadow(
            // absolute: drop-shadow scrim (theme-independent)
            color: ImageOverlayColors.shadow.withValues(alpha: 0.3),
            blurRadius: 4,
            offset: const Offset(1, 1),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Star image
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: colors.surfaceAlt,
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(SkotiqTokens.radiusXs)),
            ),
            child: crop != null
                ? _buildStarImage(crop)
                : Center(
                    child: Icon(SkotiqIcons.star,
                        size: 24, color: colors.textMuted),
                  ),
          ),

          // Navigation row
          Container(
            width: 80,
            padding: const EdgeInsets.symmetric(vertical: 2),
            decoration: BoxDecoration(
              color: colors.surfaceAlt,
              borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(SkotiqTokens.radiusXs)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Previous arrow
                _buildNavButton(
                  icon: SkotiqIcons.chevronLeft,
                  onTap: starCrops.length > 1 ? onPrevious : null,
                ),
                // Counter
                Text(
                  '${currentIndex + 1}/${starCrops.length}',
                  style: TextStyle(
                      fontSize: SkotiqTypography.fontSize9,
                      color: colors.textMuted),
                ),
                // Next arrow
                _buildNavButton(
                  icon: SkotiqIcons.chevronRight,
                  onTap: starCrops.length > 1 ? onNext : null,
                ),
                // Refresh button
                if (isRefreshing)
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: SkotiqSpinner(size: 12, color: colors.primary),
                  )
                else
                  _buildNavButton(
                    icon: SkotiqIcons.refresh,
                    onTap: onRefresh,
                    size: 12,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavButton({
    required IconData icon,
    VoidCallback? onTap,
    double size = 14,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Icon(
        icon,
        size: size,
        color: onTap != null
            ? colors.textSecondary
            : colors.textMuted.withValues(alpha: 0.3),
      ),
    );
  }

  Widget _buildStarImage(StarCrop crop) {
    // Create a grayscale image from the pixel data
    try {
      final pixels = crop.pixels;
      if (pixels.isEmpty) {
        return Center(
            child: Icon(SkotiqIcons.error, size: 24, color: colors.textMuted));
      }

      // Build RGBA image from grayscale
      final rgbaPixels = <int>[];
      for (final pixel in pixels) {
        rgbaPixels.add(pixel); // R
        rgbaPixels.add(pixel); // G
        rgbaPixels.add(pixel); // B
        rgbaPixels.add(255); // A
      }

      return ClipRRect(
        borderRadius: const BorderRadius.vertical(
            top: Radius.circular(SkotiqTokens.radiusXs)),
        child: Image.memory(
          _createBmpFromRgba(rgbaPixels, crop.width, crop.height),
          width: 80,
          height: 80,
          fit: BoxFit.contain,
          gaplessPlayback: true,
        ),
      );
    } catch (e) {
      return Center(
          child: Icon(SkotiqIcons.error, size: 24, color: colors.textMuted));
    }
  }

  /// Create a simple BMP image from RGBA pixel data
  static Uint8List _createBmpFromRgba(
      List<int> rgbaPixels, int width, int height) {
    // BMP header (54 bytes) + pixel data
    final rowSize =
        ((width * 3 + 3) ~/ 4) * 4; // Row size must be multiple of 4
    final imageSize = rowSize * height;
    final fileSize = 54 + imageSize;

    final bmp = Uint8List(fileSize);
    final data = ByteData.view(bmp.buffer);

    // BMP file header (14 bytes)
    bmp[0] = 0x42; // 'B'
    bmp[1] = 0x4D; // 'M'
    data.setUint32(2, fileSize, Endian.little);
    data.setUint32(10, 54, Endian.little); // Pixel data offset

    // DIB header (40 bytes)
    data.setUint32(14, 40, Endian.little); // Header size
    data.setInt32(18, width, Endian.little);
    data.setInt32(22, -height, Endian.little); // Negative for top-down
    data.setUint16(26, 1, Endian.little); // Planes
    data.setUint16(28, 24, Endian.little); // Bits per pixel
    data.setUint32(34, imageSize, Endian.little);

    // Pixel data (BGR format)
    int offset = 54;
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final idx = (y * width + x) * 4;
        if (idx + 2 < rgbaPixels.length) {
          bmp[offset++] = rgbaPixels[idx + 2]; // B
          bmp[offset++] = rgbaPixels[idx + 1]; // G
          bmp[offset++] = rgbaPixels[idx]; // R
        } else {
          offset += 3;
        }
      }
      // Padding
      while (offset % 4 != 54 % 4 && offset < fileSize) {
        bmp[offset++] = 0;
      }
    }

    return bmp;
  }
}

/// V-curve painter with real data points and axis labels
class _VCurvePainter extends CustomPainter {
  final SkotiqColors colors;
  final List<VCurvePoint> points;
  final FocusRange focusRange;

  _VCurvePainter({
    required this.colors,
    required this.points,
    required this.focusRange,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) {
      _drawEmptyState(canvas, size);
      return;
    }

    // Margins for axis labels
    const leftMargin = 35.0;
    const bottomMargin = 16.0;
    const topMargin = 8.0;
    const rightMargin = 8.0;

    final chartWidth = size.width - leftMargin - rightMargin;
    final chartHeight = size.height - topMargin - bottomMargin;

    // Calculate value ranges
    final minHfr = points.map((p) => p.hfr).reduce((a, b) => a < b ? a : b);
    final maxHfr = points.map((p) => p.hfr).reduce((a, b) => a > b ? a : b);
    final hfrRange = (maxHfr - minHfr).clamp(0.5, double.infinity);
    final hfrPadding = hfrRange * 0.1;

    final posRange = (focusRange.max - focusRange.min).toDouble();

    // Draw axis labels
    _drawAxisLabels(canvas, size, leftMargin, bottomMargin, topMargin,
        minHfr - hfrPadding, maxHfr + hfrPadding, focusRange);

    // Draw gridlines
    _drawGridlines(canvas, leftMargin, topMargin, chartWidth, chartHeight);

    // Draw curve and points
    final linePaint = Paint()
      ..color = colors.primary.withValues(alpha: 0.6)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    final pointPaint = Paint()
      ..color = colors.primary
      ..style = PaintingStyle.fill;

    final path = Path();
    bool first = true;

    for (final point in points) {
      final x = leftMargin +
          ((point.position - focusRange.min) / posRange) * chartWidth;
      final y = topMargin +
          chartHeight -
          ((point.hfr - (minHfr - hfrPadding)) / (hfrRange + 2 * hfrPadding)) *
              chartHeight;

      if (first) {
        path.moveTo(x, y);
        first = false;
      } else {
        path.lineTo(x, y);
      }

      canvas.drawCircle(Offset(x, y), 4, pointPaint);
    }

    canvas.drawPath(path, linePaint);

    // Mark the minimum HFR point
    final minPoint = points.reduce((a, b) => a.hfr < b.hfr ? a : b);
    final minX = leftMargin +
        ((minPoint.position - focusRange.min) / posRange) * chartWidth;
    final minY = topMargin +
        chartHeight -
        ((minPoint.hfr - (minHfr - hfrPadding)) / (hfrRange + 2 * hfrPadding)) *
            chartHeight;

    final starPaint = Paint()
      ..color = colors.success
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(minX, minY), 6, starPaint);
  }

  void _drawEmptyState(Canvas canvas, Size size) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: 'Collecting data...',
        style: TextStyle(
            color: colors.textMuted, fontSize: SkotiqTypography.fontSize11),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
        canvas,
        Offset((size.width - textPainter.width) / 2,
            (size.height - textPainter.height) / 2));
  }

  void _drawAxisLabels(
      Canvas canvas,
      Size size,
      double leftMargin,
      double bottomMargin,
      double topMargin,
      double minHfr,
      double maxHfr,
      FocusRange range) {
    final textStyle = TextStyle(
        color: colors.textMuted, fontSize: SkotiqTypography.fontSize8);

    // Y-axis label (HFR)
    final yLabel = TextPainter(
      text: TextSpan(text: 'HFR', style: textStyle),
      textDirection: TextDirection.ltr,
    );
    yLabel.layout();
    yLabel.paint(canvas, const Offset(2, 4));

    // Min/max HFR values
    final minLabel = TextPainter(
      text: TextSpan(text: minHfr.toStringAsFixed(1), style: textStyle),
      textDirection: TextDirection.ltr,
    );
    minLabel.layout();
    minLabel.paint(
        canvas, Offset(2, size.height - bottomMargin - minLabel.height));

    final maxLabel = TextPainter(
      text: TextSpan(text: maxHfr.toStringAsFixed(1), style: textStyle),
      textDirection: TextDirection.ltr,
    );
    maxLabel.layout();
    maxLabel.paint(canvas, Offset(2, topMargin));

    // X-axis labels (focus range)
    final rangeLabel = TextPainter(
      text: TextSpan(text: '${range.min} → ${range.max}', style: textStyle),
      textDirection: TextDirection.ltr,
    );
    rangeLabel.layout();
    rangeLabel.paint(
        canvas,
        Offset((size.width - rangeLabel.width) / 2,
            size.height - rangeLabel.height - 2));
  }

  void _drawGridlines(
      Canvas canvas, double left, double top, double width, double height) {
    final gridPaint = Paint()
      ..color = colors.border.withValues(alpha: 0.3)
      ..strokeWidth = 1;

    // Horizontal gridlines
    for (int i = 0; i <= 4; i++) {
      final y = top + (height * i / 4);
      canvas.drawLine(Offset(left, y), Offset(left + width, y), gridPaint);
    }

    // Vertical gridlines
    for (int i = 0; i <= 4; i++) {
      final x = left + (width * i / 4);
      canvas.drawLine(Offset(x, top), Offset(x, top + height), gridPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _VCurvePainter oldDelegate) =>
      oldDelegate.points.length != points.length ||
      oldDelegate.focusRange.min != focusRange.min ||
      oldDelegate.focusRange.max != focusRange.max;
}
