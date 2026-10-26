import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../accessible_dropdown.dart';
import 'adaptive_chart_container.dart';

/// FWHM-surface ramp endpoints, as NAMES rather than painted colours.
///
/// The surface encodes its measurement in COLOUR, which makes these chart
/// series: painted raw they drew a blue-to-red surface and a matching key over
/// a red-night screen, undoing the dark adaptation the mode exists to protect.
/// Map them with [SkotiqChartColors.forTheme] once per painter/build, then
/// interpolate between the RESOLVED endpoints — lerping the names first and
/// resolving after would put an off-axis midpoint back on the screen.
///
/// `SkotiqChartColors` offers no diverging-ramp API today; a future one
/// should own the whole ramp so the surface and the scale bar that explains it
/// come from a single declaration instead of agreeing by convention.
@visibleForTesting
const Color namedSurfaceLowValue = Color(0xFF1D4ED8);

@visibleForTesting
const Color namedSurfaceHighValue = Color(0xFFDC2626);

/// Lowest / highest elevation the surface can be tipped to, in radians.
const double _minPitch = 0.1;
const double _maxPitch = 1.45;

/// Yaw/pitch a drag of [drag] should produce on a plot of [plot] logical pixels.
///
/// Expressed as a fraction of the plot dragged — a full-width drag is one
/// revolution of yaw, a full-height drag a half-turn of pitch — rather than a
/// fixed radians-per-pixel rate. The rate version tied the sensitivity to the
/// window: the same wrist flick spun the surface several times over on a wide
/// desktop plot and barely nudged it in a narrow one.
@visibleForTesting
({double yaw, double pitch}) surfaceOrbitDelta(Offset drag, Size plot) {
  final width = plot.width.isFinite && plot.width > 0 ? plot.width : 1.0;
  final height = plot.height.isFinite && plot.height > 0 ? plot.height : 1.0;
  return (
    yaw: 2 * math.pi * drag.dx / width,
    pitch: math.pi * drag.dy / height,
  );
}

/// Iso-values the Contours control draws, as fractions of the tile grid's
/// 5th-to-95th-percentile span. Five interior levels: the extremes carry no
/// line (nothing is above the maximum) and more than five turns a 5x5 grid
/// into hatching.
const List<double> kSurfaceContourLevels = [1 / 6, 2 / 6, 3 / 6, 4 / 6, 5 / 6];

/// One straight piece of an iso-line, in fractional grid coordinates
/// (x = column, y = row) at height [level].
typedef ContourSegment = ({
  double x0,
  double y0,
  double x1,
  double y1,
  double level,
});

