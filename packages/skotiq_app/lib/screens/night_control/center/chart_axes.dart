// Axes for the center charts: a compact value scale on the left (and on the
// right when a line uses the second axis), a clock scale underneath and faint
// gridlines, all fitted to the size the row gives the chart.
//
// The labels sit where SeriesChartPainter puts those values, so a tick reads
// true against the line. Nothing here changes the chart's own ranges.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../data/session/session_format.dart';
import 'center_format.dart';

/// The axis label style: 9 px mono, line height 1.
TextStyle nightAxisStyle(BuildContext context) =>
    SkotiqTypography.monoXs.copyWith(
      fontSize: SkotiqTypography.fontSize9,
      height: 1,
      color: context.skotiqColors.textMuted,
    );

/// Up to [maxTicks] round values inside [lo]..[hi]: the largest round step
/// that leaves at least two of them, thinned to the outermost when there are
/// more than [maxTicks], else just the two ends.
@visibleForTesting
List<double> nightAxisTicks(double lo, double hi, int maxTicks) {
  if (!(hi > lo) || !lo.isFinite || !hi.isFinite) return <double>[lo];
  List<double> inside(double step) => <double>[
        for (var v = (lo / step - 1e-9).ceil() * step;
            v <= hi + step * 1e-9;
            v += step)
          // Snap away float noise such as 0.30000000000000004 and -0.0.
          _snap(v, step),
      ];

  final exponent = (math.log(hi - lo) / math.ln10).floor();
  // Steps from coarse to fine; the finest that still fits [maxTicks] wins.
  var best = const <double>[];
  for (var e = exponent; e >= exponent - 3; e--) {
    for (final mantissa in const <double>[5, 2.5, 2, 1]) {
      final step = mantissa * math.pow(10, e).toDouble();
      final ticks = inside(step);
      if (ticks.length <= maxTicks) {
        if (ticks.length > best.length) best = ticks;
        continue;
      }
      if (best.length >= 2) return best;
      // Too many and nothing coarser had two: evenly spaced, both ends
      // kept, so ±1 rather than −1, 0, 1 when only two fit.
      final last = ticks.length - 1;
      return <double>[
        for (var i = 0; i < maxTicks; i++)
          ticks[(i * last / math.max(1, maxTicks - 1)).round()],
      ];
    }
  }
  return best.length >= 2 ? best : <double>[lo, hi];
}

double _snap(double v, double step) {
  final snapped = (v / step).round() * step;
  final decimals = nightAxisDecimals(step);
  final fixed = double.parse(snapped.toStringAsFixed(decimals));
  return fixed == 0 ? 0 : fixed;
}

/// Decimals that show a step of [step] exactly (at most 3).
@visibleForTesting
int nightAxisDecimals(double step) {
  for (var d = 0; d < 3; d++) {
    final scaled = step * math.pow(10, d);
    if ((scaled - scaled.roundToDouble()).abs() < 1e-6) return d;
  }
  return 3;
}

/// Clock ticks between [from] and [to] on a round minute step, as many as
/// [maxLabels] allows.
@visibleForTesting
List<DateTime> nightTimeTicks(DateTime from, DateTime to, int maxLabels) {
  final span = to.difference(from).inMinutes;
  if (span <= 0 || maxLabels <= 0) return const <DateTime>[];
  for (final step in const <int>[1, 2, 5, 10, 15, 30, 60, 120, 180, 240]) {
    if (span / step > maxLabels + 1) continue;
    final startOfDay = DateTime(from.year, from.month, from.day);
    final minutesIn = from.difference(startOfDay).inMinutes;
    var t = startOfDay.add(Duration(minutes: (minutesIn ~/ step + 1) * step));
    final ticks = <DateTime>[];
    for (; !t.isAfter(to); t = t.add(Duration(minutes: step))) {
      ticks.add(t);
    }
    if (ticks.length <= maxLabels) return ticks;
  }
  return const <DateTime>[];
}

/// A series chart with its value scales, clock scale and gridlines.
class NightChartAxes extends StatelessWidget {
  const NightChartAxes({
    super.key,
    required this.lines,
    required this.semanticLabel,
    this.markers = const <SeriesChartMarker>[],
    this.highlights = const <SeriesChartHighlight>[],
    this.from,
    this.to,
    this.zeroLineY,
    this.leftUnit = '',
    this.rightGrouped = false,
  });

  final List<SeriesChartLine> lines;
  final String semanticLabel;
  final List<SeriesChartMarker> markers;
  final List<SeriesChartHighlight> highlights;
  final DateTime? from;
  final DateTime? to;
  final double? zeroLineY;

  /// Put on the top left label: ` px`, `″`, ` °C`.
  final String leftUnit;

