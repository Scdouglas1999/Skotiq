import 'dart:ui' show PathMetric;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/skotiq_colors.dart';

/// A [SeriesChart] line, marker or highlight color, as a role. The chart
/// resolves it against the active palette, so a caller never passes a color.
enum SeriesChartTone { primary, secondary, tertiary, muted, warning, error }

/// Which vertical scale a line or highlight is drawn against.
enum SeriesChartAxis { left, right }

/// One line on a [SeriesChart].
@immutable
class SeriesChartLine {
  const SeriesChartLine({
    required this.points,
    required this.tone,
    this.axis = SeriesChartAxis.left,
    this.dashed = false,
    this.stepped = false,
    this.minY,
    this.maxY,
  });

  /// The samples in time order. A null y is a gap: the line breaks there
  /// rather than bridging, so a missing reading never draws as a value.
  final List<(DateTime, double?)> points;

  final SeriesChartTone tone;
  final SeriesChartAxis axis;

  /// Drawn as dashes, for a reference series such as a setpoint.
  final bool dashed;

  /// Drawn as steps (hold the value, then jump), for a series that changes
  /// in discrete moves such as a focuser position.
  final bool stepped;

  /// A fixed range for this line's axis. Null fits the data. When several
  /// lines on one axis fix a bound, the widest fixed bound wins; data outside
  /// a fixed range is clipped at the chart's edge.
  final double? minY;
  final double? maxY;

  @override
  bool operator ==(Object other) =>
      other is SeriesChartLine &&
      other.tone == tone &&
      other.axis == axis &&
      other.dashed == dashed &&
      other.stepped == stepped &&
      other.minY == minY &&
      other.maxY == maxY &&
      listEquals(other.points, points);

  @override
  int get hashCode => Object.hash(
    tone,
    axis,
    dashed,
    stepped,
    minY,
    maxY,
    Object.hashAll(points),
  );
}

/// A dashed vertical at one moment: an autofocus run, a dither.
@immutable
class SeriesChartMarker {
  const SeriesChartMarker(this.at, {this.tone = SeriesChartTone.muted});

  final DateTime at;
  final SeriesChartTone tone;

  @override
  bool operator ==(Object other) =>
      other is SeriesChartMarker && other.at == at && other.tone == tone;

  @override
  int get hashCode => Object.hash(at, tone);
}

/// A dot on one point, e.g. a rejected frame.
@immutable
class SeriesChartHighlight {
  const SeriesChartHighlight(
    this.at,
    this.y, {
    this.axis = SeriesChartAxis.left,
    this.tone = SeriesChartTone.error,
  });

  final DateTime at;
  final double y;
  final SeriesChartAxis axis;
  final SeriesChartTone tone;

  @override
  bool operator ==(Object other) =>
      other is SeriesChartHighlight &&
      other.at == at &&
      other.y == y &&
      other.axis == axis &&
      other.tone == tone;

  @override
  int get hashCode => Object.hash(at, y, axis, tone);
}

/// Up to three line series against time, for the small charts under the
/// Tonight frame (HFR and stars, guide error, temperature and focus).
///
/// It has no axis chrome: no ticks, no grid, no numbers. The caption beside
/// the chart carries the values, so the plot only has to carry the shape. A
/// null y is a gap, [markers] are dashed verticals, [highlights] are dots,
/// and a line on [SeriesChartAxis.right] gets its own vertical scale.
///
/// The chart fills the width it is given and is [height] tall.
class SeriesChart extends StatelessWidget {
  const SeriesChart({
    super.key,
    required this.lines,
    this.markers = const <SeriesChartMarker>[],
    this.highlights = const <SeriesChartHighlight>[],
    this.from,
    this.to,
    this.zeroLineY,
    this.height = 70,
    required this.semanticLabel,
  }) : assert(lines.length <= maxLines, 'SeriesChart draws at most 3 lines');

  /// The lines, painted in order (the first one lowest).
  final List<SeriesChartLine> lines;

  final List<SeriesChartMarker> markers;
  final List<SeriesChartHighlight> highlights;

  /// The time range. Null fits the lines' data.
  final DateTime? from;
  final DateTime? to;

  /// A horizontal reference on the left axis, e.g. zero guide error.
  final double? zeroLineY;

  final double height;

  /// One sentence that says what the chart shows, built from the same data.
  final String semanticLabel;

  /// The most lines one chart draws.
  static const int maxLines = 3;

  /// A line's stroke width.
  static const double strokeWidth = 1.5;

