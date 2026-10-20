// The target block: name and catalog facts, a coordinates grid, and the
// altitude plot with the moon, the horizon limit, now and the flip.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show CoordinateFormat, SecondsPrecision, SexagesimalStyle;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../data/plan/night_target_provider.dart';
import '../night_control_contracts.dart';
import 'left_section_frame.dart';
import 'night_time_format.dart';

class NightTargetSection extends ConsumerWidget {
  const NightTargetSection({super.key});

  static const double chartHeight = 76;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = SkotiqLocalizations.of(context);
    final colors = context.skotiqColors;
    final target = ref.watch(nightTargetProvider);
    if (target == null) {
      return NightLeftSectionFrame(
        title: l10n.text('nightCtlTarget'),
        child: NightLeftEmpty(l10n.text('nightCtlNoTarget')),
      );
    }
    final now = nightNowOnClock(ref);
    final facts = _facts(target);

    return NightLeftSectionFrame(
      title: l10n.text('nightCtlTargetNamed', params: {'name': target.name}),
      trailing: facts == null
          ? null
          : Text(
              facts,
              style: NightLeftSectionFrame.noteStyle(colors),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _CoordinateGrid(cells: _cells(l10n, target)),
          if (target.altitudeCurve case final curve?
              when curve.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            _AltitudeChart(target: target, curve: curve, now: now),
            const SizedBox(height: SkotiqTokens.spaceXs),
            _Legend(target: target),
          ],
        ],
      ),
    );
  }

  /// "Psc · galaxy 9.9'"; null when the catalog said nothing. The prime is
  /// an apostrophe because the app's sans face has no ′ glyph.
  static String? _facts(NightTargetVm target) {
    final parts = <String>[
      if (target.constellation case final c? when c.isNotEmpty) c,
      if (target.objectType case final t? when t.isNotEmpty) t,
    ];
    final size = target.sizeArcmin;
    if (size != null) {
      final text = '${size.toStringAsFixed(size >= 10 ? 0 : 1)}\'';
      if (parts.isEmpty) {
        parts.add(text);
      } else {
        parts[parts.length - 1] = '${parts.last} $text';
      }
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  static List<(String, String?)> _cells(
    SkotiqLocalizations l10n,
    NightTargetVm target,
  ) =>
      <(String, String?)>[
        (
          l10n.text('nightCtlRa'),
          CoordinateFormat.ra(
            target.raHours,
            style: SexagesimalStyle.compactLetters,
            seconds: SecondsPrecision.integerRounded,
            wrapHours: true,
          ),
        ),
        (
          l10n.text('nightCtlDec'),
          CoordinateFormat.dec(
            target.decDegrees,
            style: SexagesimalStyle.compactLetters,
            seconds: SecondsPrecision.integerRounded,
          ).replaceFirst('-', '−'),
        ),
        (
          l10n.text('nightCtlRotation'),
          target.rotationDeg == null
              ? null
              : '${target.rotationDeg!.toStringAsFixed(1)}°',
        ),
        (
          l10n.text('nightCtlAltitude'),
          target.altitudeDeg == null
              ? null
              : '${_signed(target.altitudeDeg!, 1)}°',
        ),
        (
          l10n.text('nightCtlHourAngle'),
          target.hourAngleHours == null
              ? null
              : _hourAngle(target.hourAngleHours!),
        ),
        (
          l10n.text('nightCtlAirmass'),
          target.airmass?.toStringAsFixed(2),
        ),
      ];

  static String _signed(double value, int decimals) {
    final text = value.toStringAsFixed(decimals);
    return text.startsWith('-') ? '−${text.substring(1)}' : text;
  }

  /// `−0h59m`: negative east of the meridian.
  static String _hourAngle(double hours) {
    final minutes = (hours.abs() * 60).round();
    final sign = hours < 0 && minutes > 0 ? '−' : '';
    return '$sign${minutes ~/ 60}h${(minutes % 60).toString().padLeft(2, '0')}m';
  }
}

/// Three columns of value over label; an unknown value reads "—".
class _CoordinateGrid extends StatelessWidget {
  const _CoordinateGrid({required this.cells});

  final List<(String, String?)> cells;

  static const int columns = 3;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final rows = <Widget>[];
    for (var i = 0; i < cells.length; i += columns) {
      if (rows.isNotEmpty) {
        rows.add(const SizedBox(height: SkotiqTokens.spaceXs));
      }
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (var j = i; j < i + columns; j++) ...<Widget>[
              if (j > i) const SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(
                child: j < cells.length
                    ? _cell(cells[j], colors)
                    : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      );
    }
    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }

  Widget _cell((String, String?) cell, SkotiqColors colors) {
    final (label, value) = cell;
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // A coordinate cut short is a wrong coordinate, so a value too
          // wide for its third (large text) shrinks instead of ellipsizing.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              value ?? '—',
              style: SkotiqTypography.monoSm.copyWith(
                color: value == null ? colors.textMuted : colors.textPrimary,
              ),
              maxLines: 1,
              softWrap: false,
            ),
          ),
          Text(
            label,
            style: SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
          ),
        ],
      ),
    );
  }
}

