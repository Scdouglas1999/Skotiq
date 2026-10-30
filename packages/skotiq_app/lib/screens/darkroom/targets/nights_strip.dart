import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'darkroom_targets_model.dart';

/// Nights shown before the rest are folded behind a button.
const int darkroomNightsShown = 5;

const double _dateColumn = 116;
const double _keptColumn = 130;
const double _rowHeight = 30;
const double _tickWidth = 2;
const double _tickInset = 4;
const double _pauseInset = 8;

/// Opacity of a kept sub, and of a rejected or off-target one.
const double _keptOpacity = .92;
const double _dimOpacity = .22;

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];
const _weekdays = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', //
  'Sunday',
];

/// `Oct 23 to 24`, or `Oct 31 to Nov 1` across a month end.
String darkroomNightLabel(DateTime evening) {
  final next = DateTime(evening.year, evening.month, evening.day + 1);
  final start = '${_months[evening.month - 1]} ${evening.day}';
  return next.month == evening.month
      ? '$start to ${next.day}'
      : '$start to ${_months[next.month - 1]} ${next.day}';
}

String darkroomWeekday(DateTime day) => _weekdays[day.weekday - 1];

/// `Oct 22`.
String darkroomShortDate(DateTime day) {
  final l = day.toLocal();
  return '${_months[l.month - 1]} ${l.day}';
}

/// The color a filter's subs are drawn in.
Color darkroomFilterColor(String filter, SkotiqColors colors) {
  final series = switch (filter.toUpperCase()) {
    'L' || 'NOFILTER' => null,
    'R' => SkotiqChartColors.seriesRed,
    'G' => SkotiqChartColors.seriesGreen,
    'B' => SkotiqChartColors.seriesBlue,
    'HA' => SkotiqChartColors.seriesOrange,
    'OIII' => SkotiqChartColors.seriesDeepBlue,
    'SII' => SkotiqChartColors.seriesAmber,
    _ => SkotiqChartColors.seriesViolet,
  };
  return series == null
      ? colors.textPrimary
      : SkotiqChartColors.forTheme(series, colors);
}

/// The hours after the evening's midnight the strip spans, shared by every
/// night: from the earliest first sub to the latest last sub, on even hours,
/// inside noon to noon and at least six hours wide.
(double, double) darkroomNightAxis(List<DarkroomNight> nights) {
  if (nights.isEmpty) return (18, 30);
  var lo = double.infinity, hi = -double.infinity;
  for (final n in nights) {
    lo = math.min(lo, _hoursAfter(n, n.first));
    hi = math.max(hi, _hoursAfter(n, n.last));
  }
  lo = (lo / 2).floorToDouble() * 2;
  hi = (hi / 2).ceilToDouble() * 2;
  lo = lo.clamp(12, 36);
  hi = hi.clamp(12, 36);
  if (hi - lo < 6) {
    final mid = (lo + hi) / 2;
    lo = (mid - 3).clamp(12, 30);
    hi = lo + 6;
  }
  return (lo, hi);
}

double _hoursAfter(DarkroomNight night, DateTime t) =>
    t.toLocal().difference(night.evening).inMilliseconds / 3600000;

/// Every sub of every night as a tick colored by filter, on a shared
/// clock-time axis. Pauses are hatched, rejected and off-target subs dimmed,
/// and flips and star losses marked.
class DarkroomNightsStrip extends StatefulWidget {
  const DarkroomNightsStrip({super.key, required this.nights});

  /// Newest first.
  final List<DarkroomNight> nights;

  @override
  State<DarkroomNightsStrip> createState() => _DarkroomNightsStripState();
}

class _DarkroomNightsStripState extends State<DarkroomNightsStrip> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final nights = widget.nights;
    final shown = _all ? nights : nights.take(darkroomNightsShown).toList();
    final (lo, hi) = darkroomNightAxis(nights);
    final step = hi - lo > 10 ? 2.0 : 1.0;
    final axisStyle = SkotiqTypography.monoXs.copyWith(color: colors.textMuted);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final night in shown) _NightRow(night: night, lo: lo, hi: hi),
        Padding(
          padding: const EdgeInsets.only(top: SkotiqTokens.spaceSm),
          child: Row(
            children: [
              SizedBox(
                width: _dateColumn,
                child: Text('Local time', style: axisStyle),
              ),
              const SizedBox(width: SkotiqTokens.spaceLg),
              Expanded(
                child: SizedBox(
                  height: 14,
                  child: CustomPaint(
                    painter: _AxisPainter(
                      lo: lo,
                      hi: hi,
                      step: step,
                      style: axisStyle,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceLg),
              const SizedBox(width: _keptColumn),
            ],
          ),
        ),
        if (nights.length > darkroomNightsShown)
          Align(
            alignment: Alignment.centerLeft,
            child: SkotiqButton(
              label: _all
                  ? 'Show the latest $darkroomNightsShown nights'
                  : 'Show all ${nights.length} nights',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () => setState(() => _all = !_all),
            ),
          ),
      ],
    );
  }
}