  /// A marker's stroke width.
  static const double markerWidth = 1;

  /// Dash and gap for markers and dashed lines.
  static const double dashLength = 3;
  static const double dashGap = 3;

  /// A highlight's radius. A point standing alone between two gaps is drawn
  /// as a dot of [strokeWidth] instead, so it does not vanish.
  static const double highlightRadius = 2.5;

  /// Space kept free above and below the data, so a stroke or a dot at the
  /// extreme is not cut in half by the edge.
  static const double verticalInset = highlightRadius + 0.5;

  /// The resolved color of [tone] on [colors]. Public so the contrast test
  /// measures what the painter draws.
  ///
  /// Red night has one hue, so lines there differ by lightness alone. `info`
  /// and `error` sit at nearly the same lightness in that palette and drew
  /// the guide chart's RA and Dec as one red scribble, so the tertiary line
  /// takes the palest text red instead.
  static Color colorFor(SeriesChartTone tone, SkotiqColors colors) =>
      switch (tone) {
        SeriesChartTone.tertiary when colors.isRedNight => colors.textPrimary,
        SeriesChartTone.primary => colors.primary,
        SeriesChartTone.secondary => colors.brandWarm,
        SeriesChartTone.tertiary => colors.info,
        SeriesChartTone.muted => colors.textMuted,
        SeriesChartTone.warning => colors.warning,
        SeriesChartTone.error => colors.error,
      };

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Semantics(
      container: true,
      label: semanticLabel,
      child: RepaintBoundary(
        child: SizedBox(
          width: double.infinity,
          height: height,
          child: CustomPaint(
            painter: SeriesChartPainter(
              colors: colors,
              lines: lines,
              markers: markers,
              highlights: highlights,
              from: from,
              to: to,
              zeroLineY: zeroLineY,
            ),
          ),
        ),
      ),
    );
  }
}

/// The painter behind [SeriesChart]. Public for its scale helpers, which the
/// tests use to check where a point lands.
class SeriesChartPainter extends CustomPainter {
  SeriesChartPainter({
    required this.colors,
    required this.lines,
    required this.markers,
    required this.highlights,
    required this.from,
    required this.to,
    required this.zeroLineY,
  });

  final SkotiqColors colors;
  final List<SeriesChartLine> lines;
  final List<SeriesChartMarker> markers;
  final List<SeriesChartHighlight> highlights;
  final DateTime? from;
  final DateTime? to;
  final double? zeroLineY;

  /// The time range drawn, in milliseconds since the epoch, or null when
  /// there is nothing to place on it.
  late final (int, int)? timeRange = _timeRange();

  late final (double, double)? _leftRange = _valueRange(SeriesChartAxis.left);
  late final (double, double)? _rightRange = _valueRange(SeriesChartAxis.right);

  /// The value range of [axis], or null when no line, highlight or center
  /// line uses it.
  (double, double)? valueRange(SeriesChartAxis axis) => switch (axis) {
    SeriesChartAxis.left => _leftRange,
    SeriesChartAxis.right => _rightRange,
  };

  (int, int)? _timeRange() {
    var lo = from?.millisecondsSinceEpoch;
    var hi = to?.millisecondsSinceEpoch;
    if (lo == null || hi == null) {
      int? dataLo;
      int? dataHi;
      for (final line in lines) {
        for (final point in line.points) {
          final t = point.$1.millisecondsSinceEpoch;
          if (dataLo == null || t < dataLo) dataLo = t;
          if (dataHi == null || t > dataHi) dataHi = t;
        }
      }
      lo ??= dataLo;
      hi ??= dataHi;
    }
    if (lo == null || hi == null) return null;
    return (lo, hi);
  }

  (double, double)? _valueRange(SeriesChartAxis axis) {
    double? fixedLo;
    double? fixedHi;
    double? dataLo;
    double? dataHi;
    void take(double y) {
      if (!y.isFinite) return;
      if (dataLo == null || y < dataLo!) dataLo = y;
      if (dataHi == null || y > dataHi!) dataHi = y;
    }

    for (final line in lines) {
      if (line.axis != axis) continue;
      final lineLo = line.minY;
      final lineHi = line.maxY;
      if (lineLo != null && (fixedLo == null || lineLo < fixedLo)) {
        fixedLo = lineLo;
      }
      if (lineHi != null && (fixedHi == null || lineHi > fixedHi)) {
        fixedHi = lineHi;
      }
      for (final point in line.points) {
        final y = point.$2;
        if (y != null) take(y);
      }
    }
    for (final highlight in highlights) {
      if (highlight.axis == axis) take(highlight.y);
    }
    if (axis == SeriesChartAxis.left && zeroLineY != null) take(zeroLineY!);

    final lo = fixedLo ?? dataLo;
    final hi = fixedHi ?? dataHi;
    if (lo == null || hi == null) return null;
    if (hi > lo) return (lo, hi);
    // A flat series sits in the middle rather than on an edge.
    final pad = lo == 0 ? 1.0 : lo.abs() * 0.1;
    return (lo - pad, hi + pad);
  }