/// Marching squares over [grid] (indexed `[row][col]`, `null` where a tile is
/// missing) at each of [levels].
///
/// Cells with a missing corner are skipped rather than guessed: a partly
/// populated field map should show a gap, not an invented contour.
@visibleForTesting
List<ContourSegment> isoContourSegments(
  List<List<double?>> grid,
  List<double> levels,
) {
  final segments = <ContourSegment>[];
  final rows = grid.length;
  if (rows < 2) return segments;
  final cols = grid.first.length;
  if (cols < 2) return segments;

  for (final level in levels) {
    for (var r = 0; r < rows - 1; r++) {
      for (var c = 0; c < cols - 1; c++) {
        final tl = grid[r][c];
        final tr = grid[r][c + 1];
        final br = grid[r + 1][c + 1];
        final bl = grid[r + 1][c];
        if (tl == null || tr == null || br == null || bl == null) continue;

        // Corner values as a 4-bit case index, in the classic
        // marching-squares order: bit 0 = top-left, 1 = top-right,
        // 2 = bottom-right, 3 = bottom-left.
        var caseIndex = 0;
        if (tl >= level) caseIndex |= 1;
        if (tr >= level) caseIndex |= 2;
        if (br >= level) caseIndex |= 4;
        if (bl >= level) caseIndex |= 8;
        if (caseIndex == 0 || caseIndex == 15) continue;

        // Crossing point on each edge, interpolated linearly.
        double lerp(double a, double b) =>
            (b - a).abs() < 1e-12 ? 0.5 : ((level - a) / (b - a));
        final top = (x: c + lerp(tl, tr), y: r.toDouble());
        final right = (x: (c + 1).toDouble(), y: r + lerp(tr, br));
        final bottom = (x: c + lerp(bl, br), y: (r + 1).toDouble());
        final left = (x: c.toDouble(), y: r + lerp(tl, bl));

        void emit(({double x, double y}) a, ({double x, double y}) b) {
          // A level that passes exactly through a grid node collapses two edge
          // crossings onto one point; a zero-length line draws nothing.
          if ((a.x - b.x).abs() < 1e-9 && (a.y - b.y).abs() < 1e-9) return;
          segments.add((x0: a.x, y0: a.y, x1: b.x, y1: b.y, level: level));
        }

        switch (caseIndex) {
          case 1:
          case 14:
            emit(left, top);
          case 2:
          case 13:
            emit(top, right);
          case 3:
          case 12:
            emit(left, right);
          case 4:
          case 11:
            emit(right, bottom);
          case 6:
          case 9:
            emit(top, bottom);
          case 7:
          case 8:
            emit(left, bottom);
          // Saddles: both diagonals cross, so the cell carries two lines.
          case 5:
            emit(left, top);
            emit(right, bottom);
          case 10:
            emit(top, right);
            emit(left, bottom);
        }
      }
    }
  }
  return segments;
}

/// The value scale a field map is read against.
///
/// [low] and [high] are the 5th/95th percentiles the colour ramp saturates at;
/// [min]/[median]/[max] are the real extent of the layer. Both are needed: the
/// ramp ends say what a colour MEANS, the extent says how bad the worst tile
/// actually is.
@visibleForTesting
({double low, double high, double min, double median, double max})
    surfaceValueScale(List<ScienceTileMetricRow> tiles) {
  final values = tiles
      .map((tile) => tile.value)
      .where((value) => value.isFinite)
      .toList(growable: false)
    ..sort();
  if (values.isEmpty) {
    return (low: 0.0, high: 1.0, min: 0.0, median: 0.0, max: 0.0);
  }
  final low = values[(values.length * 0.05).floor()];
  final high =
      values[(values.length * 0.95).floor().clamp(0, values.length - 1)];
  return (
    low: low,
    high: high,
    min: values.first,
    median: values[values.length ~/ 2],
    max: values.last,
  );
}

/// A tile as it lands on screen: where its marker was drawn, how deep it sits
/// in the rotated view, and the 0–1 height that coloured it.
typedef ProjectedTile = ({
  ScienceTileMetricRow tile,
  Offset at,
  double depth,
  double norm,
});

/// Projects every tile into plot coordinates.
///
/// Shared by the painter and by the tap readout, so a tap always resolves to
/// the marker the user aimed at however the surface has been orbited.
@visibleForTesting
List<ProjectedTile> projectSurfaceTiles({
  required List<ScienceTileMetricRow> tiles,
  required Size size,
  required double yaw,
  required double pitch,
  required double zExaggeration,
  required double low,
  required double high,
}) {
  if (tiles.isEmpty) return const [];
  var maxRow = 0;
  var maxCol = 0;
  for (final tile in tiles) {
    if (tile.tileRow > maxRow) maxRow = tile.tileRow;
    if (tile.tileCol > maxCol) maxCol = tile.tileCol;
  }
  final project = surfaceProjector(
    rows: maxRow + 1,
    cols: maxCol + 1,
    size: size,
    yaw: yaw,
    pitch: pitch,
    zExaggeration: zExaggeration,
  );
  final span = (high - low).abs() < 1e-6 ? 1.0 : (high - low);
  return tiles.map((tile) {
    final norm = ((tile.value - low) / span).clamp(0.0, 1.0);
    final (at, depth) =
        project(tile.tileCol.toDouble(), tile.tileRow.toDouble(), norm);
    return (tile: tile, at: at, depth: depth, norm: norm);
  }).toList(growable: false);
}

