import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'depthlock_presentation.dart';

/// How a goal's depth has grown, and where the noise model says it goes next.
///
/// One measure on one axis: signal-to-noise against integration time. The two
/// series are the SAME measure at two confidence levels — the conservative
/// score that must clear the threshold, and the raw score it is derived from —
/// so they are drawn in one hue at two weights rather than two hues. That is
/// also what makes them safe for a colour-blind reader without a second
/// palette: they are told apart by line weight and by the legend, never by hue
/// alone. Projection is carried by dash, again not by colour.
///
/// The threshold and the floor ceiling are annotations, not series: recessive,
/// labelled where they end, and drawn in the ink tokens rather than in the
/// series colour.
class DepthLockCurveChart extends ConsumerStatefulWidget {
  const DepthLockCurveChart({super.key, required this.goal});

  final DepthLockGoal goal;

  /// The plot's height in the side panel. The panel is a column of readouts;
  /// a chart that took more than this would push the numbers off screen.
  static const double plotHeight = 168;

  @override
  ConsumerState<DepthLockCurveChart> createState() =>
      _DepthLockCurveChartState();
}

class _DepthLockCurveChartState extends ConsumerState<DepthLockCurveChart> {
  bool _showTable = false;

  /// Index of the point the crosshair is on, or null when the pointer is away.
  int? _hoverIndex;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final goal = widget.goal;
    final double exposureSecs = goal.definition.acquisition.exposureSecs;

    // Before the estimator will say anything there is no history to draw, and
    // a curve through fewer than the minimum would be a picture of a number
    // that does not exist yet.
    if (goal.evidenceFrames < kDepthLockMinimumEvidenceFrames) {
      return _ChartFrame(
        title: 'Progress',
        child: Text(
          'The curve starts once the goal has its first '
          '$kDepthLockMinimumEvidenceFrames exposures.',
          style: SkotiqTypography.caption.copyWith(
            color: colors.textMuted,
          ),
        ),
      );
    }

    final curveAsync = ref.watch(depthLockGoalCurveProvider(goal.id));

