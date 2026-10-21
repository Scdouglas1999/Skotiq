// The pass view's charts. Each one draws its own value scale and its x scale
// with a unit, in the 9 px mono the Tonight charts use, and says in its
// semantics label what it shows.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'pass_view_model.dart';

/// The color a filter lane draws in.
Color passFilterColor(String filter, SkotiqColors colors) =>
    switch (filter.toUpperCase()) {
      'R' => SkotiqChartColors.forTheme(SkotiqChartColors.seriesRed, colors),
      'G' => SkotiqChartColors.forTheme(SkotiqChartColors.seriesGreen, colors),
      'B' => SkotiqChartColors.forTheme(SkotiqChartColors.seriesBlue, colors),
      'HA' ||
      'SII' ||
      'OIII' =>
        SkotiqChartColors.forTheme(SkotiqChartColors.seriesAmber, colors),
      _ => colors.textSecondary,
    };

TextStyle passAxisStyle(SkotiqColors colors) => SkotiqTypography.monoXs
    .copyWith(fontSize: 9, height: 1, color: colors.textMuted);

/// Round values inside [lo]..[hi], at most [maxTicks] of them.
List<double> passTicks(double lo, double hi, int maxTicks) {
  if (!(hi > lo)) return <double>[lo];
  final raw = (hi - lo) / math.max(1, maxTicks - 1);
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  var step = mag * 10;
  for (final m in const <double>[1, 2, 2.5, 5, 10]) {
    if (m * mag >= raw) {
      step = m * mag;
      break;
    }
  }
  final out = <double>[];
  for (var v = (lo / step).ceil() * step; v <= hi + step * 1e-9; v += step) {
    out.add(double.parse(v.toStringAsFixed(6)));
  }
  return out.isEmpty ? <double>[lo, hi] : out;
}

/// The smallest of 1, 2, 2.5, 5 times a power of ten that is at least [v].
double passNiceCeil(double v) {
  final mag = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
  for (final m in const <double>[1, 2, 2.5, 5, 10]) {
    if (m * mag >= v - 1e-9) return m * mag;
  }
  return 10 * mag;
}

String passTickLabel(double v, double step) {
  if (step >= 1 || v == v.roundToDouble() && step >= 1) {
    return v.round().toString();
  }
  final decimals = step >= 0.1 ? 1 : (step >= 0.01 ? 2 : 3);
  return v.toStringAsFixed(decimals);
}

/// A plot frame: left value scale with its unit on top, bottom scale with its
/// unit at the right end, hairline grid at the value ticks.
class _Frame {
  _Frame({
    required this.size,
    required this.xLo,
    required this.xHi,
    required this.yLo,
    required this.yHi,
    required this.style,
    required this.leftWidth,
    this.rightWidth = 4,
  });

  final Size size;
  final double rightWidth;
  final double xLo, xHi, yLo, yHi;
  final TextStyle style;
  final double leftWidth;
  static const double bottom = 13;
  static const double top = 4;

  Rect get plot => Rect.fromLTRB(
        leftWidth,
        top,
        size.width - rightWidth,
        size.height - bottom,
      );

  double x(double v) =>
      plot.left + (v - xLo) / math.max(1e-9, xHi - xLo) * plot.width;
  double y(double v) =>
      plot.bottom - (v - yLo) / math.max(1e-9, yHi - yLo) * plot.height;