/// Grid position + normalised height, in the [-1, 1] cube, to a screen point
/// and its depth.
@visibleForTesting
(Offset, double) Function(double colF, double rowF, double norm)
    surfaceProjector({
  required int rows,
  required int cols,
  required Size size,
  required double yaw,
  required double pitch,
  required double zExaggeration,
}) {
  return (double colF, double rowF, double norm) {
    final nx = cols <= 1 ? 0.0 : (colF / (cols - 1) - 0.5) * 2.0;
    final ny = rows <= 1 ? 0.0 : (rowF / (rows - 1) - 0.5) * 2.0;
    final nz = (norm - 0.5) * zExaggeration;

    final rotYx = nx * math.cos(yaw) - nz * math.sin(yaw);
    final rotYz = nx * math.sin(yaw) + nz * math.cos(yaw);
    final rotXy = ny * math.cos(pitch) - rotYz * math.sin(pitch);
    final rotXz = ny * math.sin(pitch) + rotYz * math.cos(pitch);

    return (
      Offset(
        size.width * 0.5 + rotYx * size.width * 0.34,
        size.height * 0.56 + rotXy * size.height * 0.34,
      ),
      rotXz,
    );
  };
}

/// The plot area itself, so a test can aim a tap at a projected marker.
const Key kScienceSurfacePlotKey = Key('science-surface-plot');

class ScienceSurfaceExplorer extends StatefulWidget {
  final SkotiqColors colors;
  final List<ScienceTileMetricRow> tiles;

  const ScienceSurfaceExplorer({
    super.key,
    required this.colors,
    required this.tiles,
  });

  @override
  State<ScienceSurfaceExplorer> createState() => _ScienceSurfaceExplorerState();
}

class _ScienceSurfaceExplorerState extends State<ScienceSurfaceExplorer> {
  String _selectedLayer = ScienceLayerType.uniformity.dbValue;
  double _yaw = -0.55;
  double _pitch = 0.75;
  double _zExaggeration = 1.6;
  bool _showContour = false;
  ScienceTileMetricRow? _selectedTile;

