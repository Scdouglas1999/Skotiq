import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:skotiq_astro/format.dart';

import '../components/series_chart.dart' show SeriesChart, SeriesChartTone;
import '../theme/skotiq_chart_colors.dart';
import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';
import 'chart_scale.dart';

/// How a [ChartSeries] is drawn.
enum ChartSeriesKind {
  /// Points joined in order.
  line,

  /// Hold each value until the next point, then jump.
  step,

  /// One dot per point.
  scatter,

  /// One bar per point, from the axis floor (or zero) to the value.
  bars,
}

/// Which value scale a series or a rule is read against.
enum ChartValueAxis { left, right }

/// What an axis measures, which decides where its ticks fall and how they
/// print.
enum ChartAxisKind {
  /// A plain number on round decimal steps.
  number,

  /// Milliseconds since the epoch, labeled as clock times (`23:30`) on round
  /// minute steps.
  clock,

  /// Seconds, labeled as a length of time (`45s`, `12m`, `2h`) on round time
  /// steps.
  elapsed,
}

/// One data series on a [SkotiqChart].
@immutable
class ChartSeries {
  const ChartSeries({
    required this.points,
    this.label,
    this.tone = SeriesChartTone.primary,
    this.color,
    this.kind = ChartSeriesKind.line,
    this.axis = ChartValueAxis.left,
    this.dashed = false,
    this.filled = false,
    this.strokeWidth = 1.5,
    this.dotRadius = 2.5,
    this.errors,
  });

  /// The samples as (x, y). A non-finite y is a gap: a line breaks there
  /// instead of bridging it, so a missing reading never draws as a value.
  final List<Offset> points;

  /// The series name in the hover readout and the legend. Null leaves the
  /// series out of both.
  final String? label;

  /// The series color as a role, resolved against the active palette.
  final SeriesChartTone tone;

  /// A fixed data hue (one of [SkotiqChartColors]) instead of [tone]. It is
  /// re-expressed on the red channel in red-night mode.
  final Color? color;

  final ChartSeriesKind kind;
  final ChartValueAxis axis;

  /// Drawn as dashes, for a reference series such as a model or a setpoint.
  final bool dashed;

  /// Shade the area between the line and the bottom of the plot.
  final bool filled;

  final double strokeWidth;

  /// Dot radius for [ChartSeriesKind.scatter].
  final double dotRadius;

  /// The uncertainty of each point, one per entry of [points], drawn as a
  /// bar from `y - error` to `y + error` on a scatter series.
  final List<double>? errors;

  @override
  bool operator ==(Object other) =>
      other is ChartSeries &&
      (identical(other.points, points) || listEquals(other.points, points)) &&
      other.label == label &&
      other.tone == tone &&
      other.color == color &&
      other.kind == kind &&
      other.axis == axis &&
      other.dashed == dashed &&
      other.filled == filled &&
      other.strokeWidth == strokeWidth &&
      other.dotRadius == dotRadius &&
      (identical(other.errors, errors) || listEquals(other.errors, errors));

  @override
  int get hashCode => Object.hash(
    points.length,
    label,
    tone,
    color,
    kind,
    axis,
    dashed,
    filled,
    strokeWidth,
    dotRadius,
  );
}

/// One axis of a [SkotiqChart].
@immutable
class ChartAxis {
  const ChartAxis({
    this.kind = ChartAxisKind.number,
    this.min,
    this.max,
    this.ticks,
    this.unit = '',
    this.title,
    this.format,
    this.readout,
    this.includeZero = false,
    this.inverted = false,
    this.maxTicks = 5,
  });

  final ChartAxisKind kind;

  /// Fixed ends. Null fits the data: a value axis snaps outward to round
  /// ticks, the horizontal axis uses the data's own ends.
  final double? min;
  final double? max;

  /// Fixed tick values, for a scale with conventional stops (altitude at 0,
  /// 30, 60, 90). Null picks round values.
  final List<double>? ticks;

  /// Written after the top (value axis) or last (horizontal axis) tick label
  /// and after every value in the hover readout: ` px`, `"`, ` °C`.
  final String unit;

  /// A caption under the horizontal axis. Value axes carry their unit on the
  /// scale instead, where it costs no width.
  final String? title;

  /// How a tick or a hovered value prints. Null prints a number at the
  /// precision of the tick step, or a clock or elapsed time per [kind].
  final String Function(double value)? format;

  /// How a hovered position on the horizontal axis prints in the readout,
  /// when that should say more than the tick label does (the clock time as
  /// well as the elapsed time). Null uses the tick format.
  final String Function(double value)? readout;

  /// Keep zero in a fitted range, for a quantity where the distance from zero
  /// is the point (counts, power).
  final bool includeZero;

