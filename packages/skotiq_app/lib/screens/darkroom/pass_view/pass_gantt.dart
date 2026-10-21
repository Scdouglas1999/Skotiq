// The pass on its own clock: one row per filter lane and one for the color
// stages, each stage a block from where it started to where it ended or is
// estimated to end. Finished subs are the hairline cuts inside a block, so a
// block fills in one sub at a time.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'pass_view_charts.dart';

class PassGantt extends StatelessWidget {
  const PassGantt({
    super.key,
    required this.snapshot,
    this.rowHeight = 22,
    this.rowGap = 6,
    this.labelWidth = 44,
    this.showStageLabels = true,
  });

  final PassSnapshot snapshot;
  final double rowHeight;
  final double rowGap;
  final double labelWidth;
  final bool showStageLabels;

  bool get _afterRow => snapshot.timeline.colorSpans.isNotEmpty;

  int get _rows => snapshot.lanes.length + (_afterRow ? 1 : 0);

  double get height => _rows * rowHeight + (_rows - 1) * rowGap + 30;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final (remaining, complete) = snapshot.remaining;
    return Semantics(
      label: 'Pass timeline. ${passClockWords(snapshot.elapsed)} elapsed, '
          '${complete ? '' : 'at least '}${passClockWords(remaining)} remaining.',
      child: SizedBox(
        height: height,
        child: CustomPaint(
          size: Size.infinite,
          painter: _GanttPainter(
            snapshot: snapshot,
            schedule: snapshot.schedule,
            colors: colors,
            rowHeight: rowHeight,
            rowGap: rowGap,
            labelWidth: labelWidth,
            showStageLabels: showStageLabels,
          ),
        ),
      ),
    );
  }
}

String passClockWords(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds.remainder(60);
  return m > 0 ? '$m min $s s' : '$s s';
}

class _GanttPainter extends CustomPainter {
  _GanttPainter({
    required this.snapshot,
    required this.schedule,
    required this.colors,
    required this.rowHeight,
    required this.rowGap,
    required this.labelWidth,
    required this.showStageLabels,
  });

  final PassSnapshot snapshot;
  final List<PassScheduledSpan> schedule;
  final SkotiqColors colors;
  final double rowHeight;
  final double rowGap;
  final double labelWidth;
  final bool showStageLabels;

  static const double topPad = 14;

