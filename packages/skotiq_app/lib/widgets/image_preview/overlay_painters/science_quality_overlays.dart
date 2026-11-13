part of '../overlay_painters.dart';

// The science overlays encode a measurement in COLOUR, so their ramp endpoints
// are chart series in every sense that matters: painted raw they put a green
// heatmap, a navy uniformity map and a yellow residual field over the preview
// on a red-night screen, undoing the dark adaptation the mode exists to
// protect. Each endpoint below stays a NAME and is mapped through
// `SkotiqChartColors.forTheme` once, at painter construction — never inside
// `paint`, which runs per tile per frame.
//
// `SkotiqChartColors` has no diverging-ramp API today, only the three-stop
// legend lists (`psfGradient`, `uniformityGradient`, `clipHighGradient`,
// `clipLowGradient`) that `ScienceOverlayLegend` renders as swatches. A future
// ramp API should own the whole ramp — resolve every stop for the theme and
// sample it by t — so the painted surface and the legend that explains it come
// from one declaration; today they are separate hues that agree only by
// convention. Interpolating between ALREADY-RESOLVED endpoints (as below) is
// what keeps red night red: lerping the named hues first and resolving after
// would put a green-dominant midpoint on the screen.

/// PSF heatmap ramp: tight stars.
@visibleForTesting
const Color namedPsfTight = SciencePlotColors.psfTight;

/// PSF heatmap ramp: bloated or elongated stars.
@visibleForTesting
const Color namedPsfBloated = SciencePlotColors.psfBloated;

/// PSF heatmap: a tile with no measurable stars.
@visibleForTesting
const Color namedPsfNoStars = SciencePlotColors.noMeasurement;

class SciencePsfOverlayPainter extends CustomPainter {
  final List<PsfFieldTileRow> tiles;
  final Offset imageOffset;
  final double zoomLevel;
  final double imageWidth;
  final double imageHeight;

  /// Ramp endpoints resolved for the active theme at construction.
  final Color tightColor;
  final Color bloatedColor;
  final Color noStarsColor;

  SciencePsfOverlayPainter({
    required this.tiles,
    required this.imageOffset,
    required this.zoomLevel,
    required this.imageWidth,
    required this.imageHeight,
    required SkotiqColors colors,
  })  : tightColor = SkotiqChartColors.forTheme(namedPsfTight, colors),
        bloatedColor = SkotiqChartColors.forTheme(namedPsfBloated, colors),
        noStarsColor = SkotiqChartColors.forTheme(namedPsfNoStars, colors);