  /// Draw a value axis with its smallest value at the top, for a quantity
  /// that reads better that way (magnitudes: brighter is smaller).
  final bool inverted;

  /// The most ticks this axis labels.
  final int maxTicks;

  @override
  bool operator ==(Object other) =>
      other is ChartAxis &&
      other.kind == kind &&
      other.min == min &&
      other.max == max &&
      listEquals(other.ticks, ticks) &&
      other.unit == unit &&
      other.title == title &&
      other.format == format &&
      other.readout == readout &&
      other.includeZero == includeZero &&
      other.inverted == inverted &&
      other.maxTicks == maxTicks;

  @override
  int get hashCode =>
      Object.hash(kind, min, max, unit, title, format, includeZero, maxTicks);
}

/// A straight reference line across the plot: a threshold, a median, the
/// moment of an event.
@immutable
class ChartRule {
  /// A vertical line at [value] on the horizontal axis.
  const ChartRule.x(
    this.value, {
    this.tone = SeriesChartTone.muted,
    this.color,
    this.dashed = true,
    this.label,
  }) : vertical = true,
       axis = ChartValueAxis.left;

  /// A horizontal line at [value] on a value axis.
  const ChartRule.y(
    this.value, {
    this.axis = ChartValueAxis.left,
    this.tone = SeriesChartTone.muted,
    this.color,
    this.dashed = true,
    this.label,
  }) : vertical = false;

  final double value;
  final bool vertical;
  final ChartValueAxis axis;
  final SeriesChartTone tone;
  final Color? color;
  final bool dashed;

  /// A short caption drawn at the line's end.
  final String? label;

  @override
  bool operator ==(Object other) =>
      other is ChartRule &&
      other.value == value &&
      other.vertical == vertical &&
      other.axis == axis &&
      other.tone == tone &&
      other.color == color &&
      other.dashed == dashed &&
      other.label == label;

  @override
  int get hashCode =>
      Object.hash(value, vertical, axis, tone, color, dashed, label);
}

/// The one chart: line, step, scatter and bar series against labeled axes,
/// with a grid, reference rules, a hover readout and empty and loading
/// states. Colors, type and the red-night palette come from the theme.
///
/// The chart fills the width it is given. It is [height] tall, or as tall as
/// its parent allows when [height] is null.
class SkotiqChart extends StatefulWidget {
  const SkotiqChart({
    super.key,
    required this.series,
    required this.semanticLabel,
    this.x = const ChartAxis(),
    this.y = const ChartAxis(),
    this.y2,
    this.rules = const <ChartRule>[],
    this.height,
    this.loading = false,
    this.emptyText = 'No data yet',
    this.readout = true,
    this.legend = false,
    this.dense = false,
  });

  final List<ChartSeries> series;

  /// One sentence that says what the chart shows, for a screen reader.
  final String semanticLabel;

  final ChartAxis x;
  final ChartAxis y;

  /// The right-hand value axis. Required for a series on
  /// [ChartValueAxis.right] to get a scale of its own.
  final ChartAxis? y2;

  final List<ChartRule> rules;
  final double? height;

  /// Data is on its way: the plot shows a progress mark instead of
  /// [emptyText].
  final bool loading;

  /// Shown in the plot when no series has a finite point.
  final String emptyText;

  /// Show the values under the pointer (or a touch) in a readout.
  final bool readout;

  /// Show a row of series names with their color keys under the plot.
  final bool legend;

  /// Tighter gutters and 9 px labels, for a chart under about 120 px tall.
  final bool dense;

  /// The resolved color of a series or rule: a fixed hue re-expressed for red
  /// night, else the tone's role color.
  static Color resolveColor(
    SkotiqColors colors,
    SeriesChartTone tone,
    Color? color,
  ) => color != null
      ? SkotiqChartColors.forTheme(color, colors)
      : SeriesChart.colorFor(tone, colors);

  @override
  State<SkotiqChart> createState() => _SkotiqChartState();
}

class _SkotiqChartState extends State<SkotiqChart> {
  final ValueNotifier<Offset?> _pointer = ValueNotifier<Offset?>(null);
  final _LabelCache _labels = _LabelCache();