  void text(Canvas canvas, String s, Offset at,
      {TextAlign align = TextAlign.left, Color? color}) {
    final tp = TextPainter(
      text: TextSpan(
          text: s, style: color == null ? style : style.copyWith(color: color)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final dx = switch (align) {
      TextAlign.right => -tp.width,
      TextAlign.center => -tp.width / 2,
      _ => 0.0,
    };
    tp.paint(canvas, at + Offset(dx, 0));
    tp.dispose();
  }

  void axes(
    Canvas canvas, {
    required Color grid,
    required String xUnit,
    required String yUnit,
    List<double>? xTicks,
    List<double>? yTicks,
    int maxYTicks = 3,
  }) {
    final line = Paint()
      ..color = grid
      ..strokeWidth = 1;
    final yt = yTicks ?? passTicks(yLo, yHi, maxYTicks);
    final ystep = yt.length > 1 ? yt[1] - yt[0] : (yHi - yLo);
    for (final v in yt) {
      final py = y(v);
      canvas.drawLine(Offset(plot.left, py), Offset(plot.right, py), line);
      text(canvas, passTickLabel(v, ystep), Offset(plot.left - 3, py - 4.5),
          align: TextAlign.right);
    }
    text(canvas, yUnit, Offset(plot.left + 3, plot.top), color: style.color);
    final xt =
        xTicks ?? passTicks(xLo, xHi, math.max(2, (plot.width / 34).floor()));
    final xstep = xt.length > 1 ? xt[1] - xt[0] : (xHi - xLo);
    var lastRight = -1e9;
    for (final v in xt) {
      final px = x(v);
      canvas.drawLine(
          Offset(px, plot.bottom), Offset(px, plot.bottom + 3), line);
      final label = passTickLabel(v, xstep);
      final w = label.length * 5.6;
      if (px - w / 2 < lastRight + 4) continue;
      lastRight = px + w / 2;
      text(canvas, label, Offset(px, plot.bottom + 4), align: TextAlign.center);
    }
    canvas.drawLine(plot.bottomLeft, plot.bottomRight, line);
    text(canvas, xUnit, Offset(plot.right + 12, plot.bottom + 4));
  }
}

/// Background noise of the running integration against the number of subs
/// in it, with the 1/sqrt(N) curve those subs should follow.
class PassNoiseChart extends StatelessWidget {
  const PassNoiseChart({
    super.key,
    required this.depths,
    required this.totalSubs,
    required this.filter,
    this.height = 120,
  });

  final List<PassDepth> depths;
  final int totalSubs;
  final String filter;
  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final label = depths.isEmpty
        ? 'Noise chart: no subs stacked yet'
        : 'Noise against subs stacked: ${depths.map((d) => '${d.depth} subs ${d.noise.toStringAsFixed(1)} ADU').join(', ')}';
    return Semantics(
      label: label,
      child: SizedBox(
        height: height,
        child: CustomPaint(
          size: Size.infinite,
          painter: _NoisePainter(
            depths: depths,
            totalSubs: totalSubs,
            colors: colors,
            line: passFilterColor(filter, colors),
          ),
        ),
      ),
    );
  }
}

class _NoisePainter extends CustomPainter {
  _NoisePainter({
    required this.depths,
    required this.totalSubs,
    required this.colors,
    required this.line,
  });

  final List<PassDepth> depths;
  final int totalSubs;
  final SkotiqColors colors;
  final Color line;

  @override
  void paint(Canvas canvas, Size size) {
    final style = passAxisStyle(colors);
    final anchor = depths.isEmpty ? null : depths.first;
    double expected(double n) => anchor!.noise * math.sqrt(anchor.depth / n);
    if (anchor == null) {
      final f = _Frame(
        size: size,
        xLo: 1,
        xHi: totalSubs.toDouble(),
        yLo: 0,
        yHi: 1,
        style: style,
        leftWidth: 24,
        rightWidth: 40,
      );
      f.axes(canvas,
          grid: colors.border,
          xUnit: 'subs',
          yUnit: 'ADU',
          yTicks: const <double>[],
          xTicks: <double>[
            1,
            for (var v = 4; v <= totalSubs; v += 4) v.toDouble()
          ]);
      f.text(canvas, 'Measured from the second stacked sub on',
          Offset(f.plot.center.dx, f.plot.center.dy - 5),
          align: TextAlign.center);
      return;
    }
    final hiY = anchor.noise * 1.12;
    final f = _Frame(
      size: size,
      xLo: 1,
      xHi: totalSubs.toDouble(),
      yLo: 0,
      yHi: hiY,
      style: style,
      leftWidth: 24,
      rightWidth: 40,
    );
    f.axes(
      canvas,
      grid: colors.border,
      xUnit: 'subs',
      yUnit: 'ADU',
      xTicks: <double>[
        1,
        for (var v = 4; v <= totalSubs; v += 4) v.toDouble(),
      ],
    );
    // The expected curve, dashed, over the whole lane.
    final dash = Paint()
      ..color = colors.textMuted
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    Offset? prev;
    for (var i = 0; i <= 60; i++) {
      final n = anchor.depth + (totalSubs - anchor.depth) * i / 60;
      final p = Offset(f.x(n), f.y(expected(n)));
      if (prev != null && i.isEven) canvas.drawLine(prev, p, dash);
      prev = p;
    }
    // Measured points joined.
    final stroke = Paint()
      ..color = line
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var i = 0; i < depths.length; i++) {
      final p = Offset(f.x(depths[i].depth.toDouble()), f.y(depths[i].noise));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, stroke);
    final dot = Paint()..color = line;
    for (final d in depths) {
      canvas.drawCircle(
          Offset(f.x(d.depth.toDouble()), f.y(d.noise)), 2.5, dot);
    }
    final last = depths.last;
    f.text(
      canvas,
      last.noise.toStringAsFixed(1),
      Offset(f.x(last.depth.toDouble()) + 5, f.y(last.noise) - 10),
      color: line,
    );
  }