class _NightRow extends StatelessWidget {
  const _NightRow({required this.night, required this.lo, required this.hi});

  final DarkroomNight night;
  final double lo;
  final double hi;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final kept =
        night.use == DarkroomNightUse.all ? 'in masters' : '${night.kept} kept';
    final aria = [
      darkroomNightLabel(night.evening),
      '${night.subs.length} subs from ${hhmm(night.first)} to '
          '${hhmm(night.last)}',
      '${night.kept} kept',
      if (night.offTarget > 0) '${night.offTarget} off target',
      if (night.pauses.isNotEmpty)
        '${night.pauses.length} pause${night.pauses.length == 1 ? '' : 's'}',
      for (final m in night.marks) '${m.label} at ${hhmm(m.at)}',
      if (night.use == DarkroomNightUse.all) 'all in the current masters',
    ].join(', ');
    return Container(
      padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: _dateColumn,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  darkroomNightLabel(night.evening),
                  style: SkotiqTypography.labelStrong.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                Text(
                  darkroomWeekday(night.evening),
                  style: SkotiqTypography.captionSm.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceLg),
          Expanded(
            child: Semantics(
              label: aria,
              image: true,
              child: SizedBox(
                height: _rowHeight,
                child: CustomPaint(
                  painter: _NightPainter(
                    night: night,
                    lo: lo,
                    hi: hi,
                    colors: colors,
                    markStyle: SkotiqTypography.monoXs.copyWith(
                      color: colors.brandWarm,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceLg),
          SizedBox(
            width: _keptColumn,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  kept,
                  style: SkotiqTypography.readoutSm.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                Text(
                  night.use == DarkroomNightUse.none
                      ? night.note
                      : (night.used < night.kept
                          ? '${night.used} of ${night.kept} used'
                          : night.note),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SkotiqTypography.captionSm.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NightPainter extends CustomPainter {
  _NightPainter({
    required this.night,
    required this.lo,
    required this.hi,
    required this.colors,
    required this.markStyle,
  });

  final DarkroomNight night;
  final double lo;
  final double hi;
  final SkotiqColors colors;
  final TextStyle markStyle;

  double _x(DateTime t, Size size) =>
      (_hoursAfter(night, t) - lo) / (hi - lo) * size.width;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      Paint()
        ..color = colors.border
        ..strokeWidth = 1,
    );
    final hatch = Paint()
      ..color = colors.borderHighlight
      ..strokeWidth = 1.2;
    for (final p in night.pauses) {
      final rect = Rect.fromLTRB(
        _x(p.start, size),
        _pauseInset,
        _x(p.end, size),
        size.height - _pauseInset,
      );
      canvas.save();
      canvas.clipRect(rect);
      for (var x = rect.left - rect.height; x < rect.right; x += 5) {
        canvas.drawLine(
          Offset(x, rect.bottom),
          Offset(x + rect.height, rect.top),
          hatch,
        );
      }
      canvas.restore();
    }
    for (final s in night.subs) {
      final x = _x(s.time, size);
      final dim = !s.kept || s.offTarget;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            x - _tickWidth / 2,
            _tickInset,
            _tickWidth,
            size.height - 2 * _tickInset,
          ),
          const Radius.circular(SkotiqTokens.radiusXs),
        ),
        Paint()
          ..color = darkroomFilterColor(s.filter, colors)
              .withValues(alpha: dim ? _dimOpacity : _keptOpacity),
      );
    }
    final markPaint = Paint()
      ..color = colors.brandWarm
      ..strokeWidth = 1;
    for (final m in night.marks) {
      final x = _x(m.at, size);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), markPaint);
      final tp = TextPainter(
        text: TextSpan(text: m.label, style: markStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x + 4, -1));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_NightPainter old) =>
      old.night != night ||
      old.lo != lo ||
      old.hi != hi ||
      old.colors != colors;
}

class _AxisPainter extends CustomPainter {
  _AxisPainter({
    required this.lo,
    required this.hi,
    required this.step,
    required this.style,
  });

  final double lo;
  final double hi;
  final double step;
  final TextStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    for (var h = lo; h <= hi + 1e-9; h += step) {
      final x = (h - lo) / (hi - lo) * size.width;
      final label = '${two(h.round() % 24)}:00';
      final tp = TextPainter(
        text: TextSpan(text: label, style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      final left = (x - tp.width / 2).clamp(0.0, size.width - tp.width);
      tp.paint(canvas, Offset(left, 0));
    }
  }

  @override
  bool shouldRepaint(_AxisPainter old) =>
      old.lo != lo || old.hi != hi || old.step != step || old.style != style;
}
