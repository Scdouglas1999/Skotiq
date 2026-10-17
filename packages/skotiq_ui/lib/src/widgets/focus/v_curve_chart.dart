import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show FocusRange, VCurvePoint;

import '../../theme/skotiq_typography.dart';

/// The ONE V-curve chart in the app.
///
/// Promoted out of `autofocus_progress_overlay.dart`, whose doc comment has
/// always said not to fork a second V-curve surface. It is now parameterised
/// over a LIST of series so the same painter draws:
///
///   * the live autofocus overlay — one series, the run's accent colour, the
///     best sampled point ringed in `success` (unchanged rendering), and
///   * the focuser backlash calibration — two series on shared axes, one per
///     approach direction, each with its own colour and its own FITTED vertex,
///     which is the whole point of the measurement: the gap between the two
///     vertices IS the backlash.
///
/// The fitted vertex is deliberately a different mark from the best sampled
/// point. A parabola's vertex almost never lands on a sample, so drawing it as
/// a ringed data point would claim a measurement at a position that was never
/// exposed.
class VCurveSeries {
  const VCurveSeries({
    required this.points,
    required this.color,
    this.label,
    this.vertexPosition,
    this.vertexColor,
    this.showVertexGuide = false,
    this.highlightLatest = false,
  });

  /// Samples in this series, in acquisition order. The line is drawn in
  /// POSITION order; `highlightLatest` reads the acquisition order.
  final List<VCurvePoint> points;

  /// The series line and point colour. Callers pass this through
  /// `SkotiqChartColors.forTheme` so red night stays on the red axis.
  final Color color;

  /// Legend/semantics name for this series, e.g. 'From below'.
  final String? label;

  /// The fitted optimum, if one has been derived. Need not coincide with a
  /// sample.
  final int? vertexPosition;

  /// Colour of the vertex mark. Defaults to [color] — the autofocus overlay
  /// passes `success` instead, because there the vertex is the RESULT rather
  /// than one of two things being compared.
  final Color? vertexColor;

  /// Mark a [vertexPosition] that falls BETWEEN samples, with a guide line and
  /// a diamond on the curve.
  ///
  /// Off for the overlay, where a vertical rule through a 200px-tall chart is
  /// noise for a single curve and an off-sample best position has always simply
  /// gone unmarked. On for the calibration, where the horizontal distance
  /// between the two guides is the number being reported. A vertex that lands
  /// exactly on a sample is ringed either way.
  final bool showVertexGuide;

  /// Ring the most recently acquired point — the "we are here now" mark for a
  /// scan in flight.
  final bool highlightLatest;
}

/// How much room the chart has, which decides the tick glyph size.
enum VCurveChartDensity {
  /// The floating autofocus overlay: a 320px-tall card whose y-gutter is 36px.
  compact,

  /// A dialog or panel chart with room for the type scale.
  expanded,
}

/// Paints one or more V-curves on shared axes.
///
/// Shared axes are not a convenience here: two curves measured on different
/// scales would make the vertex gap meaningless.
class VCurvePainter extends CustomPainter {
  VCurvePainter({
    required this.series,
    required this.gridColor,
    required this.textColor,
    this.focusRange,
    this.density = VCurveChartDensity.compact,
    this.repaintTick = 0,
  });

  final List<VCurveSeries> series;

  /// The commanded scan range. When given it fixes the x-axis so the curve
  /// does not rescale under itself as points arrive.
  final FocusRange? focusRange;

  final Color gridColor;
  final Color textColor;
  final VCurveChartDensity density;

  /// An opaque value the caller bumps when something outside [series] changed
  /// that should force a repaint (the overlay passes its current point index).
  final int repaintTick;

  /// Axis-title and tick glyph sizes.
  ///
  /// These are chart FURNITURE, not typography roles. The compact sizes are
  /// below the Observatory scale's 10px floor on purpose: they have to fit the
  /// overlay's 36px y-gutter, and the scale has nothing that does. The expanded
  /// density, which has the room, uses the scale.
  static const double _compactAxisTitleSize = 8;
  static const double _compactTickSize = 7;

  /// Chart insets. Left is wide enough for a two-digit-plus-decimal HFR tick.
  static const EdgeInsets _padding = EdgeInsets.fromLTRB(36, 8, 8, 20);

  /// Radii of the three point states, in logical pixels.
  static const double _pointRadius = 3;
  static const double _latestRadius = 4;
  static const double _latestRingRadius = 7;
  static const double _vertexRadius = 5;
  static const double _vertexRingRadius = 8;

  TextStyle _axisTitleStyle() => switch (density) {
    VCurveChartDensity.compact => TextStyle(
      color: textColor,
      fontSize: _compactAxisTitleSize,
    ),
    VCurveChartDensity.expanded => SkotiqTypography.captionSm.copyWith(
      color: textColor,
    ),
  };

  TextStyle _tickStyle() => switch (density) {
    VCurveChartDensity.compact => TextStyle(
      color: textColor,
      fontSize: _compactTickSize,
    ),
    VCurveChartDensity.expanded => SkotiqTypography.monoXs.copyWith(
      color: textColor,
    ),
  };