    return curveAsync.when(
      loading: () => const _ChartFrame(
        title: 'Progress',
        child: ShimmerLoading(
          child: SizedBox(
            width: double.infinity,
            height: DepthLockCurveChart.plotHeight,
          ),
        ),
      ),
      error: (error, _) => _ChartFrame(
        title: 'Progress',
        child: Text(
          depthLockErrorMessage(error),
          style: SkotiqTypography.caption.copyWith(color: colors.warning),
        ),
      ),
      data: (points) {
        if (points.length < 2) {
          return _ChartFrame(
            title: 'Progress',
            child: Text(
              'No history to draw yet.',
              style: SkotiqTypography.caption.copyWith(
                color: colors.textMuted,
              ),
            ),
          );
        }

        final forecast = goal.report?.forecast;
        final double? ceiling = forecast != null && !forecast.reachable
            ? forecast.ceilingScore
            : null;

        return _ChartFrame(
          title: 'Progress',
          action: SkotiqButton(
            label: _showTable ? 'Chart' : 'Table',
            size: ButtonSize.small,
            variant: ButtonVariant.ghost,
            semanticsHint: _showTable
                ? 'Show the progress curve'
                : 'Show the same points as a table',
            onPressed: () => setState(() => _showTable = !_showTable),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _CurveLegend(hasCeiling: ceiling != null),
              const SizedBox(height: SkotiqTokens.spaceSm),
              if (_showTable)
                _CurveTable(points: points, exposureSecs: exposureSecs)
              else ...<Widget>[
                MouseRegion(
                  onHover: (PointerHoverEvent event) => _select(
                    event.localPosition,
                    points,
                    exposureSecs,
                    ceiling,
                  ),
                  onExit: (_) => setState(() => _hoverIndex = null),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (TapDownDetails details) => _select(
                      details.localPosition,
                      points,
                      exposureSecs,
                      ceiling,
                    ),
                    onPanUpdate: (DragUpdateDetails details) => _select(
                      details.localPosition,
                      points,
                      exposureSecs,
                      ceiling,
                    ),
                    child: SizedBox(
                      height: DepthLockCurveChart.plotHeight,
                      child: CustomPaint(
                        painter: DepthLockCurvePainter(
                          points: points,
                          exposureSecs: exposureSecs,
                          threshold: goal.definition.measurement.threshold,
                          ceiling: ceiling,
                          hoverIndex: _hoverIndex,
                          colors: colors,
                        ),
                        size: Size.infinite,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: SkotiqTokens.spaceXs),
                Text(
                  'Solid: measured. Dashed: projected at the recent sky.',
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textMuted,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// Snap the crosshair to the point nearest the pointer in x.
  ///
  /// Nearest-in-x rather than nearest-in-distance: the question a reader has
  /// over a time series is "what was it HERE", and an x-only match answers it
  /// wherever in the plot's height the pointer happens to be — which is also
  /// what makes the target the full column rather than the line itself.
  void _select(
    Offset local,
    List<DepthLockCurvePoint> points,
    double exposure,
    double? ceiling,
  ) {
    final Size size =
        (context.findRenderObject() as RenderBox?)?.size ?? Size.zero;
    if (size.width <= 0) return;
    final geometry = DepthLockCurvePainter.geometryFor(
      size: Size(size.width, DepthLockCurveChart.plotHeight),
      points: points,
      exposureSecs: exposure,
      gutterRight: DepthLockCurvePainter.gutterRightFor(
        threshold: widget.goal.definition.measurement.threshold,
        ceiling: ceiling,
      ),
    );
    final int index = geometry.nearestIndex(local.dx);
    if (index == _hoverIndex) return;
    setState(() => _hoverIndex = index);
  }
}

/// A titled block with an optional trailing control, matching the panel's
/// other sections.
class _ChartFrame extends StatelessWidget {
  const _ChartFrame({required this.title, required this.child, this.action});

  final String title;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SectionTitle(
          icon: SkotiqIcons.chart,
          title: title,
          trailing: action,
        ),
        child,
      ],
    );
  }
}

/// Identity for the three things on the plot, so none of them is carried by
/// colour alone.
class _CurveLegend extends StatelessWidget {
  const _CurveLegend({required this.hasCeiling});

  final bool hasCeiling;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Wrap(
      spacing: SkotiqTokens.spaceMd,
      runSpacing: SkotiqTokens.spaceXs,
      children: <Widget>[
        _LegendEntry(
          label: 'Conservative S/N',
          color: colors.accent,
          strokeWidth: 2,
        ),
        _LegendEntry(
          label: 'Raw S/N',
          color: colors.accent.withValues(alpha: 0.45),
          strokeWidth: 1.2,
        ),
        _LegendEntry(
          label: 'Goal',
          color: colors.textMuted,
          strokeWidth: 1,
          dashed: true,
        ),
        if (hasCeiling)
          _LegendEntry(
            label: DepthLockCurvePainter.ceilingLabel,
            color: colors.warning,
            strokeWidth: 1,
            dashed: true,
          ),
      ],
    );
  }
}

class _LegendEntry extends StatelessWidget {
  const _LegendEntry({
    required this.label,
    required this.color,
    required this.strokeWidth,
    this.dashed = false,
  });

  final String label;
  final Color color;
  final double strokeWidth;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        CustomPaint(
          size: const Size(16, 8),
          painter: _LegendSwatchPainter(
            color: color,
            strokeWidth: strokeWidth,
            dashed: dashed,
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceXs),
        Text(
          label,
          // Legend text is ink, never the series colour — the swatch beside it
          // is what carries identity.
          style: SkotiqTypography.caption.copyWith(
            color: colors.textSecondary,
          ),
        ),
      ],
    );
  }
}

class _LegendSwatchPainter extends CustomPainter {
  const _LegendSwatchPainter({
    required this.color,
    required this.strokeWidth,
    required this.dashed,
  });

  final Color color;
  final double strokeWidth;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    final double y = size.height / 2;
    if (!dashed) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      return;
    }
    const double dash = 4;
    const double gap = 3;
    double x = 0;
    while (x < size.width) {
      canvas.drawLine(
        Offset(x, y),
        Offset(math.min(x + dash, size.width), y),
        paint,
      );
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_LegendSwatchPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.dashed != dashed;
}

/// The same points as rows, for anyone the plot does not serve.
class _CurveTable extends StatelessWidget {
  const _CurveTable({required this.points, required this.exposureSecs});

  final List<DepthLockCurvePoint> points;
  final double exposureSecs;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    // Thinned to the ends and a stride through the middle: a table of sixty
    // near-identical rows is not more accessible than the chart, it is just
    // longer.
    final int stride = math.max(1, (points.length / 12).ceil());
    final rows = <DepthLockCurvePoint>[
      for (var i = 0; i < points.length; i += stride) points[i],
      if (points.isNotEmpty && (points.length - 1) % stride != 0) points.last,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceXs),
          child: Row(
            children: <Widget>[
              Expanded(
                  flex: 3, child: _cell(context, 'Integration', header: true)),
              Expanded(flex: 2, child: _cell(context, 'Frames', header: true)),
              Expanded(flex: 2, child: _cell(context, 'S/N', header: true)),
              Expanded(
                  flex: 3, child: _cell(context, 'Conservative', header: true)),
            ],
          ),
        ),
        for (final point in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              children: <Widget>[
                Expanded(
                  flex: 3,
                  child: _cell(
                    context,
                    '${depthLockDuration(depthLockHours(frames: point.frames, exposureSecs: exposureSecs))}'
                    '${point.projected ? ' (projected)' : ''}',
                  ),
                ),
                Expanded(flex: 2, child: _cell(context, '${point.frames}')),
                Expanded(
                  flex: 2,
                  child: _cell(context, point.score.toStringAsFixed(1)),
                ),
                Expanded(
                  flex: 3,
                  child: _cell(
                    context,
                    point.conservativeScore.toStringAsFixed(1),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        Text(
          'Rows marked projected are the noise model run forward at the '
          'recent sky.',
          style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }

  Widget _cell(BuildContext context, String text, {bool header = false}) {
    final colors = context.skotiqColors;
    return Text(
      text,
      style: SkotiqTypography.caption.copyWith(
        color: header ? colors.textMuted : colors.textSecondary,
        fontWeight: header ? FontWeight.w600 : FontWeight.w400,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// Where the plot's data sits inside its box.
@immutable
class DepthLockCurveGeometry {
  const DepthLockCurveGeometry({
    required this.plot,
    required this.maxHours,
    required this.maxScore,
    required this.hours,
  });

  /// The drawing area, inside the axis gutters.
  final Rect plot;
  final double maxHours;
  final double maxScore;

  /// Integration hours for each point, in order.
  final List<double> hours;

  double xFor(double hoursValue) =>
      plot.left + (maxHours <= 0 ? 0 : hoursValue / maxHours) * plot.width;

  double yFor(double score) =>
      plot.bottom - (maxScore <= 0 ? 0 : score / maxScore) * plot.height;

  /// The point whose x is nearest [dx].
  int nearestIndex(double dx) {
    var best = 0;
    var bestDistance = double.infinity;
    for (var i = 0; i < hours.length; i++) {
      final double distance = (xFor(hours[i]) - dx).abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        best = i;
      }
    }
    return best;
  }
}

/// Draws the two series, the reference lines and the crosshair.
class DepthLockCurvePainter extends CustomPainter {
  DepthLockCurvePainter({
    required this.points,
    required this.exposureSecs,
    required this.threshold,
    required this.ceiling,
    required this.hoverIndex,
    required this.colors,
  });

  final List<DepthLockCurvePoint> points;
  final double exposureSecs;
  final double threshold;

  /// The score the calibration floor caps at, when the goal cannot reach its
  /// threshold. Null otherwise.
  final double? ceiling;
  final int? hoverIndex;
  final SkotiqColors colors;

  /// Room for the y labels on the left and the x labels below.
  static const double _gutterLeft = 30;
  static const double _gutterBottom = 16;
  static const double _gutterTop = 6;

  /// The label a reference line carries at its right end.
  static String goalLabel(double threshold) =>
      'Goal ${threshold.toStringAsFixed(1)}';
  static const String ceilingLabel = 'Floor limit';

  /// The right gutter is sized to the widest reference label rather than a
  /// fixed number: the labels sit outside the plot, and a fixed gutter clips
  /// "Floor limit" — or a two-digit goal — at the panel's edge.
  static double gutterRightFor({
    required double threshold,
    required double? ceiling,
  }) {
    var widest = 0.0;
    for (final label in <String>[
      goalLabel(threshold),
      if (ceiling != null) ceilingLabel,
    ]) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: SkotiqTypography.caption),
        textDirection: TextDirection.ltr,
      )..layout();
      widest = math.max(widest, painter.width);
    }
    return widest + 6;
  }

  static DepthLockCurveGeometry geometryFor({
    required Size size,
    required List<DepthLockCurvePoint> points,
    required double exposureSecs,
    required double gutterRight,
  }) {
    final hours = <double>[
      for (final point in points)
        depthLockHours(frames: point.frames, exposureSecs: exposureSecs),
    ];
    final double maxHours =
        hours.isEmpty ? 0 : hours.reduce((a, b) => a > b ? a : b);
    final double maxScore = points.isEmpty
        ? 1
        : points.map((p) => p.score).reduce((a, b) => a > b ? a : b);
    return DepthLockCurveGeometry(
      plot: Rect.fromLTRB(
        _gutterLeft,
        _gutterTop,
        math.max(_gutterLeft + 1, size.width - gutterRight),
        math.max(_gutterTop + 1, size.height - _gutterBottom),
      ),
      maxHours: maxHours,
      maxScore: maxScore,
      hours: hours,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final geometry = geometryFor(
      size: size,
      points: points,
      exposureSecs: exposureSecs,
      gutterRight: gutterRightFor(threshold: threshold, ceiling: ceiling),
    );
    // The plot must hold the reference lines too, or a threshold above the
    // measured scores would be drawn off the top of its own chart.
    final double top = math.max(
      threshold,
      math.max(geometry.maxScore, ceiling ?? 0),
    );
    final scaled = DepthLockCurveGeometry(
      plot: geometry.plot,
      maxHours: geometry.maxHours,
      maxScore: top * 1.12,
      hours: geometry.hours,
    );

    _paintGrid(canvas, scaled);
    _paintReference(
      canvas,
      scaled,
      value: threshold,
      label: goalLabel(threshold),
      color: colors.textMuted,
    );
    if (ceiling != null) {
      _paintReference(
        canvas,
        scaled,
        value: ceiling!,
        label: ceilingLabel,
        color: colors.warning,
      );
    }
    _paintSeries(
      canvas,
      scaled,
      value: (p) => p.score,
      color: colors.accent.withValues(alpha: 0.45),
      strokeWidth: 1.2,
    );
    _paintSeries(
      canvas,
      scaled,
      value: (p) => p.conservativeScore,
      color: colors.accent,
      strokeWidth: 2,
    );
    _paintCrosshair(canvas, scaled, size);
  }

  void _paintGrid(Canvas canvas, DepthLockCurveGeometry geometry) {
    final axis = Paint()
      ..color = colors.border
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(geometry.plot.left, geometry.plot.bottom),
      Offset(geometry.plot.right, geometry.plot.bottom),
      axis,
    );

    // Three horizontal rules and their labels: enough to read a value off,
    // few enough to stay behind the data.
    final grid = Paint()
      ..color = colors.border.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    for (var i = 1; i <= 2; i++) {
      final double value = geometry.maxScore * i / 2;
      final double y = geometry.yFor(value);
      canvas.drawLine(
        Offset(geometry.plot.left, y),
        Offset(geometry.plot.right, y),
        grid,
      );
      _paintText(
        canvas,
        value.toStringAsFixed(0),
        Offset(geometry.plot.left - 4, y - 6),
        colors.textMuted,
        alignRight: true,
      );
    }
    _paintText(
      canvas,
      '0',
      Offset(geometry.plot.left - 4, geometry.plot.bottom - 6),
      colors.textMuted,
      alignRight: true,
    );
    _paintText(
      canvas,
      depthLockDuration(geometry.maxHours),
      Offset(geometry.plot.right, geometry.plot.bottom + 3),
      colors.textMuted,
      alignRight: true,
    );
    _paintText(
      canvas,
      '0 h',
      Offset(geometry.plot.left, geometry.plot.bottom + 3),
      colors.textMuted,
    );
  }

  void _paintReference(
    Canvas canvas,
    DepthLockCurveGeometry geometry, {
    required double value,
    required String label,
    required Color color,
  }) {
    final double y = geometry.yFor(value);
    final paint = Paint()
      ..color = color.withValues(alpha: 0.8)
      ..strokeWidth = 1;
    double x = geometry.plot.left;
    while (x < geometry.plot.right) {
      canvas.drawLine(
        Offset(x, y),
        Offset(math.min(x + 5, geometry.plot.right), y),
        paint,
      );
      x += 9;
    }
    // Labelled where the line ends, so the reader never has to match a colour
    // to a legend to know which rule is which.
    _paintText(canvas, label, Offset(geometry.plot.right + 3, y - 6), color);
  }

  void _paintSeries(
    Canvas canvas,
    DepthLockCurveGeometry geometry, {
    required double Function(DepthLockCurvePoint) value,
    required Color color,
    required double strokeWidth,
  }) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    for (var i = 1; i < points.length; i++) {
      final Offset a = Offset(
        geometry.xFor(geometry.hours[i - 1]),
        geometry.yFor(value(points[i - 1])),
      );
      final Offset b = Offset(
        geometry.xFor(geometry.hours[i]),
        geometry.yFor(value(points[i])),
      );
      // A segment is projected when the point it arrives at is: the join
      // between measured and projected belongs to the future half.
      if (points[i].projected) {
        _dashedLine(canvas, a, b, paint);
      } else {
        canvas.drawLine(a, b, paint);
      }
    }
  }

  void _dashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    final double length = (b - a).distance;
    if (length <= 0) return;
    final Offset unit = (b - a) / length;
    const double dash = 4;
    const double gap = 3;
    double travelled = 0;
    while (travelled < length) {
      final double segment = math.min(dash, length - travelled);
      canvas.drawLine(
        a + unit * travelled,
        a + unit * (travelled + segment),
        paint,
      );
      travelled += dash + gap;
    }
  }

  void _paintCrosshair(
    Canvas canvas,
    DepthLockCurveGeometry geometry,
    Size size,
  ) {
    final int? index = hoverIndex;
    if (index == null || index < 0 || index >= points.length) return;
    final point = points[index];
    final double x = geometry.xFor(geometry.hours[index]);

    canvas.drawLine(
      Offset(x, geometry.plot.top),
      Offset(x, geometry.plot.bottom),
      Paint()
        ..color = colors.textMuted.withValues(alpha: 0.5)
        ..strokeWidth = 1,
    );
    canvas.drawCircle(
      Offset(x, geometry.yFor(point.conservativeScore)),
      3.5,
      Paint()..color = colors.accent,
    );

    final String text =
        '${depthLockDuration(geometry.hours[index])} · ${point.frames} frames\n'
        'S/N ${point.score.toStringAsFixed(1)} · conservative '
        '${point.conservativeScore.toStringAsFixed(1)}'
        '${point.projected ? '\nprojected' : ''}';
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: SkotiqTypography.caption.copyWith(
          color: colors.textPrimary,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    // Flip the plate to the other side of the crosshair near the right edge
    // rather than let it run off the chart.
    final double left =
        x + 8 + painter.width > size.width ? x - 8 - painter.width : x + 8;
    final Rect plate = Rect.fromLTWH(
      left - 4,
      geometry.plot.top,
      painter.width + 8,
      painter.height + 6,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          plate, const Radius.circular(SkotiqTokens.radiusXs)),
      Paint()..color = colors.surfaceElevated.withValues(alpha: 0.95),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          plate, const Radius.circular(SkotiqTokens.radiusXs)),
      Paint()
        ..color = colors.border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    painter.paint(canvas, Offset(left, geometry.plot.top + 3));
  }

  void _paintText(
    Canvas canvas,
    String text,
    Offset at,
    Color color, {
    bool alignRight = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: SkotiqTypography.caption.copyWith(color: color),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      alignRight ? Offset(at.dx - painter.width, at.dy) : at,
    );
  }

  @override
  bool shouldRepaint(DepthLockCurvePainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.threshold != threshold ||
      oldDelegate.ceiling != ceiling ||
      oldDelegate.hoverIndex != hoverIndex ||
      oldDelegate.exposureSecs != exposureSecs ||
      oldDelegate.colors != colors;
}