/// Altitude across the night on a fixed 0 to 90° scale, the moon dashed,
/// the horizon limit as the center line, now and the flip as markers, with
/// degrees down the left and clock hours along the bottom.
class _AltitudeChart extends StatelessWidget {
  const _AltitudeChart({
    required this.target,
    required this.curve,
    required this.now,
  });

  final NightTargetVm target;
  final List<SeriesPoint> curve;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    List<(DateTime, double?)> points(List<SeriesPoint> series) =>
        <(DateTime, double?)>[for (final p in series) (p.t, p.y)];
    final moon = target.moonAltitudeCurve;
    final chart = SeriesChart(
      height: NightTargetSection.chartHeight,
      from: curve.first.t,
      to: curve.last.t,
      zeroLineY: target.horizonLimitDeg,
      lines: <SeriesChartLine>[
        if (moon != null && moon.isNotEmpty)
          SeriesChartLine(
            points: points(moon),
            tone: SeriesChartTone.muted,
            dashed: true,
            minY: 0,
            maxY: 90,
          ),
        SeriesChartLine(
          points: points(curve),
          tone: SeriesChartTone.primary,
          minY: 0,
          maxY: 90,
        ),
      ],
      markers: <SeriesChartMarker>[
        SeriesChartMarker(now),
        if (target.flipAt case final flip?)
          SeriesChartMarker(flip, tone: SeriesChartTone.warning),
      ],
      semanticLabel: _sentence(l10n),
    );
    return _AltitudeAxes(
      from: curve.first.t,
      to: curve.last.t,
      chart: chart,
    );
  }

  /// "M74 altitude over the night: transit 00:51 at 66 degrees, below 30
  /// degrees after 04:20; moon sets 23:09".
  String _sentence(SkotiqLocalizations l10n) {
    final limit = target.horizonLimitDeg.round().toString();
    final facts = <String>[
      if (target.transitAt case final at?)
        target.transitAltitudeDeg == null
            ? l10n.text('nightCtlAltSemTransit', params: {'time': nightHm(at)})
            : l10n.text('nightCtlAltSemTransitAt', params: {
                'time': nightHm(at),
                'deg': target.transitAltitudeDeg!.round().toString(),
              }),
      if (target.belowLimitAt case final at?)
        l10n.text('nightCtlAltSemBelow', params: {
          'deg': limit,
          'time': nightHm(at),
        }),
    ];
    final extras = <String>[
      if (target.moonSet case final at?)
        l10n.text('nightCtlAltSemMoonSet', params: {'time': nightHm(at)}),
      if (target.flipAt case final at?)
        l10n.text('nightCtlAltSemFlip', params: {'time': nightHm(at)}),
    ];
    final head = l10n.text('nightCtlAltSem', params: {'name': target.name});
    final buffer = StringBuffer(head);
    if (facts.isNotEmpty) buffer.write(': ${facts.join(', ')}');
    if (extras.isNotEmpty) buffer.write('; ${extras.join(', ')}');
    return buffer.toString();
  }
}

/// Degree labels and faint gridlines at 0, 30, 60 and 90°, and an hour
/// scale under the plot, so a point on the curve reads as a time and an
/// altitude without hovering.
class _AltitudeAxes extends StatelessWidget {
  const _AltitudeAxes({
    required this.from,
    required this.to,
    required this.chart,
  });

  final DateTime from;
  final DateTime to;
  final Widget chart;