  /// Right labels as grouped whole numbers (`45 484`).
  final bool rightGrouped;

  /// Below this chart height the scales are left out rather than crowded.
  static const double minChartHeight = 18;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final style = nightAxisStyle(context);
    final scaler = MediaQuery.textScalerOf(context);
    final labelHeight = scaler.scale(9);

    return LayoutBuilder(builder: (context, constraints) {
      final timeHeight = labelHeight + 3;
      final chartHeight = constraints.maxHeight - timeHeight;
      SeriesChart chart(double height) => SeriesChart(
            lines: lines,
            markers: markers,
            highlights: highlights,
            from: from,
            to: to,
            zeroLineY: zeroLineY,
            height: math.max(0, height),
            semanticLabel: semanticLabel,
          );
      if (chartHeight < minChartHeight) {
        return chart(constraints.maxHeight);
      }

      final painter = SeriesChartPainter(
        colors: colors,
        lines: lines,
        markers: markers,
        highlights: highlights,
        from: from,
        to: to,
        zeroLineY: zeroLineY,
      );
      final maxTicks = chartHeight >= labelHeight * 5 ? 3 : 2;

      List<(double, String)> labels(
        SeriesChartAxis axis,
        String Function(double value, int decimals) format,
      ) {
        final range = painter.valueRange(axis);
        if (range == null) return const <(double, String)>[];
        final ticks = nightAxisTicks(range.$1, range.$2, maxTicks);
        // A round step shows exactly; the two-end fallback shows to 0.01.
        final decimals = ticks.length < 2
            ? 1
            : math.min(nightAxisDecimals(ticks[1] - ticks[0]), 2);
        return <(double, String)>[
          for (final t in ticks) (t, format(t, decimals)),
        ];
      }

      final left = labels(SeriesChartAxis.left, (v, d) => nightFixed(v, d));
      if (left.isNotEmpty) {
        final top = left.last;
        left[left.length - 1] = (top.$1, '${top.$2}$leftUnit');
      }
      final right = labels(
        SeriesChartAxis.right,
        (v, d) => rightGrouped ? nightGrouped(v.round()) : nightFixed(v, d),
      );

      double widest(List<(double, String)> items) {
        var w = 0.0;
        for (final (_, text) in items) {
          final tp = TextPainter(
            text: TextSpan(text: text, style: style),
            textScaler: scaler,
            textDirection: TextDirection.ltr,
            maxLines: 1,
          )..layout();
          w = math.max(w, tp.width);
          tp.dispose();
        }
        return w == 0 ? 0 : w.ceilToDouble() + 3;
      }

      final leftWidth = widest(left);
      final rightWidth = widest(right);
      final plotWidth = constraints.maxWidth - leftWidth - rightWidth;
      final range = painter.timeRange;
      final clockWidth = widest(const <(double, String)>[(0, '00:00')]) + 6;
      final timeTicks = range == null || plotWidth <= 0
          ? const <DateTime>[]
          : nightTimeTicks(
              DateTime.fromMillisecondsSinceEpoch(range.$1),
              DateTime.fromMillisecondsSinceEpoch(range.$2),
              (plotWidth / clockWidth).floor(),
            );

      // Labels closer than a line apart: keep the outer ones.
      // Each label with the y it sits at, in chart order.
      List<(double, String)> spaced(
        List<(double, String)> items,
        SeriesChartAxis axis,
      ) {
        final kept = <(double, String)>[];
        double? lastY;
        for (final (value, text) in items) {
          final y = painter.yOf(value, axis, chartHeight);
          if (y == null) continue;
          if (lastY != null && (lastY - y).abs() < labelHeight + 1) continue;
          kept.add((y, text));
          lastY = y;
        }
        return kept;
      }

      Widget gutter(
        List<(double, String)> items,
        double width,
        TextAlign align,
      ) =>
          SizedBox(
            width: width,
            child: ExcludeSemantics(
              child: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  for (final (y, text) in items)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: (y - labelHeight / 2)
                          .clamp(0.0, math.max(0.0, chartHeight - labelHeight)),
                      child: Padding(
                        padding: EdgeInsets.only(
                          right: align == TextAlign.right ? 3 : 0,
                          left: align == TextAlign.left ? 3 : 0,
                        ),
                        child: Text(
                          text,
                          style: style,
                          maxLines: 1,
                          softWrap: false,
                          textAlign: align,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            height: chartHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (leftWidth > 0)
                  gutter(
                    spaced(left, SeriesChartAxis.left),
                    leftWidth,
                    TextAlign.right,
                  ),
                Expanded(
                  child: CustomPaint(
                    painter: _GridPainter(
                      painter: painter,
                      yTicks: <double>[for (final (v, _) in left) v],
                      timeTicks: timeTicks,
                      line: colors.border,
                    ),
                    child: chart(chartHeight),
                  ),
                ),
                if (rightWidth > 0)
                  gutter(
                    spaced(right, SeriesChartAxis.right),
                    rightWidth,
                    TextAlign.left,
                  ),
              ],
            ),
          ),
          SizedBox(
            height: timeHeight,
            child: Padding(
              padding: EdgeInsets.only(left: leftWidth, right: rightWidth),
              child: ExcludeSemantics(
                child: _TimeScale(
                  painter: painter,
                  ticks: timeTicks,
                  width: math.max(0, plotWidth),
                  labelWidth: clockWidth,
                  style: style,
                ),
              ),
            ),
          ),
        ],
      );
    });
  }
}