  @override
  void dispose() {
    _pointer.dispose();
    _labels.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final scaler = MediaQuery.textScalerOf(context);
    final labelStyle = TextStyle(
      fontFamily: SkotiqTypography.fontFamilyMono,
      fontSize: widget.dense
          ? SkotiqTypography.fontSize9
          : SkotiqTypography.fontSize10,
      height: 1,
      color: colors.textMuted,
    );
    _labels.configure(labelStyle, scaler);
    final layout = ChartLayout(
      series: widget.series,
      x: widget.x,
      y: widget.y,
      y2: widget.y2,
      rules: widget.rules,
      dense: widget.dense,
    );

    Widget plot = LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final hasData = layout.hasData;
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            RepaintBoundary(
              child: CustomPaint(
                painter: _ChartPainter(
                  layout: layout,
                  colors: colors,
                  labels: _labels,
                ),
              ),
            ),
            if (!hasData)
              Center(
                child: widget.loading
                    ? SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colors.textMuted,
                        ),
                      )
                    : Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: SkotiqTokens.spaceSm,
                        ),
                        child: Text(
                          widget.emptyText,
                          textAlign: TextAlign.center,
                          style: SkotiqTypography.bodySm.copyWith(
                            color: colors.textMuted,
                          ),
                        ),
                      ),
              ),
            if (hasData && widget.readout && size.width > 0)
              Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (e) => _pointer.value = e.localPosition,
                onPointerMove: (e) => _pointer.value = e.localPosition,
                onPointerHover: (e) => _pointer.value = e.localPosition,
                child: MouseRegion(
                  onExit: (_) => _pointer.value = null,
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: _ReadoutPainter(
                        layout: layout,
                        colors: colors,
                        labels: _labels,
                        pointer: _pointer,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );

    final height = widget.height;
    if (height != null) {
      plot = SizedBox(height: height, width: double.infinity, child: plot);
    }

    final named = <ChartSeries>[
      for (final s in widget.series)
        if (s.label != null) s,
    ];
    return Semantics(
      container: true,
      label: widget.semanticLabel,
      child: ExcludeSemantics(
        child: widget.legend && named.isNotEmpty
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (height == null) Expanded(child: plot) else plot,
                  const SizedBox(height: SkotiqTokens.spaceXs),
                  Wrap(
                    spacing: SkotiqTokens.spaceMd,
                    runSpacing: 2,
                    children: <Widget>[
                      for (final s in named)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Container(
                              width: 10,
                              height: s.kind == ChartSeriesKind.scatter ? 6 : 2,
                              decoration: BoxDecoration(
                                color: SkotiqChart.resolveColor(
                                  colors,
                                  s.tone,
                                  s.color,
                                ),
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              s.label!,
                              style: SkotiqTypography.labelSm.copyWith(
                                color: colors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ],
              )
            : plot,
      ),
    );
  }
}

/// Where everything on a chart lands: the ranges, the ticks and the mapping
/// from a value to a pixel. Public so a test can ask where a point is drawn
/// and which labels an axis prints, since canvas text leaves nothing in the
/// widget tree to read.
class ChartLayout {
  ChartLayout({
    required this.series,
    required this.x,
    required this.y,
    required this.y2,
    required this.rules,
    this.dense = false,
  }) {
    _fit();
  }

  final List<ChartSeries> series;
  final ChartAxis x;
  final ChartAxis y;
  final ChartAxis? y2;
  final List<ChartRule> rules;
  final bool dense;

  late final bool hasData;
  late final double xMin;
  late final double xMax;
  late final ChartRange? _left;
  late final ChartRange? _right;

  /// The fitted or fixed range of a value axis, or null when nothing uses it.
  ChartRange? valueRange(ChartValueAxis axis) =>
      axis == ChartValueAxis.left ? _left : _right;

  void _fit() {
    double? dataXMin;
    double? dataXMax;
    final lo = <ChartValueAxis, double>{};
    final hi = <ChartValueAxis, double>{};
    for (final s in series) {
      for (final p in s.points) {
        if (!p.dx.isFinite || !p.dy.isFinite) continue;
        if (dataXMin == null || p.dx < dataXMin) dataXMin = p.dx;
        if (dataXMax == null || p.dx > dataXMax) dataXMax = p.dx;
        final a = lo[s.axis];
        final b = hi[s.axis];
        if (a == null || p.dy < a) lo[s.axis] = p.dy;
        if (b == null || p.dy > b) hi[s.axis] = p.dy;
      }
    }
    hasData = dataXMin != null;
    for (final rule in rules) {
      if (rule.vertical || !rule.value.isFinite) continue;
      final a = lo[rule.axis];
      final b = hi[rule.axis];
      if (a == null || rule.value < a) lo[rule.axis] = rule.value;
      if (b == null || rule.value > b) hi[rule.axis] = rule.value;
    }

    var x0 = x.min ?? dataXMin ?? 0;
    var x1 = x.max ?? dataXMax ?? 1;
    if (!(x1 > x0)) {
      // One sample, or all at one x: center it.
      x0 -= 0.5;
      x1 += 0.5;
    }
    xMin = x0;
    xMax = x1;
    _left = _valueRange(y, lo[ChartValueAxis.left], hi[ChartValueAxis.left]);
    final right = y2;
    _right = right == null
        ? null
        : _valueRange(
            right,
            lo[ChartValueAxis.right],
            hi[ChartValueAxis.right],
          );
  }

  static ChartRange? _valueRange(ChartAxis axis, double? lo, double? hi) {
    final fixedMin = axis.min;
    final fixedMax = axis.max;
    if (fixedMin == null && fixedMax == null && lo == null) return null;
    final fixed = axis.ticks;
    if (fixedMin != null && fixedMax != null) {
      return ChartRange(
        fixedMin,
        fixedMax,
        fixed != null
            ? ChartTicks(fixed, _decimalsOf(fixed))
            : ChartScale.ticksWithin(fixedMin, fixedMax, axis.maxTicks),
      );
    }
    final nice = ChartScale.niceRange(
      fixedMin ?? lo ?? 0,
      fixedMax ?? hi ?? fixedMin ?? 1,
      targetTicks: math.max(2, axis.maxTicks - 1),
      includeZero: axis.includeZero,
    );
    final min = fixedMin ?? nice.min;
    final max = fixedMax ?? nice.max;
    if (fixed != null) {
      return ChartRange(min, max, ChartTicks(fixed, _decimalsOf(fixed)));
    }
    if (fixedMin == null && fixedMax == null) return nice;
    return ChartRange(
      min,
      max,
      ChartScale.ticksWithin(min, max, axis.maxTicks),
    );
  }

  static int _decimalsOf(List<double> ticks) => ticks.length < 2
      ? 0
      : ChartScale.decimalsFor((ticks[1] - ticks[0]).abs());

  /// The horizontal axis ticks for a plot [plotWidth] wide whose labels are
  /// about [labelWidth] wide.
  List<double> xTicks(double plotWidth, double labelWidth) {
    final fixed = x.ticks;
    if (fixed != null) return fixed;
    final fit = math.max(
      2,
      math.min(x.maxTicks, (plotWidth / (labelWidth + 12)).floor()),
    );
    switch (x.kind) {
      case ChartAxisKind.number:
        return ChartScale.ticksWithin(xMin, xMax, fit).values;
      case ChartAxisKind.elapsed:
        return ChartScale.elapsedTicks(xMin, xMax, fit);
      case ChartAxisKind.clock:
        return <double>[
          for (final t in ChartScale.clockTicks(
            DateTime.fromMillisecondsSinceEpoch(xMin.round()),
            DateTime.fromMillisecondsSinceEpoch(xMax.round()),
            fit,
          ))
            t.millisecondsSinceEpoch.toDouble(),
        ];
    }
  }

  /// [value] on the horizontal axis as its tick label.
  String xLabel(double value, {int? decimals}) {
    final format = x.format;
    if (format != null) return format(value);
    switch (x.kind) {
      case ChartAxisKind.number:
        final d =
            decimals ?? ChartScale.ticksWithin(xMin, xMax, x.maxTicks).decimals;
        final text = value.toStringAsFixed(d);
        return double.parse(text) == 0 ? 0.toStringAsFixed(d) : text;
      case ChartAxisKind.elapsed:
        return ChartScale.elapsedLabel(value);
      case ChartAxisKind.clock:
        return ClockFormat.hm(
          DateTime.fromMillisecondsSinceEpoch(value.round()),
        );
    }
  }

  /// [value] on a value axis as its tick label, without the unit.
  String valueLabel(
    double value,
    ChartValueAxis axis, {
    int extraDecimals = 0,
  }) {
    final config = axis == ChartValueAxis.left ? y : (y2 ?? y);
    final format = config.format;
    if (format != null) return format(value);
    final ticks = valueRange(axis)?.ticks;
    if (ticks == null) return value.toStringAsFixed(1);
    if (extraDecimals == 0) return ticks.label(value);
    return value.toStringAsFixed(math.min(4, ticks.decimals + extraDecimals));
  }

  /// The plot rectangle inside [size] once the gutters for [leftLabelWidth],
  /// [rightLabelWidth] and a label [labelHeight] tall are taken out.
  Rect plotRect(
    Size size, {
    required double leftLabelWidth,
    required double rightLabelWidth,
    required double labelHeight,
  }) {
    final gap = dense ? 3.0 : 6.0;
    final left = leftLabelWidth == 0 ? 0.0 : leftLabelWidth + gap;
    final right = rightLabelWidth == 0
        ? (dense ? 0.0 : gap)
        : rightLabelWidth + gap;
    final bottom =
        labelHeight + gap + (x.title == null ? 0 : labelHeight + gap);
    final top = (labelHeight / 2).ceilToDouble();
    return Rect.fromLTRB(
      left,
      top,
      math.max(left, size.width - right),
      math.max(top, size.height - bottom),
    );
  }

  double xOf(double value, Rect plot) =>
      plot.left + (value - xMin) / (xMax - xMin) * plot.width;

  double? yOf(double value, ChartValueAxis axis, Rect plot) {
    final range = valueRange(axis);
    if (range == null || range.span <= 0) return null;
    final fraction = (value - range.min) / range.span;
    final inverted = (axis == ChartValueAxis.left ? y : (y2 ?? y)).inverted;
    return inverted
        ? plot.top + fraction * plot.height
        : plot.bottom - fraction * plot.height;
  }

  @override
  bool operator ==(Object other) =>
      other is ChartLayout &&
      other.dense == dense &&
      other.x == x &&
      other.y == y &&
      other.y2 == y2 &&
      listEquals(other.series, series) &&
      listEquals(other.rules, rules);

  @override
  int get hashCode => Object.hash(x, y, y2, series.length, rules.length, dense);
}

/// Laid-out tick labels, kept between paints. A live chart repaints every
/// second with the same dozen labels; laying each out again is most of what
/// an axis costs.
class _LabelCache {
  final Map<String, TextPainter> _painters = <String, TextPainter>{};
  TextStyle? _style;
  TextScaler _scaler = TextScaler.noScaling;

  void configure(TextStyle style, TextScaler scaler) {
    if (style == _style && scaler == _scaler) return;
    _style = style;
    _scaler = scaler;
    _clear();
  }

  double get lineHeight => of('0').height;

  TextPainter of(String text, {Color? color}) {
    final key = color == null ? text : '$text\u0000${color.toARGB32()}';
    final cached = _painters[key];
    if (cached != null) return cached;
    if (_painters.length > 96) _clear();
    final style = color == null ? _style : _style?.copyWith(color: color);
    return _painters[key] = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: _scaler,
      maxLines: 1,
    )..layout();
  }

  void _clear() {
    for (final p in _painters.values) {
      p.dispose();
    }
    _painters.clear();
  }

  void dispose() => _clear();
}

/// The geometry both painters share for one size.
class _Frame {
  _Frame(this.layout, this.labels, Size size) {
    final lineHeight = labels.lineHeight;
    left = _valueLabels(ChartValueAxis.left, layout.y);
    right = layout.y2 == null
        ? const <(double, String)>[]
        : _valueLabels(ChartValueAxis.right, layout.y2!);
    plot = layout.plotRect(
      size,
      leftLabelWidth: _widest(left),
      rightLabelWidth: _widest(right),
      labelHeight: lineHeight,
    );
    final sample = layout.xLabel(layout.xMax);
    xTicks = plot.width <= 0
        ? const <double>[]
        : layout.xTicks(plot.width, labels.of(sample).width);
    xDecimals = layout.x.kind == ChartAxisKind.number && xTicks.length > 1
        ? ChartScale.decimalsFor((xTicks[1] - xTicks[0]).abs())
        : null;
  }

  final ChartLayout layout;
  final _LabelCache labels;
  late final List<(double, String)> left;
  late final List<(double, String)> right;
  late final Rect plot;
  late final List<double> xTicks;
  late final int? xDecimals;

  List<(double, String)> _valueLabels(ChartValueAxis axis, ChartAxis config) {
    final range = layout.valueRange(axis);
    if (range == null) return const <(double, String)>[];
    final values = range.ticks.values;
    return <(double, String)>[
      for (var i = 0; i < values.length; i++)
        if (values[i] >= range.min - 1e-9 && values[i] <= range.max + 1e-9)
          (
            values[i],
            i == values.length - 1 && config.unit.isNotEmpty
                ? '${layout.valueLabel(values[i], axis)}${config.unit}'
                : layout.valueLabel(values[i], axis),
          ),
    ];
  }

  double _widest(List<(double, String)> items) {
    var w = 0.0;
    for (final (_, text) in items) {
      w = math.max(w, labels.of(text).width);
    }
    return w.ceilToDouble();
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.layout,
    required this.colors,
    required this.labels,
  });

  final ChartLayout layout;
  final SkotiqColors colors;
  final _LabelCache labels;

  static const double _dash = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = _Frame(layout, labels, size);
    final plot = frame.plot;
    if (plot.width <= 0 || plot.height <= 0) return;
    final lineHeight = labels.lineHeight;

    final grid = Paint()
      ..color = colors.border.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    final axisLine = Paint()
      ..color = colors.border
      ..strokeWidth = 1;

    // Value scales: gridlines from the left scale, labels on both sides. A
    // label that would touch the one before it is skipped, outermost kept.
    void scale(
      List<(double, String)> items,
      ChartValueAxis axis, {
      required bool onLeft,
    }) {
      double? lastY;
      for (final (value, text) in items.reversed) {
        final y = layout.yOf(value, axis, plot);
        if (y == null) continue;
        if (onLeft) {
          canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
        }
        if (lastY != null && (y - lastY).abs() < lineHeight + 2) continue;
        lastY = y;
        final tp = labels.of(text);
        final top = (y - tp.height / 2).clamp(0.0, size.height - tp.height);
        tp.paint(
          canvas,
          Offset(
            onLeft
                ? plot.left - (layout.dense ? 3 : 6) - tp.width
                : plot.right + (layout.dense ? 3 : 6),
            top,
          ),
        );
      }
    }

    scale(frame.left, ChartValueAxis.left, onLeft: true);
    scale(frame.right, ChartValueAxis.right, onLeft: false);

    // Horizontal axis: a faint line and a label per tick.
    var lastRight = double.negativeInfinity;
    final ticks = frame.xTicks;
    for (var i = 0; i < ticks.length; i++) {
      final x = layout.xOf(ticks[i], plot);
      if (x < plot.left - 0.5 || x > plot.right + 0.5) continue;
      canvas.drawLine(
        Offset(x, plot.top),
        Offset(x, plot.bottom),
        Paint()
          ..color = colors.border.withValues(alpha: 0.25)
          ..strokeWidth = 1,
      );
      var text = layout.xLabel(ticks[i], decimals: frame.xDecimals);
      if (i == ticks.length - 1 && layout.x.unit.isNotEmpty) {
        text = '$text${layout.x.unit}';
      }
      final tp = labels.of(text);
      final left = (x - tp.width / 2).clamp(0.0, size.width - tp.width);
      if (left < lastRight + 4) continue;
      lastRight = left + tp.width;
      tp.paint(canvas, Offset(left, plot.bottom + (layout.dense ? 3 : 6)));
    }
    final title = layout.x.title;
    if (title != null) {
      final tp = labels.of(title);
      tp.paint(
        canvas,
        Offset(plot.center.dx - tp.width / 2, size.height - tp.height),
      );
    }

    canvas.drawLine(plot.bottomLeft, plot.bottomRight, axisLine);
    canvas.drawLine(plot.topLeft, plot.bottomLeft, axisLine);

    canvas.save();
    canvas.clipRect(plot.inflate(1));
    for (final rule in layout.rules) {
      _paintRule(canvas, plot, rule);
    }
    for (final s in layout.series) {
      _paintSeries(canvas, plot, s);
    }
    canvas.restore();
  }

  void _paintRule(Canvas canvas, Rect plot, ChartRule rule) {
    final paint = Paint()
      ..color = SkotiqChart.resolveColor(colors, rule.tone, rule.color)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final Offset a;
    final Offset b;
    if (rule.vertical) {
      final x = layout.xOf(rule.value, plot);
      if (x < plot.left || x > plot.right) return;
      a = Offset(x, plot.top);
      b = Offset(x, plot.bottom);
    } else {
      final y = layout.yOf(rule.value, rule.axis, plot);
      if (y == null || y < plot.top || y > plot.bottom) return;
      a = Offset(plot.left, y);
      b = Offset(plot.right, y);
    }
    if (rule.dashed) {
      _dashed(
        canvas,
        Path()
          ..moveTo(a.dx, a.dy)
          ..lineTo(b.dx, b.dy),
        paint,
      );
    } else {
      canvas.drawLine(a, b, paint);
    }
    final label = rule.label;
    if (label != null) {
      final tp = labels.of(label, color: paint.color);
      final at = rule.vertical
          ? Offset(
              (a.dx + 3).clamp(plot.left, plot.right - tp.width),
              plot.top + 1,
            )
          : Offset(plot.right - tp.width - 2, a.dy - tp.height - 1);
      tp.paint(canvas, at);
    }
  }

  void _paintSeries(Canvas canvas, Rect plot, ChartSeries s) {
    final color = SkotiqChart.resolveColor(colors, s.tone, s.color);
    final range = layout.valueRange(s.axis);
    if (range == null || range.span <= 0) return;
    final kx = plot.width / (layout.xMax - layout.xMin);
    final inverted =
        (s.axis == ChartValueAxis.left ? layout.y : (layout.y2 ?? layout.y))
            .inverted;
    final ky = plot.height / range.span * (inverted ? -1 : 1);
    final y0 = inverted ? plot.top : plot.bottom;
    double px(Offset p) => plot.left + (p.dx - layout.xMin) * kx;
    double py(Offset p) => y0 - (p.dy - range.min) * ky;

    switch (s.kind) {
      case ChartSeriesKind.scatter:
        final fill = Paint()..color = color;
        final errors = s.errors;
        final bar = Paint()
          ..color = color.withValues(alpha: 0.4)
          ..strokeWidth = 1;
        for (var i = 0; i < s.points.length; i++) {
          final p = s.points[i];
          if (!p.dx.isFinite || !p.dy.isFinite) continue;
          final at = Offset(px(p), py(p));
          final e = errors != null && i < errors.length ? errors[i] : 0.0;
          if (e.isFinite && e > 0) {
            canvas.drawLine(
              Offset(at.dx, at.dy - e * ky.abs()),
              Offset(at.dx, at.dy + e * ky.abs()),
              bar,
            );
          }
          canvas.drawCircle(at, s.dotRadius, fill);
        }
      case ChartSeriesKind.bars:
        final fill = Paint()..color = color.withValues(alpha: 0.85);
        var pitch = plot.width;
        for (var i = 1; i < s.points.length; i++) {
          final d = (s.points[i].dx - s.points[i - 1].dx).abs() * kx;
          if (d > 0 && d < pitch) pitch = d;
        }
        final width = math.max(1.0, pitch * 0.8);
        final floor = y0 - (math.max(range.min, 0.0) - range.min) * ky;
        for (final p in s.points) {
          if (!p.dx.isFinite || !p.dy.isFinite) continue;
          final x = px(p);
          canvas.drawRect(
            Rect.fromPoints(
              Offset(x - width / 2, py(p)),
              Offset(x + width / 2, floor),
            ),
            fill,
          );
        }
      case ChartSeriesKind.line:
      case ChartSeriesKind.step:
        final stroke = Paint()
          ..color = color
          ..strokeWidth = s.strokeWidth
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round;
        final path = Path();
        final area = s.filled ? Path() : null;
        var run = 0;
        var runStartX = 0.0;
        Offset? previous;
        void endRun() {
          final last = previous;
          if (last != null) {
            if (run == 1) {
              canvas.drawCircle(last, s.strokeWidth, Paint()..color = color);
            }
            area
              ?..lineTo(last.dx, y0)
              ..lineTo(runStartX, y0)
              ..close();
          }
          run = 0;
          previous = null;
        }

        for (final p in _thinned(s, kx)) {
          if (!p.dx.isFinite || !p.dy.isFinite) {
            endRun();
            continue;
          }
          final x = px(p);
          final y = py(p);
          final last = previous;
          if (last == null) {
            path.moveTo(x, y);
            area?.moveTo(x, y);
            runStartX = x;
          } else {
            if (s.kind == ChartSeriesKind.step) {
              path.lineTo(x, last.dy);
              area?.lineTo(x, last.dy);
            }
            path.lineTo(x, y);
            area?.lineTo(x, y);
          }
          previous = Offset(x, y);
          run++;
        }
        endRun();
        if (area != null) {
          canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.12));
        }
        if (s.dashed) {
          _dashed(canvas, path, stroke);
        } else {
          canvas.drawPath(path, stroke);
        }
    }
  }

  /// The points of a line series, thinned when there are several per pixel
  /// column: each column keeps its first, lowest, highest and last sample in
  /// order, so every peak survives and a 20 000-point spectrum costs what a
  /// plot-width one does. Assumes x does not decrease, as a series over time
  /// or frequency does; an unordered series is drawn as it is.
  static Iterable<Offset> _thinned(ChartSeries s, double pixelsPerUnit) {
    final points = s.points;
    if (s.kind != ChartSeriesKind.line || points.length < 2) return points;
    final span = (points.last.dx - points.first.dx) * pixelsPerUnit;
    if (!span.isFinite || span <= 0 || points.length < span * 4) return points;
    final out = <Offset>[];
    var column = double.negativeInfinity;
    Offset? first;
    Offset? low;
    Offset? high;
    Offset? last;
    void flush() {
      final a = first;
      if (a == null) return;
      final lo = low!;
      final hi = high!;
      out.add(a);
      if (lo.dx <= hi.dx) {
        if (!identical(lo, a)) out.add(lo);
        if (!identical(hi, lo)) out.add(hi);
      } else {
        if (!identical(hi, a)) out.add(hi);
        if (!identical(lo, hi)) out.add(lo);
      }
      final z = last!;
      if (!identical(z, out.last)) out.add(z);
      first = null;
    }

    var previousX = double.negativeInfinity;
    for (final p in points) {
      if (!p.dx.isFinite || !p.dy.isFinite) {
        flush();
        out.add(p);
        continue;
      }
      if (p.dx < previousX) return points;
      previousX = p.dx;
      final c = (p.dx * pixelsPerUnit).floorToDouble();
      if (c != column) {
        flush();
        column = c;
      }
      if (first == null) {
        first = low = high = last = p;
      } else {
        if (p.dy < low!.dy) low = p;
        if (p.dy > high!.dy) high = p;
        last = p;
      }
    }
    flush();
    return out;
  }

  static void _dashed(Canvas canvas, Path path, Paint paint) {
    for (final PathMetric metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        canvas.drawPath(metric.extractPath(distance, distance + _dash), paint);
        distance += _dash * 2;
      }
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.colors != colors || old.layout != layout;
}