  @override
  void paint(Canvas canvas, Size size) {
    if (tiles.isEmpty) {
      return;
    }

    var maxRow = 0;
    var maxCol = 0;
    var maxFwhm = 0.0;
    for (final tile in tiles) {
      if (tile.tileRow > maxRow) {
        maxRow = tile.tileRow;
      }
      if (tile.tileCol > maxCol) {
        maxCol = tile.tileCol;
      }
      if (tile.starCount > 0 && tile.medianFwhm > maxFwhm) {
        maxFwhm = tile.medianFwhm;
      }
    }

    final validFwhm = tiles
        .where((tile) => tile.starCount > 0 && tile.medianFwhm > 0)
        .map((tile) => tile.medianFwhm)
        .toList(growable: false)
      ..sort();
    final low = validFwhm.isEmpty ? 0.0 : _percentile(validFwhm, 0.05);
    final high = validFwhm.isEmpty
        ? maxFwhm
        : _percentile(validFwhm, 0.95).clamp(low + 1e-6, double.infinity);

    final rows = maxRow + 1;
    final cols = maxCol + 1;
    final tileW = imageWidth / cols;
    final tileH = imageHeight / rows;
    final borderPaint = Paint()
      // absolute: tile grid line over the image canvas
      ..color = ImageOverlayColors.foreground.withValues(alpha: 0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6;

    for (final tile in tiles) {
      final norm = tile.starCount <= 0 || high <= low
          ? 0.0
          : ((tile.medianFwhm - low) / (high - low)).clamp(0.0, 1.0);
      final fill = Paint()
        ..color = (tile.starCount <= 0
                ? noStarsColor
                : Color.lerp(tightColor, bloatedColor, norm)!)
            .withValues(alpha: tile.starCount > 0 ? 0.28 : 0.12)
        ..style = PaintingStyle.fill;

      final left = (tile.tileCol * tileW) * zoomLevel + imageOffset.dx;
      final top = (tile.tileRow * tileH) * zoomLevel + imageOffset.dy;
      final rect = Rect.fromLTWH(
        left,
        top,
        tileW * zoomLevel,
        tileH * zoomLevel,
      );

      canvas.drawRect(rect, fill);
      canvas.drawRect(rect, borderPaint);
    }
  }

  @override
  bool shouldRepaint(covariant SciencePsfOverlayPainter oldDelegate) {
    return tiles != oldDelegate.tiles ||
        imageOffset != oldDelegate.imageOffset ||
        zoomLevel != oldDelegate.zoomLevel ||
        imageWidth != oldDelegate.imageWidth ||
        imageHeight != oldDelegate.imageHeight ||
        // A theme flip changes nothing else about the painter, so without this
        // the heatmap keeps its old-theme ramp until the tiles change.
        tightColor != oldDelegate.tightColor;
  }

  double _percentile(List<double> sortedValues, double p) {
    if (sortedValues.isEmpty) {
      return 0.0;
    }
    final q = p.clamp(0.0, 1.0);
    final pos = (sortedValues.length - 1) * q;
    final lo = pos.floor();
    final hi = pos.ceil();
    if (lo == hi) {
      return sortedValues[lo];
    }
    final t = pos - lo;
    return sortedValues[lo] * (1.0 - t) + sortedValues[hi] * t;
  }
}

/// Residual vector field: the shaft.
@visibleForTesting
const Color namedResidualShaft = SciencePlotColors.residualShaft;

/// Residual vector field: the arrowhead, a shade darker than the shaft.
@visibleForTesting
const Color namedResidualHead = SciencePlotColors.residualHead;

class ScienceResidualOverlayPainter extends CustomPainter {
  final List<AstrometryResidualVectorRow> vectors;
  final Offset imageOffset;
  final double zoomLevel;

  /// Vector hues resolved for the active theme at construction: `paint` draws
  /// up to 350 vectors, so the remap cannot live in the loop.
  final Color shaftColor;
  final Color headColor;

  ScienceResidualOverlayPainter({
    required this.vectors,
    required this.imageOffset,
    required this.zoomLevel,
    required SkotiqColors colors,
  })  : shaftColor = SkotiqChartColors.forTheme(namedResidualShaft, colors),
        headColor = SkotiqChartColors.forTheme(namedResidualHead, colors);

  @override
  void paint(Canvas canvas, Size size) {
    if (vectors.isEmpty) {
      return;
    }

    final linePaint = Paint()
      ..color = shaftColor.withValues(alpha: 0.75)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final headPaint = Paint()
      ..color = headColor.withValues(alpha: 0.85)
      ..style = PaintingStyle.fill;

    final magnitudes = vectors
        .map((vector) => vector.magnitudeArcsec)
        .where((value) => value.isFinite && value > 0)
        .toList(growable: false)
      ..sort();
    final p95Magnitude = magnitudes.isEmpty
        ? 1.0
        : magnitudes[((magnitudes.length - 1) * 0.95).floor()];
    final scaleArcsecToPixels = p95Magnitude <= 0
        ? 6.0
        : (22.0 / p95Magnitude).clamp(2.0, 40.0).toDouble();

    final maxVectors = math.min(350, vectors.length);
    for (var i = 0; i < maxVectors; i++) {
      final vector = vectors[i];
      final x1 = vector.x * zoomLevel + imageOffset.dx;
      final y1 = vector.y * zoomLevel + imageOffset.dy;
      final dx = vector.dxArcsec * zoomLevel * scaleArcsecToPixels;
      final dy = vector.dyArcsec * zoomLevel * scaleArcsecToPixels;
      final x2 = x1 + dx;
      final y2 = y1 + dy;

      if (x1 < -100 ||
          x1 > size.width + 100 ||
          y1 < -100 ||
          y1 > size.height + 100) {
        continue;
      }

      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), linePaint);
      canvas.drawCircle(Offset(x2, y2), 1.6, headPaint);
    }
  }

  @override
  bool shouldRepaint(covariant ScienceResidualOverlayPainter oldDelegate) {
    return vectors != oldDelegate.vectors ||
        imageOffset != oldDelegate.imageOffset ||
        zoomLevel != oldDelegate.zoomLevel ||
        shaftColor != oldDelegate.shaftColor;
  }
}