  /// The x of [t] in a chart [width] wide, or null with no time range.
  double? xOf(DateTime t, double width) {
    final range = timeRange;
    if (range == null) return null;
    final span = range.$2 - range.$1;
    if (span <= 0) return width / 2;
    return (t.millisecondsSinceEpoch - range.$1) / span * width;
  }

  /// The y of [value] on [axis] in a chart [height] tall, or null when the
  /// axis has no range.
  double? yOf(double value, SeriesChartAxis axis, double height) {
    final range = valueRange(axis);
    if (range == null) return null;
    final usable = height - 2 * SeriesChart.verticalInset;
    final f = (value - range.$1) / (range.$2 - range.$1);
    return SeriesChart.verticalInset + (1 - f) * usable;
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    final zero = zeroLineY;
    if (zero != null) {
      final y = yOf(zero, SeriesChartAxis.left, size.height);
      if (y != null) {
        canvas.drawLine(
          Offset(0, y),
          Offset(size.width, y),
          Paint()
            ..color = colors.borderHighlight
            ..strokeWidth = 1,
        );
      }
    }

    for (final marker in markers) {
      final x = xOf(marker.at, size.width);
      if (x == null || x < 0 || x > size.width) continue;
      _drawDashed(
        canvas,
        Path()
          ..moveTo(x, 0)
          ..lineTo(x, size.height),
        Paint()
          ..color = SeriesChart.colorFor(marker.tone, colors)
          ..strokeWidth = SeriesChart.markerWidth
          ..style = PaintingStyle.stroke,
      );
    }

    for (final line in lines) {
      _paintLine(canvas, size, line);
    }

    for (final highlight in highlights) {
      final x = xOf(highlight.at, size.width);
      final y = yOf(highlight.y, highlight.axis, size.height);
      if (x == null || y == null) continue;
      canvas.drawCircle(
        Offset(x, y),
        SeriesChart.highlightRadius,
        Paint()..color = SeriesChart.colorFor(highlight.tone, colors),
      );
    }

    canvas.restore();
  }

  void _paintLine(Canvas canvas, Size size, SeriesChartLine line) {
    final color = SeriesChart.colorFor(line.tone, colors);
    final stroke = Paint()
      ..color = color
      ..strokeWidth = SeriesChart.strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final dot = Paint()..color = color;

    // Each run of non-null points becomes one subpath; a null ends the run.
    final path = Path();
    var runLength = 0;
    Offset? previous;
    void endRun() {
      if (runLength == 1 && previous != null) {
        canvas.drawCircle(previous!, SeriesChart.strokeWidth, dot);
      }
      runLength = 0;
      previous = null;
    }

    for (final point in line.points) {
      final value = point.$2;
      if (value == null || !value.isFinite) {
        endRun();
        continue;
      }
      final x = xOf(point.$1, size.width);
      final y = yOf(value, line.axis, size.height);
      if (x == null || y == null) continue;
      final here = Offset(x, y);
      final last = previous;
      if (last == null) {
        path.moveTo(x, y);
      } else {
        if (line.stepped) path.lineTo(x, last.dy);
        path.lineTo(x, y);
      }
      previous = here;
      runLength++;
    }
    endRun();

    if (line.dashed) {
      _drawDashed(canvas, path, stroke);
    } else {
      canvas.drawPath(path, stroke);
    }
  }

  static void _drawDashed(Canvas canvas, Path path, Paint paint) {
    for (final PathMetric metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = distance + SeriesChart.dashLength;
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance = end + SeriesChart.dashGap;
      }
    }
  }

  @override
  bool shouldRepaint(SeriesChartPainter oldDelegate) =>
      oldDelegate.colors != colors ||
      oldDelegate.from != from ||
      oldDelegate.to != to ||
      oldDelegate.zeroLineY != zeroLineY ||
      !listEquals(oldDelegate.lines, lines) ||
      !listEquals(oldDelegate.markers, markers) ||
      !listEquals(oldDelegate.highlights, highlights);
}