  @override
  Widget build(BuildContext context) {
    final layerNames = widget.tiles
        .map((tile) => tile.layerType)
        .toSet()
        .toList(growable: false)
      ..sort();
    if (layerNames.isNotEmpty && !layerNames.contains(_selectedLayer)) {
      _selectedLayer = layerNames.first;
    }
    final selectedTiles = widget.tiles
        .where((tile) => tile.layerType == _selectedLayer)
        .toList(growable: false);

    return SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '3D Surface Explorer',
                style: SkotiqTypography.bodyStrong
                    .copyWith(color: widget.colors.textPrimary),
              ),
              const Spacer(),
              if (layerNames.isNotEmpty)
                AccessibleDropdown<String>(
                  value: _selectedLayer,
                  items: layerNames
                      .map(
                        (layer) => DropdownMenuItem(
                          value: layer,
                          child: Text(_labelForLayer(layer)),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }
                    // The readout names a tile of the OLD layer; keeping it
                    // would print one layer's value under another's name.
                    setState(() {
                      _selectedLayer = value;
                      _selectedTile = null;
                    });
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              if (selectedTiles.isEmpty) {
                return AdaptiveChartContainer.fixed(
                  height: 240,
                  child: Center(
                    child: Text(
                      'No tile metrics available for this frame.',
                      style: SkotiqTypography.body
                          .copyWith(color: widget.colors.textMuted),
                    ),
                  ),
                );
              }

              final scale = surfaceValueScale(selectedTiles);
              final useAspect = constraints.maxWidth >= 520;
              final plot = LayoutBuilder(
                builder: (context, plotConstraints) {
                  final plotSize = Size(
                    plotConstraints.maxWidth,
                    plotConstraints.maxHeight,
                  );
                  return GestureDetector(
                    onPanUpdate: (details) {
                      final orbit = surfaceOrbitDelta(details.delta, plotSize);
                      setState(() {
                        _yaw += orbit.yaw;
                        _pitch =
                            (_pitch - orbit.pitch).clamp(_minPitch, _maxPitch);
                      });
                    },
                    onTapUp: (details) => _selectTileAt(
                      details.localPosition,
                      selectedTiles,
                      plotSize,
                      scale,
                    ),
                    child: CustomPaint(
                      key: kScienceSurfacePlotKey,
                      painter: _SurfacePainter(
                        tiles: selectedTiles,
                        yaw: _yaw,
                        pitch: _pitch,
                        zExaggeration: _zExaggeration,
                        showContour: _showContour,
                        colors: widget.colors,
                        selectedRow: _selectedTile?.tileRow,
                        selectedCol: _selectedTile?.tileCol,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  );
                },
              );

              if (useAspect) {
                // Full width, 16:9 up to a cap. Unbounded, a wide desktop
                // column gave the plot ~450px of mostly empty space and
                // pushed the value scale and the controls out of the card
                // entirely — the 25 dots never filled it.
                return SizedBox(
                  height: math.min(constraints.maxWidth * 9 / 16, 300.0),
                  child: plot,
                );
              }

              return AdaptiveChartContainer(
                preferredHeight: 240,
                child: plot,
              );
            },
          ),
          if (selectedTiles.isNotEmpty) ...[
            const SizedBox(height: 8),
            _ValueScaleBar(
              colors: widget.colors,
              scale: surfaceValueScale(selectedTiles),
              unit: _unitForLayer(_selectedLayer),
            ),
            const SizedBox(height: 6),
            Text(
              _selectedTile == null
                  ? 'Tap a marker to read its tile and value. Drag to orbit.'
                  : 'Tile r${_selectedTile!.tileRow}·c${_selectedTile!.tileCol}'
                      ' — ${_formatValue(_selectedTile!.value)}'
                      '${_unitForLayer(_selectedLayer)}'
                      ' (${_selectedTile!.sampleCount} px sampled)',
              style: SkotiqTypography.caption.copyWith(
                  color: _selectedTile == null
                      ? widget.colors.textMuted
                      : widget.colors.textPrimary),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _SliderLabeled(
                  label: 'Z Exaggeration',
                  value: _zExaggeration,
                  min: 0.6,
                  max: 3.2,
                  onChanged: (value) => setState(() => _zExaggeration = value),
                ),
              ),
              const SizedBox(width: 10),
              FilterChip(
                selected: _showContour,
                onSelected: (value) => setState(() => _showContour = value),
                label: const Text('Contours'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Resolves a tap to the nearest marker, so the plot can say WHICH tile is
  /// the red one instead of only that a red one exists.
  void _selectTileAt(
    Offset local,
    List<ScienceTileMetricRow> tiles,
    Size plotSize,
    ({double low, double high, double min, double median, double max}) scale,
  ) {
    final projected = projectSurfaceTiles(
      tiles: tiles,
      size: plotSize,
      yaw: _yaw,
      pitch: _pitch,
      zExaggeration: _zExaggeration,
      low: scale.low,
      high: scale.high,
    );
    ProjectedTile? nearest;
    var bestDistance = double.infinity;
    for (final point in projected) {
      final distance = (point.at - local).distance;
      if (distance < bestDistance) {
        bestDistance = distance;
        nearest = point;
      }
    }
    // A tap that lands nowhere near a marker clears the readout rather than
    // silently reporting a tile the user did not aim at.
    setState(() => _selectedTile = bestDistance <= 18.0 ? nearest?.tile : null);
  }

  String _labelForLayer(String dbValue) {
    switch (dbValue) {
      case 'uniformity':
        return 'Uniformity';
      case 'clip_low':
        return 'Clip Low';
      case 'clip_high':
        return 'Clip High';
      case 'background':
        return 'Background';
      case 'snr':
        return 'Sky/read noise';
      case 'fwhm':
        return 'FWHM';
      case 'hfr':
        return 'HFR';
      case 'eccentricity':
        return 'Eccentricity';
      case 'residual_mag':
        return 'Residual';
      default:
        return dbValue;
    }
  }

  /// Unit suffix for a layer's values, empty where the quantity is a ratio.
  ///
  /// Only the units the producer provably writes are named: `clip_low`/
  /// `clip_high` are percentages of pixels, `background` is the tile's median
  /// ADU, `residual_mag` is magnitudes, `fwhm`/`hfr` are pixels. Uniformity
  /// (a coefficient of variation), SNR and eccentricity are dimensionless.
  static String _unitForLayer(String dbValue) {
    switch (dbValue) {
      case 'clip_low':
      case 'clip_high':
        return '%';
      case 'background':
        return ' ADU';
      case 'residual_mag':
        return ' mag';
      case 'fwhm':
      case 'hfr':
        return ' px';
      default:
        return '';
    }
  }
}

/// Formats a field-map value at a precision that survives both a 0.02 spread
/// and a 4000 ADU background.
String _formatValue(double value) {
  if (!value.isFinite) return kReadoutUnknown;
  final magnitude = value.abs();
  if (magnitude >= 1000) return value.toStringAsFixed(0);
  if (magnitude >= 10) return value.toStringAsFixed(1);
  if (magnitude >= 1) return value.toStringAsFixed(2);
  return value.toStringAsFixed(3);
}

/// The colour ramp with numbers on it.
///
/// Without this the card was 25 coloured dots and no scale: a 2% uniformity
/// spread and a 40% one drew exactly the same picture, so the map could not be
/// acted on. The bar's ends are the same 5th/95th percentiles the ramp
/// saturates at, and the full extent is stated beside them because the worst
/// tile is usually the point of looking.
class _ValueScaleBar extends StatelessWidget {
  final SkotiqColors colors;
  final ({
    double low,
    double high,
    double min,
    double median,
    double max
  }) scale;
  final String unit;

  const _ValueScaleBar({
    required this.colors,
    required this.scale,
    required this.unit,
  });

  @override
  Widget build(BuildContext context) {
    final caption = SkotiqTypography.caption.copyWith(color: colors.textMuted);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('${_formatValue(scale.low)}$unit', style: caption),
            const SizedBox(width: 6),
            Expanded(
              child: Container(
                height: 8,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
                  // The scale bar explains the surface, so it must be the
                  // SAME ramp: painted raw it advertised a blue-to-red key
                  // beside a red-night surface that no longer had one.
                  gradient: LinearGradient(
                    colors: [
                      SkotiqChartColors.forTheme(namedSurfaceLowValue, colors),
                      SkotiqChartColors.forTheme(namedSurfaceHighValue, colors),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text('${_formatValue(scale.high)}$unit', style: caption),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'median ${_formatValue(scale.median)}$unit  ·  '
          'range ${_formatValue(scale.min)}–${_formatValue(scale.max)}$unit  ·  '
          'colour saturates at the 5th/95th percentile',
          style: caption,
        ),
      ],
    );
  }
}

class _SliderLabeled extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  const _SliderLabeled({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: SkotiqTypography.caption),
        Slider(
          min: min,
          max: max,
          value: value,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _SurfacePainter extends CustomPainter {
  final List<ScienceTileMetricRow> tiles;
  final double yaw;
  final double pitch;
  final double zExaggeration;
  final bool showContour;
  final SkotiqColors colors;
  final int? selectedRow;
  final int? selectedCol;

  /// Surface ramp endpoints resolved for the active theme at construction:
  /// [_surfaceColor] is called once per tile and once per contour segment, so
  /// the remap cannot live inside it.
  final Color lowValueColor;
  final Color highValueColor;

  _SurfacePainter({
    required this.tiles,
    required this.yaw,
    required this.pitch,
    required this.zExaggeration,
    required this.showContour,
    required this.colors,
    this.selectedRow,
    this.selectedCol,
  })  : lowValueColor =
            SkotiqChartColors.forTheme(namedSurfaceLowValue, colors),
        highValueColor =
            SkotiqChartColors.forTheme(namedSurfaceHighValue, colors);

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
    final rows = maxRow + 1;
    final cols = maxCol + 1;

    final scale = surfaceValueScale(tiles);
    final project = surfaceProjector(
      rows: rows,
      cols: cols,
      size: size,
      yaw: yaw,
      pitch: pitch,
      zExaggeration: zExaggeration,
    );

    final points = projectSurfaceTiles(
      tiles: tiles,
      size: size,
      yaw: yaw,
      pitch: pitch,
      zExaggeration: zExaggeration,
      low: scale.low,
      high: scale.high,
    ).toList()
      ..sort((a, b) => a.depth.compareTo(b.depth));

    final grid = List<List<double?>>.generate(
      rows,
      (_) => List<double?>.filled(cols, null),
    );
    for (final point in points) {
      grid[point.tile.tileRow][point.tile.tileCol] = point.norm;
    }

    final pointPaint = Paint()..style = PaintingStyle.fill;
    for (final point in points) {
      final isSelected = point.tile.tileRow == selectedRow &&
          point.tile.tileCol == selectedCol;
      pointPaint.color = _surfaceColor(point.norm).withValues(alpha: 0.8);
      canvas.drawCircle(point.at, isSelected ? 6.5 : 4.2, pointPaint);
      if (isSelected) {
        canvas.drawCircle(
          point.at,
          9.0,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6
            ..color = colors.textPrimary,
        );
      }
    }

    // Which corner of the SENSOR each corner of the surface is. Without it the
    // plot said a corner was bad but not which corner, so it could not be
    // mapped onto a tilt adjustment — and the surface can be orbited, so a
    // fixed legend would be wrong half the time. Rows/cols are indexed from the
    // first image row and column.
    for (final corner in <(int row, int col)>[
      (0, 0),
      (0, cols - 1),
      (rows - 1, 0),
      (rows - 1, cols - 1),
    ]) {
      final norm = grid[corner.$1][corner.$2];
      if (norm == null) continue;
      final (at, _) = project(
        corner.$2.toDouble(),
        corner.$1.toDouble(),
        norm,
      );
      final label = TextPainter(
        text: TextSpan(
          text: 'r${corner.$1}·c${corner.$2}',
          style: SkotiqTypography.caption.copyWith(
              color: colors.textSecondary, fontWeight: FontWeight.w600),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(
        canvas,
        Offset(
          (at.dx - label.width / 2).clamp(0.0, size.width - label.width),
          (at.dy - label.height - 8).clamp(0.0, size.height - label.height),
        ),
      );
    }

    if (!showContour) return;

    // Real iso-value lines across the interpolated surface. A vertical stem
    // from every marker down to a flat baseline is a lollipop plot: it breaks
    // the 3D projection it hangs inside and draws no contour anywhere.
    final contourPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round;
    for (final segment in isoContourSegments(grid, kSurfaceContourLevels)) {
      contourPaint.color = _surfaceColor(segment.level).withValues(alpha: 0.85);
      final (a, _) = project(segment.x0, segment.y0, segment.level);
      final (b, _) = project(segment.x1, segment.y1, segment.level);
      canvas.drawLine(a, b, contourPaint);
    }
  }

  Color _surfaceColor(double norm) =>
      Color.lerp(lowValueColor, highValueColor, norm)!;

  @override
  bool shouldRepaint(covariant _SurfacePainter oldDelegate) {
    return tiles != oldDelegate.tiles ||
        yaw != oldDelegate.yaw ||
        pitch != oldDelegate.pitch ||
        zExaggeration != oldDelegate.zExaggeration ||
        showContour != oldDelegate.showContour ||
        selectedRow != oldDelegate.selectedRow ||
        selectedCol != oldDelegate.selectedCol ||
        lowValueColor != oldDelegate.lowValueColor;
  }
}