/// The crosshair and value box under the pointer. A layer of its own, so
/// moving the pointer never repaints the series.
class _ReadoutPainter extends CustomPainter {
  _ReadoutPainter({
    required this.layout,
    required this.colors,
    required this.labels,
    required this.pointer,
  }) : super(repaint: pointer);

  final ChartLayout layout;
  final SkotiqColors colors;
  final _LabelCache labels;
  final ValueListenable<Offset?> pointer;

  @override
  void paint(Canvas canvas, Size size) {
    final at = pointer.value;
    if (at == null) return;
    final frame = _Frame(layout, labels, size);
    final plot = frame.plot;
    if (plot.width <= 0 || !plot.inflate(8).contains(at)) return;

    // The sample nearest the pointer in x, over every series.
    double? nearestX;
    var best = double.infinity;
    for (final s in layout.series) {
      for (final p in s.points) {
        if (!p.dx.isFinite || !p.dy.isFinite) continue;
        final d = (layout.xOf(p.dx, plot) - at.dx).abs();
        if (d < best) {
          best = d;
          nearestX = p.dx;
        }
      }
    }
    if (nearestX == null) return;
    final x = layout.xOf(nearestX, plot);
    canvas.drawLine(
      Offset(x, plot.top),
      Offset(x, plot.bottom),
      Paint()
        ..color = colors.borderHighlight
        ..strokeWidth = 1,
    );

    final lines = <TextPainter>[
      labels.of(
        layout.x.readout?.call(nearestX) ??
            '${layout.xLabel(nearestX, decimals: _hoverDecimals(frame))}'
                '${layout.x.unit}',
        color: colors.textSecondary,
      ),
    ];
    final tolerance = (layout.xMax - layout.xMin) * 1e-9;
    for (final s in layout.series) {
      Offset? hit;
      for (final p in s.points) {
        if (p.dy.isFinite && (p.dx - nearestX).abs() <= tolerance) {
          hit = p;
          break;
        }
      }
      if (hit == null) continue;
      final color = SkotiqChart.resolveColor(colors, s.tone, s.color);
      final y = layout.yOf(hit.dy, s.axis, plot);
      if (y != null && y >= plot.top - 1 && y <= plot.bottom + 1) {
        canvas.drawCircle(Offset(x, y), 3.5, Paint()..color = colors.surface);
        canvas.drawCircle(Offset(x, y), 2.5, Paint()..color = color);
      }
      final unit = (s.axis == ChartValueAxis.left ? layout.y : layout.y2)?.unit;
      final value =
          '${layout.valueLabel(hit.dy, s.axis, extraDecimals: 1)}${unit ?? ''}';
      lines.add(
        labels.of(s.label == null ? value : '${s.label}  $value', color: color),
      );
    }

    var width = 0.0;
    var height = 0.0;
    for (final tp in lines) {
      width = math.max(width, tp.width);
      height += tp.height + 3;
    }
    const pad = 6.0;
    final boxSize = Size(width + pad * 2, height - 3 + pad * 2);
    var left = x + 8;
    if (left + boxSize.width > size.width) left = x - 8 - boxSize.width;
    left = left.clamp(0.0, math.max(0.0, size.width - boxSize.width));
    final top = (at.dy - boxSize.height - 8).clamp(
      0.0,
      math.max(0.0, size.height - boxSize.height),
    );
    final box = RRect.fromRectAndRadius(
      Offset(left, top.toDouble()) & boxSize,
      const Radius.circular(SkotiqTokens.radiusXs),
    );
    canvas.drawRRect(box, Paint()..color = colors.surfaceElevated);
    canvas.drawRRect(
      box,
      Paint()
        ..color = colors.border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    var y = top + pad;
    for (final tp in lines) {
      tp.paint(canvas, Offset(left + pad, y));
      y += tp.height + 3;
    }
  }

  int? _hoverDecimals(_Frame frame) {
    final d = frame.xDecimals;
    return d == null ? null : math.min(4, d + 1);
  }

  @override
  bool shouldRepaint(_ReadoutPainter old) =>
      old.colors != colors || old.layout != layout;
}