/// Uniformity ramp: a flat background.
@visibleForTesting
const Color namedUniformityFlat = SciencePlotColors.uniformityFlat;

/// Uniformity ramp: a strong gradient (vignetting, moonglow).
@visibleForTesting
const Color namedUniformityStrong = SciencePlotColors.uniformityStrong;

class ScienceUniformityOverlayPainter extends CustomPainter {
  final List<ScienceTileMetricRow> tiles;
  final Offset imageOffset;
  final double zoomLevel;
  final double imageWidth;
  final double imageHeight;
  final double opacity;

  /// Ramp endpoints resolved for the active theme at construction.
  final Color flatColor;
  final Color strongColor;

  ScienceUniformityOverlayPainter({
    required this.tiles,
    required this.imageOffset,
    required this.zoomLevel,
    required this.imageWidth,
    required this.imageHeight,
    required this.opacity,
    required SkotiqColors colors,
  })  : flatColor = SkotiqChartColors.forTheme(namedUniformityFlat, colors),
        strongColor = SkotiqChartColors.forTheme(namedUniformityStrong, colors);

  @override
  void paint(Canvas canvas, Size size) {
    if (tiles.isEmpty) {
      return;
    }

    var maxRow = 0;
    var maxCol = 0;
    for (final tile in tiles) {
      if (tile.tileRow > maxRow) {
        maxRow = tile.tileRow;
      }
      if (tile.tileCol > maxCol) {
        maxCol = tile.tileCol;
      }
    }

    final values = tiles
        .map((tile) => tile.value)
        .where((value) => value.isFinite && value >= 0.0)
        .toList(growable: false)
      ..sort();
    final low = values.isEmpty ? 0.0 : _percentile(values, 0.05);
    final high = values.isEmpty
        ? 1.0
        : _percentile(values, 0.95).clamp(low + 1e-6, double.infinity);

    final rows = maxRow + 1;
    final cols = maxCol + 1;
    final tileW = imageWidth / cols;
    final tileH = imageHeight / rows;
    final borderPaint = Paint()
      // absolute: tile grid line over the image canvas
      ..color = ImageOverlayColors.foreground.withValues(alpha: 0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6;

    for (final tile in tiles) {
      final norm = high <= low
          ? 0.0
          : ((tile.value - low) / (high - low)).clamp(0.0, 1.0);
      final fill = Paint()
        ..color =
            Color.lerp(flatColor, strongColor, norm)!.withValues(alpha: opacity)
        ..style = PaintingStyle.fill;

      final left = (tile.tileCol * tileW) * zoomLevel + imageOffset.dx;
      final top = (tile.tileRow * tileH) * zoomLevel + imageOffset.dy;
      final rect = Rect.fromLTWH(
        left,
        top,
        tileW * zoomLevel,
        tileH * zoomLevel,
      );
      canvas.drawRect(rect, fill);
      canvas.drawRect(rect, borderPaint);
    }
  }

  @override
  bool shouldRepaint(covariant ScienceUniformityOverlayPainter oldDelegate) {
    return tiles != oldDelegate.tiles ||
        imageOffset != oldDelegate.imageOffset ||
        zoomLevel != oldDelegate.zoomLevel ||
        imageWidth != oldDelegate.imageWidth ||
        imageHeight != oldDelegate.imageHeight ||
        opacity != oldDelegate.opacity ||
        flatColor != oldDelegate.flatColor;
  }

  double _percentile(List<double> sortedValues, double p) {
    if (sortedValues.isEmpty) {
      return 0.0;
    }
    final q = p.clamp(0.0, 1.0);
    final pos = (sortedValues.length - 1) * q;
    final lo = pos.floor();
    final hi = pos.ceil();
    if (lo == hi) {
      return sortedValues[lo];
    }
    final t = pos - lo;
    return sortedValues[lo] * (1.0 - t) + sortedValues[hi] * t;
  }
}

/// Clip map: pixels hitting the noise floor.
@visibleForTesting
const Color namedClipLow = SciencePlotColors.clipLow;

/// Clip map: pixels saturating.
@visibleForTesting
const Color namedClipHigh = SciencePlotColors.clipHigh;

class ScienceClipOverlayPainter extends CustomPainter {
  final List<ScienceTileMetricRow> highTiles;
  final List<ScienceTileMetricRow> lowTiles;
  final Offset imageOffset;
  final double zoomLevel;
  final double imageWidth;
  final double imageHeight;
  final double opacity;