  void _text(Canvas canvas, String s, Offset at, TextStyle style,
      {TextAlign align = TextAlign.left, double? maxWidth}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: maxWidth == null ? null : '',
    )..layout(maxWidth: maxWidth ?? double.infinity);
    final dx = switch (align) {
      TextAlign.right => -tp.width,
      TextAlign.center => -tp.width / 2,
      _ => 0.0,
    };
    tp.paint(canvas, at + Offset(dx, 0));
    tp.dispose();
  }

  double _width(String s, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final w = tp.width;
    tp.dispose();
    return w;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final axis = passAxisStyle(colors);
    final after = snapshot.timeline.colorSpans;
    final rowCount = snapshot.lanes.length + (after.isEmpty ? 0 : 1);
    if (rowCount == 0) return;
    var knownEnd = snapshot.elapsed;
    for (final s in schedule) {
      if (s.drawnEnd > knownEnd) knownEnd = s.drawnEnd;
    }
    final spanMs = math.max(1, knownEnd.inMilliseconds).toDouble();
    final plot = Rect.fromLTRB(
        labelWidth, topPad, size.width - 2, topPad + _rowsHeight(rowCount));
    double x(Duration d) => plot.left + d.inMilliseconds / spanMs * plot.width;

    // Clock scale and gridlines.
    final grid = Paint()
      ..color = colors.border
      ..strokeWidth = 1;
    final totalSec = spanMs / 1000;
    final step = _clockStep(totalSec, plot.width);
    for (var t = 0.0; t <= totalSec + 1e-6; t += step) {
      final px = plot.left + t / totalSec * plot.width;
      canvas.drawLine(Offset(px, plot.top), Offset(px, plot.bottom + 3), grid);
      _text(canvas, passClock(Duration(seconds: t.round())),
          Offset(px, plot.bottom + 5), axis,
          align: t == 0
              ? TextAlign.left
              : (px > plot.right - 16 ? TextAlign.right : TextAlign.center));
    }
    _text(canvas, 'm:ss', Offset(0, plot.bottom + 5), axis);

    // Row labels.
    final rows = <String?>[
      for (final l in snapshot.lanes) l.lane,
      if (after.isNotEmpty) null,
    ];
    final afterLabel = after.containsKey(PassStage.align) ||
            after.containsKey(PassStage.combine)
        ? 'Color'
        : 'Drafts';
    for (var i = 0; i < rows.length; i++) {
      final top = plot.top + i * (rowHeight + rowGap);
      final f = rows[i];
      final label = f ?? afterLabel;
      final color =
          f == null ? colors.textSecondary : passFilterColor(f, colors);
      canvas.drawRect(Rect.fromLTWH(0, top + rowHeight / 2 - 4, 8, 8),
          Paint()..color = color);
      _text(
        canvas,
        label,
        Offset(13, top + rowHeight / 2 - 6.5),
        SkotiqTypography.monoXs.copyWith(
            color: colors.textPrimary, fontWeight: FontWeight.w600, height: 1),
        maxWidth: labelWidth - 15,
      );
    }

    // Blocks.
    final ink = SkotiqTypography.monoXs.copyWith(fontSize: 9.5, height: 1);
    var stageIndex = <String?, int>{};
    for (final s in schedule) {
      if (s.state == PassStepState.notRun) continue;
      final row = s.lane == null ? rows.length - 1 : rows.indexOf(s.lane);
      if (row < 0) continue;
      final top = plot.top + row * (rowHeight + rowGap);
      final n = stageIndex[s.lane] = (stageIndex[s.lane] ?? -1) + 1;
      final base = s.failed
          ? colors.error
          : (s.lane == null
              ? colors.textSecondary
              : passFilterColor(s.lane!, colors));
      // Adjacent stages alternate two strengths of the lane color.
      final fill = base.withValues(alpha: n.isEven ? 0.92 : 0.62);
      final left = x(s.start);
      final right = x(s.drawnEnd);
      if (right - left < 0.5) continue;
      final rect = Rect.fromLTRB(
          left, top, math.max(left + 1, right - 1), top + rowHeight);

      final filledTo = switch (s.state) {
        PassStepState.done => rect.right,
        PassStepState.running => math.min(rect.right, x(snapshot.elapsed)),
        PassStepState.waiting || PassStepState.notRun => rect.left,
      };
      if (filledTo > rect.left) {
        canvas.drawRect(
            Rect.fromLTRB(rect.left, rect.top, filledTo, rect.bottom),
            Paint()..color = fill);
      }
      if (s.state != PassStepState.done) {
        final outline = Paint()
          ..color = s.state == PassStepState.running
              ? base.withValues(alpha: 0.7)
              : colors.borderHighlight
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1;
        final r = rect.deflate(0.5);
        if (s.end == null) {
          // No estimate: three sides, the right end left open and dashed.
          final path = Path()
            ..moveTo(r.right, r.top)
            ..lineTo(r.left, r.top)
            ..lineTo(r.left, r.bottom)
            ..lineTo(r.right, r.bottom);
          canvas.drawPath(path, outline);
          for (var yy = r.top; yy < r.bottom; yy += 4) {
            canvas.drawLine(Offset(r.right, yy),
                Offset(r.right, math.min(r.bottom, yy + 2)), outline);
          }
        } else {
          canvas.drawRect(r, outline);
        }
      }
      // One cut per finished sub.
      final cut = Paint()
        ..color = colors.background.withValues(alpha: 0.55)
        ..strokeWidth = 1;
      for (final t in s.ticks) {
        final px = x(t);
        if (px <= rect.left + 1 || px >= filledTo - 0.5) continue;
        canvas.drawLine(
            Offset(px, rect.top + 3), Offset(px, rect.bottom - 3), cut);
      }

      if (!showStageLabels) continue;
      final count = s.total > 0 && s.state == PassStepState.running
          ? ' ${s.done}/${s.total}'
          : '';
      final candidates = <String>[
        if (s.end == null && s.state != PassStepState.done)
          '${s.stage.label} · no timing yet',
        '${s.stage.label}$count',
        s.stage.label,
        s.stage.label.substring(0, 1),
      ];
      for (final text in candidates) {
        final onFill = s.state == PassStepState.done ||
            (s.state == PassStepState.running &&
                filledTo - rect.left > _width(text, ink) + 8);
        final style = ink.copyWith(
          color: onFill ? colors.background : colors.textSecondary,
          fontWeight: FontWeight.w600,
        );
        final w = _width(text, style);
        // Off the fill, the label starts past the filled part.
        final left = onFill || filledTo <= rect.left ? rect.left : filledTo + 2;
        if (left + w + 6 > rect.right) continue;
        // A label on the fill sits on a plate of the block's own color so the
        // sub cuts never run through the letters.
        if (onFill) {
          canvas.drawRect(
            Rect.fromLTWH(rect.left + 1, rect.top + 2, w + 6, rect.height - 4),
            Paint()..color = fill,
          );
        }
        _text(canvas, text, Offset(left + 4, rect.center.dy - 5), style);
        break;
      }
    }

    // Now; a finished record has no now.
    if (snapshot.ended) return;
    final nx = x(snapshot.elapsed);
    final now = Paint()
      ..color = colors.primary
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(nx, plot.top - 4), Offset(nx, plot.bottom + 2), now);
    _text(
      canvas,
      'now ${passClock(snapshot.elapsed)}',
      Offset(nx, 0),
      axis.copyWith(color: colors.primary),
      align: nx > plot.right - 50 ? TextAlign.right : TextAlign.center,
    );
  }

  double _rowsHeight(int rows) => rows * rowHeight + (rows - 1) * rowGap;

  static double _clockStep(double totalSec, double width) {
    final maxLabels = math.max(2, (width / 56).floor());
    for (final s in const <double>[
      5,
      10,
      15,
      30,
      60,
      120,
      300,
      600,
      900,
      1800
    ]) {
      if (totalSec / s <= maxLabels) return s;
    }
    return 3600;
  }

  @override
  bool shouldRepaint(_GanttPainter old) =>
      old.snapshot.elapsed != snapshot.elapsed || old.colors != colors;
}