  @override
  bool shouldRepaint(_NoisePainter old) =>
      old.depths != depths ||
      old.totalSubs != totalSubs ||
      old.colors != colors;
}

/// One registration offset on the scatter.
class PassOffsetPoint {
  const PassOffsetPoint(this.dx, this.dy, this.filter,
      {this.current = false, this.rejected = false});
  final double dx;
  final double dy;
  final String filter;
  final bool current;
  final bool rejected;
}

/// Every registered sub's offset onto its reference, in pixels: the dither
/// pattern the night left, one dot per sub.
class PassOffsetScatter extends StatelessWidget {
  const PassOffsetScatter({
    super.key,
    required this.points,
    this.extent,
    this.size = 150,
  });

  final List<PassOffsetPoint> points;

  /// Half the plotted range in px; fitted to the points when null.
  final double? extent;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Semantics(
      label: 'Registration offsets of ${points.length} subs, in pixels',
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter:
              _ScatterPainter(points: points, colors: colors, extent: extent),
        ),
      ),
    );
  }
}

class _ScatterPainter extends CustomPainter {
  _ScatterPainter({required this.points, required this.colors, this.extent});
  final List<PassOffsetPoint> points;
  final SkotiqColors colors;
  final double? extent;

  @override
  void paint(Canvas canvas, Size size) {
    var m = extent ?? 0;
    if (extent == null) {
      for (final p in points) {
        m = math.max(m, math.max(p.dx.abs(), p.dy.abs()));
      }
    }
    final e = passNiceCeil(math.max(m * 1.08, 2));
    final f = _Frame(
      size: size,
      xLo: -e,
      xHi: e,
      yLo: -e,
      yHi: e,
      style: passAxisStyle(colors),
      leftWidth: 24,
      rightWidth: 30,
    );
    final ticks = <double>[-e, -e / 2, 0, e / 2, e];
    f.axes(canvas,
        grid: colors.border,
        xUnit: 'px',
        yUnit: 'y',
        xTicks: <double>[-e, 0, e],
        yTicks: ticks);
    final cross = Paint()
      ..color = colors.textMuted
      ..strokeWidth = 1;
    final o = Offset(f.x(0), f.y(0));
    canvas.drawLine(o - const Offset(4, 0), o + const Offset(4, 0), cross);
    canvas.drawLine(o - const Offset(0, 4), o + const Offset(0, 4), cross);
    for (final p in points) {
      final c = Offset(f.x(p.dx), f.y(-p.dy));
      final color =
          p.rejected ? colors.error : passFilterColor(p.filter, colors);
      canvas.drawCircle(c, p.current ? 3 : 2.2, Paint()..color = color);
      if (p.current) {
        canvas.drawCircle(
          c,
          5.5,
          Paint()
            ..color = colors.primary
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_ScatterPainter old) =>
      old.points != points || old.colors != colors;
}

/// One band of [PassMetricStrips]: a measurement per sub for each lane.
class PassMetricStrip {
  const PassMetricStrip({
    required this.label,
    required this.unit,
    required this.value,
    this.decimals = 1,
  });

  final String label;
  final String unit;
  final double? Function(PassFrame frame) value;
  final int decimals;
}

/// Small multiples by sub number: one band per measurement, one line per
/// lane, the newest measured sub's value printed at the band's right, and
/// rejected subs as error-tone dots.
class PassMetricStrips extends StatelessWidget {
  const PassMetricStrips({
    super.key,
    required this.snapshot,
    required this.strips,
    this.bandHeight = 34,
  });

  final PassSnapshot snapshot;
  final List<PassMetricStrip> strips;
  final double bandHeight;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final maxSubs =
        snapshot.lanes.fold<int>(0, (m, l) => math.max(m, l.frames.length));
    return Semantics(
      label: 'Per-sub ${strips.map((s) => s.label).join(', ')} for each filter',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (var i = 0; i < strips.length; i++)
            SizedBox(
              height: bandHeight + (i == strips.length - 1 ? _Frame.bottom : 0),
              child: CustomPaint(
                painter: _StripPainter(
                  snapshot: snapshot,
                  strip: strips[i],
                  colors: colors,
                  maxSubs: maxSubs,
                  showX: i == strips.length - 1,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StripPainter extends CustomPainter {
  _StripPainter({
    required this.snapshot,
    required this.strip,
    required this.colors,
    required this.maxSubs,
    required this.showX,
  });

  final PassSnapshot snapshot;
  final PassMetricStrip strip;
  final SkotiqColors colors;
  final int maxSubs;
  final bool showX;

  static const double labelWidth = 96;
  static const double scaleWidth = 30;

  @override
  void paint(Canvas canvas, Size size) {
    final style = passAxisStyle(colors);
    // Range over every measured value of every lane.
    var lo = double.infinity, hi = -double.infinity;
    for (final lane in snapshot.lanes) {
      for (final f in lane.frames) {
        if (!snapshot.measured(lane, f)) continue;
        final v = strip.value(f);
        if (v == null) continue;
        lo = math.min(lo, v);
        hi = math.max(hi, v);
      }
    }
    final has = lo.isFinite;
    if (!has) {
      lo = 0;
      hi = 1;
    }
    if (hi - lo < 1e-9) {
      hi = lo + 1;
    }
    final pad = (hi - lo) * 0.12;
    final plot = Rect.fromLTRB(
      labelWidth + scaleWidth,
      3,
      size.width - 4,
      size.height - (showX ? _Frame.bottom : 0) - 3,
    );
    double x(int index) =>
        plot.left + (index - 1) / math.max(1, maxSubs - 1) * plot.width;
    double y(double v) =>
        plot.bottom -
        (v - (lo - pad)) / ((hi + pad) - (lo - pad)) * plot.height;

    void text(String s, Offset at,
        {TextAlign align = TextAlign.left, TextStyle? st}) {
      final tp = TextPainter(
        text: TextSpan(text: s, style: st ?? style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: 200);
      final dx = align == TextAlign.right
          ? -tp.width
          : (align == TextAlign.center ? -tp.width / 2 : 0.0);
      tp.paint(canvas, at + Offset(dx, 0));
      tp.dispose();
    }

    final grid = Paint()
      ..color = colors.border
      ..strokeWidth = 1;
    canvas.drawRect(plot, Paint()..color = colors.well);
    text(
      strip.unit.isEmpty ? strip.label : '${strip.label}, ${strip.unit}',
      Offset(0, plot.center.dy - 6),
      st: SkotiqTypography.captionSm.copyWith(color: colors.textSecondary),
    );
    if (has) {
      final topLabel = hi.toStringAsFixed(strip.decimals);
      final botLabel = lo.toStringAsFixed(strip.decimals);
      text(topLabel, Offset(plot.left - 3, y(hi) - 4.5),
          align: TextAlign.right);
      text(botLabel, Offset(plot.left - 3, y(lo) - 4.5),
          align: TextAlign.right);
      canvas.drawLine(
          Offset(plot.left, y(hi)), Offset(plot.right, y(hi)), grid);
      canvas.drawLine(
          Offset(plot.left, y(lo)), Offset(plot.right, y(lo)), grid);
    }
    for (final lane in snapshot.lanes) {
      final color = passFilterColor(lane.filter, colors);
      final path = Path();
      var started = false;
      for (final f in lane.frames) {
        if (!snapshot.measured(lane, f)) break;
        final v = strip.value(f);
        if (v == null) {
          started = false;
          continue;
        }
        final p = Offset(x(f.index), y(v));
        if (!started) {
          path.moveTo(p.dx, p.dy);
          started = true;
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = 1.2
          ..style = PaintingStyle.stroke,
      );
      for (final f in lane.frames) {
        if (!snapshot.measured(lane, f)) break;
        final v = strip.value(f);
        if (v == null) continue;
        if (!f.accepted) {
          canvas.drawCircle(
              Offset(x(f.index), y(v)), 2.6, Paint()..color = colors.error);
        }
      }
    }
    if (showX) {
      final ticks = <int>[1, for (var i = 4; i <= maxSubs; i += 4) i];
      for (final t in ticks) {
        final px = x(t);
        canvas.drawLine(
            Offset(px, plot.bottom), Offset(px, plot.bottom + 3), grid);
        text('$t', Offset(px, plot.bottom + 5), align: TextAlign.center);
      }
      text('sub', Offset(plot.left - 12, plot.bottom + 5),
          align: TextAlign.right);
    }
  }

  @override
  bool shouldRepaint(_StripPainter old) =>
      old.snapshot != snapshot || old.colors != colors;
}