class _TimeScale extends StatelessWidget {
  const _TimeScale({
    required this.painter,
    required this.ticks,
    required this.width,
    required this.labelWidth,
    required this.style,
  });

  final SeriesChartPainter painter;
  final List<DateTime> ticks;
  final double width;
  final double labelWidth;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final labels = <Widget>[];
    var lastRight = double.negativeInfinity;
    for (final t in ticks) {
      final x = painter.xOf(t, width);
      if (x == null) continue;
      final left = (x - labelWidth / 2).clamp(0.0, width - labelWidth);
      if (left < lastRight) continue;
      lastRight = left + labelWidth;
      labels.add(
        Positioned(
          left: left,
          top: 3,
          width: labelWidth,
          child: Text(
            nightClockHm(t),
            style: style,
            maxLines: 1,
            softWrap: false,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return Stack(clipBehavior: Clip.none, children: labels);
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter({
    required this.painter,
    required this.yTicks,
    required this.timeTicks,
    required this.line,
  });

  final SeriesChartPainter painter;
  final List<double> yTicks;
  final List<DateTime> timeTicks;
  final Color line;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = line.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    for (final v in yTicks) {
      final y = painter.yOf(v, SeriesChartAxis.left, size.height);
      if (y == null) continue;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    for (final t in timeTicks) {
      final x = painter.xOf(t, size.width);
      if (x == null) continue;
      canvas.drawLine(
        Offset(x, size.height - 3),
        Offset(x, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      old.line != line ||
      !listEquals(old.yTicks, yTicks) ||
      !listEquals(old.timeTicks, timeTicks) ||
      old.painter.timeRange != painter.timeRange;
}

/// One band of a [NightChartStrips]: its lines on their own value scale,
/// and the unit that scale is in.
@immutable
class NightChartStrip {
  const NightChartStrip({
    required this.lines,
    required this.unit,
    this.unitTone = SeriesChartTone.muted,
    this.grouped = false,
  });

  final List<SeriesChartLine> lines;

  /// The scale's unit, written beside it: `°C`, `steps`.
  final String unit;

  /// The unit's color, the color of the strip's line, so it doubles as the
  /// line's key.
  final SeriesChartTone unitTone;

  /// Scale labels as grouped whole numbers (`45 480`).
  final bool grouped;
}

/// Small multiples: two or more charts stacked on one clock, each with its
/// own value scale and unit, sharing [markers] and one clock scale under the
/// bottom band. Used where series in different units would otherwise share
/// one plot and leave every scale unreadable.
class NightChartStrips extends StatelessWidget {
  const NightChartStrips({
    super.key,
    required this.strips,
    required this.semanticLabel,
    this.markers = const <SeriesChartMarker>[],
    this.from,
    this.to,
  });

  final List<NightChartStrip> strips;
  final String semanticLabel;
  final List<SeriesChartMarker> markers;
  final DateTime? from;
  final DateTime? to;

  /// The space between two bands.
  static const double gap = 4;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final style = nightAxisStyle(context);
    final scaler = MediaQuery.textScalerOf(context);
    final labelHeight = scaler.scale(9);

    double textWidth(String text, TextStyle style) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: style),
        textScaler: scaler,
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final w = tp.width;
      tp.dispose();
      return w;
    }

    return LayoutBuilder(builder: (context, constraints) {
      final timeHeight = labelHeight + 3;
      final count = strips.length;
      final bandHeight =
          (constraints.maxHeight - timeHeight - gap * (count - 1)) / count;
      final painters = <SeriesChartPainter>[
        for (final strip in strips)
          SeriesChartPainter(
            colors: colors,
            lines: strip.lines,
            markers: markers,
            highlights: const <SeriesChartHighlight>[],
            from: from,
            to: to,
            zeroLineY: null,
          ),
      ];
      // A band about a label tall (its label may run into the gap below)
      // still gets its unit and its top value; two values need a label and
      // a half.
      final scales = bandHeight + gap >= labelHeight;

      // Each band's labels: its two or three round values, the outermost
      // kept when they would touch.
      final labels = <List<(double, String)>>[];
      for (var i = 0; i < count; i++) {
        final range = painters[i].valueRange(SeriesChartAxis.left);
        if (!scales || range == null) {
          labels.add(const <(double, String)>[]);
          continue;
        }
        final maxTicks = bandHeight >= labelHeight * 5 ? 3 : 2;
        var ticks = nightAxisTicks(range.$1, range.$2, maxTicks);
        if (bandHeight < labelHeight * 1.5 && ticks.length > 1) {
          ticks = <double>[ticks.last];
        }
        final decimals = ticks.length < 2
            ? 1
            : math.min(nightAxisDecimals(ticks[1] - ticks[0]), 2);
        final strip = strips[i];
        final kept = <(double, String)>[];
        double? lastY;
        for (final t in ticks.reversed) {
          final y = painters[i].yOf(t, SeriesChartAxis.left, bandHeight);
          if (y == null) continue;
          if (lastY != null && (y - lastY).abs() < labelHeight + 1) continue;
          kept.add((
            t,
            strip.grouped ? nightGrouped(t.round()) : nightFixed(t, decimals),
          ));
          lastY = y;
        }
        labels.add(kept);
      }

      var leftWidth = 0.0;
      for (final band in labels) {
        for (final (_, text) in band) {
          leftWidth = math.max(leftWidth, textWidth(text, style));
        }
      }
      leftWidth = leftWidth == 0 ? 0 : leftWidth.ceilToDouble() + 3;
      var rightWidth = 0.0;
      if (scales) {
        for (final strip in strips) {
          rightWidth = math.max(rightWidth, textWidth(strip.unit, style));
        }
        rightWidth = rightWidth == 0 ? 0 : rightWidth.ceilToDouble() + 4;
      }
      final plotWidth = constraints.maxWidth - leftWidth - rightWidth;
      final range = painters.last.timeRange;
      final clockWidth = textWidth('00:00', style).ceilToDouble() + 9;
      final timeTicks = range == null || plotWidth <= 0
          ? const <DateTime>[]
          : nightTimeTicks(
              DateTime.fromMillisecondsSinceEpoch(range.$1),
              DateTime.fromMillisecondsSinceEpoch(range.$2),
              (plotWidth / clockWidth).floor(),
            );

      Widget band(int i) {
        final strip = strips[i];
        final chart = SeriesChart(
          lines: strip.lines,
          markers: markers,
          from: from,
          to: to,
          height: math.max(0, bandHeight),
          semanticLabel: semanticLabel,
        );
        return SizedBox(
          height: math.max(0, bandHeight),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (leftWidth > 0)
                SizedBox(
                  width: leftWidth,
                  child: ExcludeSemantics(
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: <Widget>[
                        for (final (value, text) in labels[i])
                          Positioned(
                            left: 0,
                            right: 3,
                            top: ((painters[i].yOf(
                                          value,
                                          SeriesChartAxis.left,
                                          bandHeight,
                                        ) ??
                                        0) -
                                    labelHeight / 2)
                                .clamp(
                              0.0,
                              math.max(0.0, bandHeight - labelHeight),
                            ),
                            child: Text(
                              text,
                              style: style,
                              maxLines: 1,
                              softWrap: false,
                              textAlign: TextAlign.right,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              Expanded(
                child: CustomPaint(
                  painter: _GridPainter(
                    painter: painters[i],
                    yTicks: <double>[for (final (v, _) in labels[i]) v],
                    timeTicks: i == count - 1 ? timeTicks : const <DateTime>[],
                    line: colors.border,
                  ),
                  // One sentence for the whole stack, on the first band.
                  child: i == 0 ? chart : ExcludeSemantics(child: chart),
                ),
              ),
              if (rightWidth > 0)
                SizedBox(
                  width: rightWidth,
                  child: ExcludeSemantics(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Text(
                          strip.unit,
                          style: style.copyWith(
                            color: SeriesChart.colorFor(strip.unitTone, colors),
                          ),
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      }

      return Semantics(
        container: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (var i = 0; i < count; i++) ...<Widget>[
              if (i > 0) const SizedBox(height: gap),
              band(i),
            ],
            SizedBox(
              height: timeHeight,
              child: Padding(
                padding: EdgeInsets.only(left: leftWidth, right: rightWidth),
                child: ExcludeSemantics(
                  child: _TimeScale(
                    painter: painters.last,
                    ticks: timeTicks,
                    width: math.max(0, plotWidth),
                    labelWidth: clockWidth,
                    style: style,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    });
  }
}
