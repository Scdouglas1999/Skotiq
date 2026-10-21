// The pass view's chart helpers and its noise chart. Every scale is fitted to
// the data it shows, so nothing here assumes a star size or a noise level.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'package:skotiq_core/skotiq_core.dart' show PassDepth;

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
        : 'Noise against subs stacked: ${depths.where((d) => d.noise != null).map((d) => '${d.depth} subs ${d.noise!.toStringAsFixed(1)} ADU').join(', ')}';
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
    final measured = <PassDepth>[
      for (final d in depths)
        if (d.noise != null && d.noise! > 0) d,
    ];
    final anchor = measured.isEmpty ? null : measured.first;
    double expected(double n) => anchor!.noise! * math.sqrt(anchor.depth / n);
    final xTicks = <double>[
      1,
      for (final t in passTicks(1, totalSubs.toDouble(), 5))
        if (t > 1.5) t,
    ];
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
          xTicks: xTicks);
      f.text(canvas, 'Measured as each sub is stacked',
          Offset(f.plot.center.dx, f.plot.center.dy - 5),
          align: TextAlign.center);
      return;
    }
    var hiY = 0.0;
    for (final d in measured) {
      hiY = math.max(hiY, d.noise!);
    }
    hiY *= 1.12;
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
      xTicks: xTicks,
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
    for (var i = 0; i < measured.length; i++) {
      final p =
          Offset(f.x(measured[i].depth.toDouble()), f.y(measured[i].noise!));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, stroke);
    // One dot per sub reads as a line once there are many.
    final dot = Paint()..color = line;
    final radius = measured.length > 24 ? 1.5 : 2.5;
    for (final d in measured) {
      canvas.drawCircle(
          Offset(f.x(d.depth.toDouble()), f.y(d.noise!)), radius, dot);
    }
    final last = measured.last;
    f.text(
      canvas,
      last.noise!.toStringAsFixed(1),
      Offset(
        math.min(f.x(last.depth.toDouble()) + 5, f.plot.right - 24),
        f.y(last.noise!) - 12,
      ),
      color: line,
    );
  }

  @override
  bool shouldRepaint(_NoisePainter old) =>
      old.depths != depths ||
      old.totalSubs != totalSubs ||
      old.colors != colors;
}