  Iterable<VCurvePoint> get _allPoints => series.expand((s) => s.points);

  @override
  void paint(Canvas canvas, Size size) {
    final all = _allPoints.toList();
    if (all.isEmpty) return;

    final chartArea = Rect.fromLTWH(
      _padding.left,
      _padding.top,
      size.width - _padding.horizontal,
      size.height - _padding.vertical,
    );
    if (chartArea.width <= 0 || chartArea.height <= 0) return;

    // The x-axis spans the commanded range when there is one, and otherwise
    // the samples. Fitted vertices are folded in as well: a vertex that fell
    // outside the scan is exactly the case `vertex_outside_scan` refuses on,
    // and clipping it off the chart would hide the evidence.
    final positions = <int>[
      ...all.map((p) => p.position),
      for (final s in series)
        if (s.vertexPosition != null) s.vertexPosition!,
      if (focusRange != null) ...[focusRange!.min, focusRange!.max],
    ];
    final hfrs = all.map((p) => p.hfr).toList();

    final minPos = positions.reduce(math.min);
    final maxPos = positions.reduce(math.max);
    final minHfr = hfrs.reduce(math.min);
    final maxHfr = hfrs.reduce(math.max);

    final posRange = (maxPos - minPos).toDouble();
    final hfrPadding = (maxHfr - minHfr) * 0.15;
    final displayMinHfr = math.max(0.0, minHfr - hfrPadding);
    final displayMaxHfr = maxHfr + hfrPadding;
    final hfrRange = displayMaxHfr - displayMinHfr;

    if (posRange == 0 || hfrRange == 0) return;

    double toX(num position) =>
        chartArea.left + (position - minPos) / posRange * chartArea.width;
    double toY(double hfr) =>
        chartArea.bottom - (hfr - displayMinHfr) / hfrRange * chartArea.height;

    _paintGrid(canvas, chartArea);
    for (final s in series) {
      _paintSeries(canvas, chartArea, s, toX, toY);
    }
    _paintAxes(canvas, size, chartArea, displayMinHfr, displayMaxHfr);
  }