  /// Ramp endpoints resolved for the active theme at construction: `paint`
  /// lerps them once per grid cell.
  final Color lowClipColor;
  final Color highClipColor;

  ScienceClipOverlayPainter({
    required this.highTiles,
    required this.lowTiles,
    required this.imageOffset,
    required this.zoomLevel,
    required this.imageWidth,
    required this.imageHeight,
    required this.opacity,
    required SkotiqColors colors,
  })  : lowClipColor = SkotiqChartColors.forTheme(namedClipLow, colors),
        highClipColor = SkotiqChartColors.forTheme(namedClipHigh, colors);

  @override
  void paint(Canvas canvas, Size size) {
    if (highTiles.isEmpty && lowTiles.isEmpty) {
      return;
    }
    var maxRow = 0;
    var maxCol = 0;
    for (final tile in highTiles) {
      if (tile.tileRow > maxRow) {
        maxRow = tile.tileRow;
      }
      if (tile.tileCol > maxCol) {
        maxCol = tile.tileCol;
      }
    }
    for (final tile in lowTiles) {
      if (tile.tileRow > maxRow) {
        maxRow = tile.tileRow;
      }
      if (tile.tileCol > maxCol) {
        maxCol = tile.tileCol;
      }
    }
    final rows = maxRow + 1;
    final cols = maxCol + 1;
    final tileW = imageWidth / cols;
    final tileH = imageHeight / rows;
    final borderPaint = Paint()
      // absolute: tile grid line over the image canvas
      ..color = ImageOverlayColors.foreground.withValues(alpha: 0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6;

    final highMap = <(int, int), double>{};
    final lowMap = <(int, int), double>{};
    for (final tile in highTiles) {
      highMap[(tile.tileRow, tile.tileCol)] = tile.value;
    }
    for (final tile in lowTiles) {
      lowMap[(tile.tileRow, tile.tileCol)] = tile.value;
    }

    for (var row = 0; row < rows; row++) {
      for (var col = 0; col < cols; col++) {
        final high = (highMap[(row, col)] ?? 0.0).clamp(0.0, 100.0);
        final low = (lowMap[(row, col)] ?? 0.0).clamp(0.0, 100.0);
        if (high <= 0 && low <= 0) {
          continue;
        }
        final alpha = (math.max(high, low) / 100.0).clamp(0.08, 1.0) * opacity;
        final fillColor = Color.lerp(
          lowClipColor,
          highClipColor,
          high / math.max(1.0, high + low),
        )!
            .withValues(alpha: alpha);
        final fill = Paint()
          ..color = fillColor
          ..style = PaintingStyle.fill;

        final left = (col * tileW) * zoomLevel + imageOffset.dx;
        final top = (row * tileH) * zoomLevel + imageOffset.dy;
        final rect = Rect.fromLTWH(
          left,
          top,
          tileW * zoomLevel,
          tileH * zoomLevel,
        );
        canvas.drawRect(rect, fill);
        canvas.drawRect(rect, borderPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant ScienceClipOverlayPainter oldDelegate) {
    return highTiles != oldDelegate.highTiles ||
        lowTiles != oldDelegate.lowTiles ||
        imageOffset != oldDelegate.imageOffset ||
        zoomLevel != oldDelegate.zoomLevel ||
        imageWidth != oldDelegate.imageWidth ||
        imageHeight != oldDelegate.imageHeight ||
        opacity != oldDelegate.opacity ||
        lowClipColor != oldDelegate.lowClipColor;
  }
}
