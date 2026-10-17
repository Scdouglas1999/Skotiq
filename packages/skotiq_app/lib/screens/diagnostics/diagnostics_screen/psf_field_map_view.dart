import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A public, reusable PSF field-quality heat-grid: each [PsfFieldTileRow] is a
/// cell coloured by its median HFR (green = sharp → red = bloated), laid out on
/// the tile (row, col) grid. The HFR value is printed in cells big enough to
/// hold it.
///
/// Shared by the diagnostics screen's PSF field-map card and the Morning Report
/// workbench, which renders the same painter at *per-sub* granularity. Both
/// render this widget over their own tile rows.
class PsfFieldMapView extends StatelessWidget {
  /// The PSF field tiles to render. May be empty.
  final List<PsfFieldTileRow> tiles;

  const PsfFieldMapView({super.key, required this.tiles});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return CustomPaint(
      painter: PsfFieldMapPainter(
        tiles: tiles,
        goodColor: colors.success,
        warnColor: colors.warning,
        badColor: colors.error,
        borderColor: colors.border,
        textColor: colors.textPrimary,
        bgColor: colors.surfaceAlt,
      ),
    );
  }
}

/// The PSF field-map heat-grid painter. Public so both the diagnostics screen
/// and the Morning Report workbench paint the same cells from the same source.
class PsfFieldMapPainter extends CustomPainter {
  final List<PsfFieldTileRow> tiles;
  final Color goodColor;
  final Color warnColor;
  final Color badColor;
  final Color borderColor;
  final Color textColor;
  final Color bgColor;

  PsfFieldMapPainter({
    required this.tiles,
    required this.goodColor,
    required this.warnColor,
    required this.badColor,
    required this.borderColor,
    required this.textColor,
    required this.bgColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (tiles.isEmpty) return;

    final maxRow =
        tiles.map((t) => t.tileRow).fold<int>(0, (a, b) => a > b ? a : b);
    final maxCol =
        tiles.map((t) => t.tileCol).fold<int>(0, (a, b) => a > b ? a : b);
    final numRows = maxRow + 1;
    final numCols = maxCol + 1;

    if (numRows == 0 || numCols == 0) return;

    final cellWidth = size.width / numCols;
    final cellHeight = size.height / numRows;

    // Compute HFR range across all tiles for normalization
    final hfrValues =
        tiles.map((t) => t.medianHfr).where((v) => v > 0).toList();
    if (hfrValues.isEmpty) return;

    final minHfr = hfrValues.reduce(math.min);
    final maxHfr = hfrValues.reduce(math.max);
    final hfrRange = (maxHfr - minHfr).clamp(0.01, double.infinity);

    // Build lookup
    final lookup = <(int, int), PsfFieldTileRow>{};
    for (final tile in tiles) {
      lookup[(tile.tileRow, tile.tileCol)] = tile;
    }

    for (int row = 0; row < numRows; row++) {
      for (int col = 0; col < numCols; col++) {
        final rect = Rect.fromLTWH(
          col * cellWidth,
          row * cellHeight,
          cellWidth,
          cellHeight,
        );

        final tile = lookup[(row, col)];
        if (tile == null || tile.medianHfr <= 0) {
          // Empty tile
          final emptyPaint = Paint()..color = bgColor;
          canvas.drawRRect(
            RRect.fromRectAndRadius(
                rect.deflate(1), const Radius.circular(SkotiqTokens.radiusXs)),
            emptyPaint,
          );
          continue;
        }

        // Normalize HFR to 0-1 (0 = best, 1 = worst)
        final normalized = (tile.medianHfr - minHfr) / hfrRange;

        // Interpolate color: green -> yellow -> red
        final color = Color.lerp(
          Color.lerp(goodColor, warnColor, (normalized * 2).clamp(0.0, 1.0)),
          badColor,
          ((normalized - 0.5) * 2).clamp(0.0, 1.0),
        )!;

        final cellPaint = Paint()..color = color.withValues(alpha: 0.7);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
              rect.deflate(1), const Radius.circular(SkotiqTokens.radiusXs)),
          cellPaint,
        );

        // Draw border
        final borderPaint = Paint()
          ..color = borderColor.withValues(alpha: 0.3)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
              rect.deflate(1), const Radius.circular(SkotiqTokens.radiusXs)),
          borderPaint,
        );

        // Draw HFR value text if cell is big enough
        if (cellWidth > 40 && cellHeight > 25) {
          final span = TextSpan(
            text: tile.medianHfr.toStringAsFixed(1),
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize10,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          );
          final painter = TextPainter(
            text: span,
            textDirection: TextDirection.ltr,
          )..layout();
          painter.paint(
            canvas,
            Offset(
              rect.center.dx - painter.width / 2,
              rect.center.dy - painter.height / 2,
            ),
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant PsfFieldMapPainter old) => tiles != old.tiles;
}