  void _paintGrid(Canvas canvas, Rect chartArea) {
    final gridPaint = Paint()
      ..color = gridColor.withValues(alpha: 0.2)
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = chartArea.top + (chartArea.height * i / 3);
      canvas.drawLine(
        Offset(chartArea.left, y),
        Offset(chartArea.right, y),
        gridPaint,
      );
    }
  }

  void _paintSeries(
    Canvas canvas,
    Rect chartArea,
    VCurveSeries s,
    double Function(num) toX,
    double Function(double) toY,
  ) {
    if (s.points.isEmpty) return;

    // Sorted by position so the polyline forms a clean V regardless of the
    // order the points were acquired in — which, for the from-above scan, is
    // descending.
    final sorted = List.of(s.points)
      ..sort((a, b) => a.position.compareTo(b.position));

    if (sorted.length > 1) {
      final linePaint = Paint()
        ..color = s.color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path();
      var started = false;
      for (final p in sorted) {
        final x = toX(p.position);
        final y = toY(p.hfr);
        if (!x.isFinite || !y.isFinite) continue;
        if (!started) {
          path.moveTo(x, y);
          started = true;
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, linePaint);
    }

    final pointPaint = Paint()
      ..color = s.color
      ..style = PaintingStyle.fill;
    final vertexColor = s.vertexColor ?? s.color;

    for (var i = 0; i < s.points.length; i++) {
      final p = s.points[i];
      final x = toX(p.position);
      final y = toY(p.hfr);
      if (!x.isFinite || !y.isFinite) continue;

      final isVertexSample =
          s.vertexPosition != null && p.position == s.vertexPosition;
      final isLatest = s.highlightLatest && i == s.points.length - 1;

      if (isVertexSample) {
        canvas.drawCircle(
          Offset(x, y),
          _vertexRadius,
          Paint()
            ..color = vertexColor
            ..style = PaintingStyle.fill,
        );
        canvas.drawCircle(
          Offset(x, y),
          _vertexRingRadius,
          Paint()
            ..color = vertexColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      } else if (isLatest) {
        canvas.drawCircle(Offset(x, y), _latestRadius, pointPaint);
        canvas.drawCircle(
          Offset(x, y),
          _latestRingRadius,
          Paint()
            ..color = s.color.withValues(alpha: 0.4)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      } else {
        canvas.drawCircle(Offset(x, y), _pointRadius, pointPaint);
      }
    }

    _paintVertexGuide(canvas, chartArea, s, vertexColor, sorted, toX, toY);
  }

  /// The fitted vertex, drawn as a guide line plus a hollow diamond on the
  /// curve. Skipped when the vertex coincides with a sample, which
  /// [_paintSeries] has already ringed.
  void _paintVertexGuide(
    Canvas canvas,
    Rect chartArea,
    VCurveSeries s,
    Color vertexColor,
    List<VCurvePoint> sorted,
    double Function(num) toX,
    double Function(double) toY,
  ) {
    final vertex = s.vertexPosition;
    if (vertex == null || !s.showVertexGuide) return;
    if (sorted.any((p) => p.position == vertex)) return;

    final x = toX(vertex);
    if (!x.isFinite) return;

    canvas.drawLine(
      Offset(x, chartArea.top),
      Offset(x, chartArea.bottom),
      Paint()
        ..color = vertexColor.withValues(alpha: 0.45)
        ..strokeWidth = 1,
    );

    final y = toY(_interpolatedHfr(sorted, vertex));
    if (!y.isFinite) return;
    final markPaint = Paint()
      ..color = vertexColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final diamond = Path()
      ..moveTo(x, y - _vertexRadius)
      ..lineTo(x + _vertexRadius, y)
      ..lineTo(x, y + _vertexRadius)
      ..lineTo(x - _vertexRadius, y)
      ..close();
    canvas.drawPath(diamond, markPaint);
  }

  /// HFR of the sampled polyline at [position], so the vertex mark sits ON the
  /// curve the operator can see rather than at a fitted minimum they cannot.
  double _interpolatedHfr(List<VCurvePoint> sorted, int position) {
    if (position <= sorted.first.position) return sorted.first.hfr;
    if (position >= sorted.last.position) return sorted.last.hfr;
    for (var i = 1; i < sorted.length; i++) {
      final a = sorted[i - 1];
      final b = sorted[i];
      if (position > b.position) continue;
      final span = (b.position - a.position).toDouble();
      if (span == 0) return a.hfr;
      final t = (position - a.position) / span;
      return a.hfr + (b.hfr - a.hfr) * t;
    }
    return sorted.last.hfr;
  }

  void _paintAxes(
    Canvas canvas,
    Size size,
    Rect chartArea,
    double displayMinHfr,
    double displayMaxHfr,
  ) {
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    final axisTitle = _axisTitleStyle();
    final tick = _tickStyle();

    void draw(String text, TextStyle style, Offset Function(Size) place) {
      textPainter.text = TextSpan(text: text, style: style);
      textPainter.layout();
      textPainter.paint(canvas, place(textPainter.size));
    }

    draw('HFR', axisTitle, (_) => Offset(4, chartArea.top));
    draw(
      'Position',
      axisTitle,
      (s) => Offset(chartArea.center.dx - s.width / 2, size.height - 12),
    );
    draw(
      displayMaxHfr.toStringAsFixed(1),
      tick,
      (s) => Offset(chartArea.left - s.width - 2, chartArea.top - 4),
    );
    draw(
      displayMinHfr.toStringAsFixed(1),
      tick,
      (s) => Offset(chartArea.left - s.width - 2, chartArea.bottom - 6),
    );
  }

  @override
  bool shouldRepaint(covariant VCurvePainter old) {
    if (repaintTick != old.repaintTick) return true;
    if (density != old.density) return true;
    if (gridColor != old.gridColor || textColor != old.textColor) return true;
    if (focusRange?.min != old.focusRange?.min ||
        focusRange?.max != old.focusRange?.max) {
      return true;
    }
    if (series.length != old.series.length) return true;
    for (var i = 0; i < series.length; i++) {
      final a = series[i];
      final b = old.series[i];
      if (a.points.length != b.points.length ||
          a.vertexPosition != b.vertexPosition ||
          a.color != b.color ||
          a.vertexColor != b.vertexColor ||
          a.highlightLatest != b.highlightLatest ||
          a.showVertexGuide != b.showVertexGuide) {
        return true;
      }
    }
    return false;
  }
}

/// [VCurvePainter] in a sized box with a screen-reader description.
///
/// A canvas is invisible to assistive technology, so the chart publishes the
/// same facts as prose: how many points each series holds and where its
/// optimum landed.
class VCurveChart extends StatelessWidget {
  const VCurveChart({
    super.key,
    required this.series,
    required this.gridColor,
    required this.textColor,
    this.focusRange,
    this.density = VCurveChartDensity.expanded,
    this.repaintTick = 0,
    this.semanticsLabel,
  });

  final List<VCurveSeries> series;
  final FocusRange? focusRange;
  final Color gridColor;
  final Color textColor;
  final VCurveChartDensity density;
  final int repaintTick;

  /// Overrides the generated description. Give one when the surrounding panel
  /// already states the numbers and a second reading would be repetition.
  final String? semanticsLabel;

  String _describe() {
    final parts = <String>[];
    for (final s in series) {
      if (s.points.isEmpty) continue;
      final name = s.label ?? 'Focus curve';
      final vertex = s.vertexPosition;
      parts.add(
        vertex == null
            ? '$name: ${s.points.length} points'
            : '$name: ${s.points.length} points, optimum at $vertex',
      );
    }
    if (parts.isEmpty) return 'Focus curve chart, no points yet';
    return 'Focus curve chart. ${parts.join('. ')}.';
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticsLabel ?? _describe(),
      excludeSemantics: true,
      child: CustomPaint(
        painter: VCurvePainter(
          series: series,
          focusRange: focusRange,
          gridColor: gridColor,
          textColor: textColor,
          density: density,
          repaintTick: repaintTick,
        ),
        size: Size.infinite,
      ),
    );
  }
}