  static const double _gutter = 24;
  static const double _scaleHeight = 13;
  static const double _labelHeight = 11;
  static const List<int> _degrees = <int>[90, 60, 30, 0];

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final style = SkotiqTypography.captionSm.copyWith(
      color: colors.textMuted,
      fontSize: 9,
      height: 1,
    );
    const height = NightTargetSection.chartHeight;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          height: height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(
                width: _gutter,
                child: ExcludeSemantics(
                  child: Stack(
                    children: <Widget>[
                      for (final deg in _degrees)
                        Positioned(
                          right: 4,
                          top: (height * (1 - deg / 90) - _labelHeight / 2)
                              .clamp(0.0, height - _labelHeight),
                          child: Text('$deg°', style: style),
                        ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: CustomPaint(
                  painter: _AltitudeGridPainter(
                    ticks: _hourTicks(from, to),
                    from: from,
                    to: to,
                    line: colors.border,
                  ),
                  child: chart,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: _scaleHeight,
          child: Padding(
            padding: const EdgeInsets.only(left: _gutter),
            child: ExcludeSemantics(
              child: LayoutBuilder(
                builder: (context, constraints) => _HourScale(
                  width: constraints.maxWidth,
                  from: from,
                  to: to,
                  style: style,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Whole hours between [from] and [to], every two hours on a long night.
List<DateTime> _hourTicks(DateTime from, DateTime to) {
  final span = to.difference(from);
  if (span.inMinutes <= 0) return const <DateTime>[];
  final step = span.inHours > 6 ? 2 : 1;
  var t = DateTime(from.year, from.month, from.day, from.hour)
      .add(const Duration(hours: 1));
  while (t.hour % step != 0) {
    t = t.add(const Duration(hours: 1));
  }
  final ticks = <DateTime>[];
  for (; !t.isAfter(to); t = t.add(Duration(hours: step))) {
    ticks.add(t);
  }
  return ticks;
}

double _fractionOf(DateTime t, DateTime from, DateTime to) =>
    t.difference(from).inSeconds / to.difference(from).inSeconds;

class _HourScale extends StatelessWidget {
  const _HourScale({
    required this.width,
    required this.from,
    required this.to,
    required this.style,
  });

  final double width;
  final DateTime from;
  final DateTime to;
  final TextStyle style;

  static const double _labelWidth = 26;

  @override
  Widget build(BuildContext context) {
    final labels = <Widget>[];
    var lastRight = double.negativeInfinity;
    for (final t in _hourTicks(from, to)) {
      final center = width * _fractionOf(t, from, to);
      final left = (center - _labelWidth / 2).clamp(0.0, width - _labelWidth);
      if (left < lastRight + 2) continue;
      lastRight = left + _labelWidth;
      labels.add(
        Positioned(
          left: left,
          top: 2,
          width: _labelWidth,
          child: Text(
            '${t.hour.toString().padLeft(2, '0')}h',
            style: style,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return Stack(clipBehavior: Clip.none, children: labels);
  }
}

class _AltitudeGridPainter extends CustomPainter {
  _AltitudeGridPainter({
    required this.ticks,
    required this.from,
    required this.to,
    required this.line,
  });

  final List<DateTime> ticks;
  final DateTime from;
  final DateTime to;
  final Color line;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = line.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    for (final deg in _AltitudeAxes._degrees) {
      final y = (size.height * (1 - deg / 90)).clamp(0.5, size.height - 0.5);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    for (final t in ticks) {
      final x = size.width * _fractionOf(t, from, to);
      canvas.drawLine(
        Offset(x, size.height - 3),
        Offset(x, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_AltitudeGridPainter old) =>
      old.line != line ||
      old.from != from ||
      old.to != to ||
      old.ticks.length != ticks.length;
}

class _Legend extends StatelessWidget {
  const _Legend({required this.target});

  final NightTargetVm target;

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    final colors = context.skotiqColors;
    final style = SkotiqTypography.captionSm.copyWith(color: colors.textMuted);
    final moonPct = target.moonIlluminationPct;
    final moonCurve = target.moonAltitudeCurve;
    final hasMoon = moonCurve != null && moonCurve.isNotEmpty;

    Widget item(Color swatch, String text, {Color? ink}) => Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(width: 10, height: 2, color: swatch),
            const SizedBox(width: SkotiqTokens.spaceXs),
            Text(text, style: ink == null ? style : style.copyWith(color: ink)),
          ],
        );

    return ExcludeSemantics(
      child: Wrap(
        spacing: 10,
        runSpacing: 2,
        children: <Widget>[
          item(colors.primary, l10n.text('nightCtlLegendAltitude')),
          if (hasMoon)
            item(
              colors.textMuted,
              moonPct == null
                  ? l10n.text('nightCtlLegendMoon')
                  : l10n.text('nightCtlLegendMoonPct', params: {
                      'pct': moonPct.round().toString(),
                    }),
            ),
          if (target.flipAt case final flip?)
            item(
              colors.warning,
              l10n.text('nightCtlLegendFlip', params: {'time': nightHm(flip)}),
              ink: colors.warning,
            ),
          item(
            colors.borderHighlight,
            l10n.text('nightCtlLegendLimit', params: {
              'deg': target.horizonLimitDeg.round().toString(),
            }),
          ),
        ],
      ),
    );
  }
}
