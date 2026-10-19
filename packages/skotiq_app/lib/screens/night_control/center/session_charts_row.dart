// The chart row under the strip.
//
// During and after a run: HFR · stars per frame with autofocus and rejected
// marks, guide error in pixels with dither marks, temperature · focus. Before
// a run (TonightReady.dc.html): the last autofocus curve, the guider's idle
// card with Start looping / Open PHD2, and the cooling ramp. Every chart
// carries a semantics sentence built from the same data it draws.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../data/plan/night_run_phase_provider.dart';
import '../data/session/session_format.dart';
import '../data/session/session_series_provider.dart';
import '../data/session/guide_series_provider.dart';
import '../night_control_contracts.dart';
import '../night_control_layout.dart';
import 'center_format.dart';
import 'frame_stage.dart' show nightIsBeforeRun;

part 'session_charts_ready.dart';

// ---------------------------------------------------------------------------
// The row
// ---------------------------------------------------------------------------

class SessionChartsRow extends ConsumerWidget {
  const SessionChartsRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final density = NightControlDensity.maybeOf(context);
    final height = density?.chartRowHeight ?? NightControlLayout.chartRowHeight;
    final before = nightIsBeforeRun(ref.watch(nightRunPhaseProvider));
    final cells = before
        ? const <Widget>[_FocusCard(), _GuiderIdleCard(), _CoolingCard()]
        : const <Widget>[_HfrChart(), _GuideChart(), _TemperatureChart()];

    final single = density?.mode == NightControlMode.singleColumn;
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: single
          ? _Pager(cells: cells)
          : Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (var i = 0; i < cells.length; i++)
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: i < cells.length - 1
                            ? Border(right: BorderSide(color: colors.border))
                            : const Border(),
                      ),
                      child: cells[i],
                    ),
                  ),
              ],
            ),
    );
  }
}

/// The single column's charts: one card per page, the next one peeking in
/// so the row reads as swipeable.
class _Pager extends StatefulWidget {
  const _Pager({required this.cells});

  final List<Widget> cells;

  @override
  State<_Pager> createState() => _PagerState();
}

class _PagerState extends State<_Pager> {
  final PageController _controller = PageController(viewportFraction: 0.9);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return PageView(
      controller: _controller,
      padEnds: false,
      children: <Widget>[
        for (final cell in widget.cells)
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(right: BorderSide(color: colors.border)),
            ),
            child: cell,
          ),
      ],
    );
  }
}

/// A cell: title and a note on the first line, the body, a legend line.
class _Cell extends StatelessWidget {
  const _Cell({
    required this.title,
    required this.body,
    this.note,
    this.noteColor,
    this.legend,
  });

  final String title;
  final String? note;
  final Color? noteColor;
  final Widget body;
  final InlineSpan? legend;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 7, 10, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // The title keeps its words; the note shortens first.
          LayoutBuilder(
            builder: (context, constraints) => Row(
              children: <Widget>[
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth * 0.7,
                  ),
                  child: Semantics(
                    header: true,
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: SkotiqTypography.labelStrongSm.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Expanded(
                  child: note == null
                      ? const SizedBox.shrink()
                      : Text(
                          note!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.end,
                          style: SkotiqTypography.captionSm.copyWith(
                            color: noteColor ?? colors.textMuted,
                          ),
                        ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(child: body),
          if (legend != null) ...<Widget>[
            const SizedBox(height: 3),
            Text.rich(
              legend!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: SkotiqTypography.captionSm.copyWith(
                color: colors.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A chart filling the body, or a quiet line when there is nothing to draw.
class _ChartBody extends StatelessWidget {
  const _ChartBody({
    required this.semanticLabel,
    required this.lines,
    this.markers = const <SeriesChartMarker>[],
    this.highlights = const <SeriesChartHighlight>[],
    this.from,
    this.to,
    this.zeroLineY,
    this.empty,
  });

  final String semanticLabel;
  final List<SeriesChartLine> lines;
  final List<SeriesChartMarker> markers;
  final List<SeriesChartHighlight> highlights;
  final DateTime? from;
  final DateTime? to;
  final double? zeroLineY;

  /// Shown instead of the chart when set.
  final String? empty;

  @override
  Widget build(BuildContext context) {
    final emptyText = empty;
    if (emptyText != null) {
      return Semantics(
        label: semanticLabel,
        excludeSemantics: true,
        child: Center(
          child: Text(
            emptyText,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: SkotiqTypography.captionSm.copyWith(
              color: context.skotiqColors.textMuted,
            ),
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) => SeriesChart(
        lines: lines,
        markers: markers,
        highlights: highlights,
        from: from,
        to: to,
        zeroLineY: zeroLineY,
        height: math.max(0, constraints.maxHeight),
        semanticLabel: semanticLabel,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Mapping the view models onto the kit chart
// ---------------------------------------------------------------------------

SeriesChartTone _tone(SeriesTone tone) => switch (tone) {
      SeriesTone.primary => SeriesChartTone.primary,
      SeriesTone.secondary => SeriesChartTone.secondary,
      SeriesTone.tertiary => SeriesChartTone.tertiary,
      SeriesTone.muted => SeriesChartTone.muted,
      SeriesTone.warning => SeriesChartTone.warning,
      SeriesTone.error => SeriesChartTone.error,
    };

SeriesChartLine _line(SeriesLineVm line, {double? minY, double? maxY}) =>
    SeriesChartLine(
      points: <(DateTime, double?)>[
        for (final point in line.points) (point.t, point.y),
      ],
      tone: _tone(line.tone),
      axis: line.secondaryAxis ? SeriesChartAxis.right : SeriesChartAxis.left,
      dashed: line.dashed,
      stepped: line.stepped,
      minY: minY,
      maxY: maxY,
    );

SeriesChartTone _markerTone(SeriesMarkerKind kind) => switch (kind) {
      SeriesMarkerKind.autofocus => SeriesChartTone.muted,
      SeriesMarkerKind.dither => SeriesChartTone.secondary,
      SeriesMarkerKind.flip => SeriesChartTone.warning,
      SeriesMarkerKind.reject => SeriesChartTone.error,
    };

/// Vertical marks for everything but rejects, which are dots on the line.
List<SeriesChartMarker> _markers(NightSeriesVm vm) => <SeriesChartMarker>[
      for (final marker in vm.markers)
        if (marker.kind != SeriesMarkerKind.reject)
          SeriesChartMarker(marker.t, tone: _markerTone(marker.kind)),
    ];

SeriesLineVm? _lineOf(NightSeriesVm vm, NightSeriesId id) {
  for (final line in vm.lines) {
    if (line.id == id) return line;
  }
  return null;
}

List<double> _values(SeriesLineVm? line) => <double>[
      if (line != null)
        for (final point in line.points)
          if (point.y case final y?) y,
    ];

/// The legend swatch for a legend entry, by the label key P1b gives it.
const Map<String, NightSeriesId> _legendLine = <String, NightSeriesId>{
  'nightSessionHfr': NightSeriesId.hfr,
  'nightSessionStars': NightSeriesId.stars,
  'nightSessionGuideRa': NightSeriesId.guideRa,
  'nightSessionGuideDec': NightSeriesId.guideDec,
  'nightSessionFocuserTemp': NightSeriesId.focuserTemp,
  'nightSessionFocuserPosition': NightSeriesId.focuserPosition,
  'nightSessionSensorTemp': NightSeriesId.sensorTemp,
};

InlineSpan _legend(
  BuildContext context,
  NightSeriesVm vm, {
  List<(String, SeriesChartTone)> marks = const <(String, SeriesChartTone)>[],
}) {
  final colors = context.skotiqColors;
  final l10n = context.l10n;
  final spans = <InlineSpan>[];
  void gap() {
    if (spans.isNotEmpty) spans.add(const TextSpan(text: '   '));
  }

  for (final item in vm.legend) {
    gap();
    final id = _legendLine[item.label.key];
    final line = id == null ? null : _lineOf(vm, id);
    if (line != null) {
      spans.add(
        _swatch(
          line.dashed ? _SwatchKind.dashed : _SwatchKind.line,
          SeriesChart.colorFor(_tone(line.tone), colors),
        ),
      );
    }
    spans.add(
      TextSpan(
        text: item.value == null
            ? item.label.resolve(l10n)
            : '${item.label.resolve(l10n)} ${item.value}',
      ),
    );
  }
  for (final (label, tone) in marks) {
    gap();
    final dot = tone == SeriesChartTone.error;
    final color = SeriesChart.colorFor(tone, colors);
    spans
      ..add(_swatch(dot ? _SwatchKind.dot : _SwatchKind.marker, color))
      ..add(
        TextSpan(
          text: label,
          style: TextStyle(color: dot ? color : null),
        ),
      );
  }
  return TextSpan(children: spans);
}

String _join(List<String> parts) => parts.join('; ');

enum _SwatchKind { line, dashed, marker, dot }

/// A legend key drawn rather than typed: the chart faces have no box-drawing
/// or bullet glyphs.
InlineSpan _swatch(_SwatchKind kind, Color color) {
  final Widget mark = switch (kind) {
    _SwatchKind.line => Container(width: 10, height: 2, color: color),
    _SwatchKind.dashed => Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(width: 4, height: 2, color: color),
          const SizedBox(width: 2),
          Container(width: 4, height: 2, color: color),
        ],
      ),
    _SwatchKind.marker => Container(width: 1.5, height: 9, color: color),
    _SwatchKind.dot => Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
  };
  return WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: Padding(
      padding: const EdgeInsets.only(right: 4),
      child: ExcludeSemantics(child: mark),
    ),
  );
}

// ---------------------------------------------------------------------------
// During the run
// ---------------------------------------------------------------------------

class _HfrChart extends ConsumerWidget {
  const _HfrChart();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final vm = ref.watch(nightFrameSeriesProvider);
    final title = l10n.text('nightCtrChartHfr');
    final hfr = _lineOf(vm, NightSeriesId.hfr);
    final count = vm.sampleCount;
    final rejected = <SeriesPoint>[
      if (hfr != null)
        for (final point in hfr.points)
          if (!point.accepted && point.y != null) point,
    ];
    final afTimes = <String>[
      for (final marker in vm.markers)
        if (marker.kind == SeriesMarkerKind.autofocus) nightClockHm(marker.t),
    ];

    final values = _values(hfr);
    final semantic = vm.isEmpty
        ? l10n.text('nightCtrSemNoData', params: {'title': title})
        : _join(<String>[
            l10n.text(
              'nightCtrSemHfr',
              params: <String, String>{'count': '${count ?? values.length}'},
            ),
            if (values.isNotEmpty)
              l10n.text(
                'nightCtrSemHfrRange',
                params: <String, String>{
                  'first': nightFixed(values.first, 2),
                  'last': nightFixed(values.last, 2),
                  'best': nightFixed(values.reduce(math.min), 2),
                },
              ),
            if (afTimes.isNotEmpty)
              l10n.text(
                'nightCtrSemAfAt',
                params: <String, String>{'times': afTimes.join(', ')},
              ),
            if (rejected.isNotEmpty)
              l10n.text(
                'nightCtrSemRejected',
                params: <String, String>{'count': '${rejected.length}'},
              ),
          ]);

    return _Cell(
      title: title,
      note: count == null
          ? null
          : l10n.text(
              'nightCtrChartHfrNote',
              params: <String, String>{'count': '$count'},
            ),
      body: _ChartBody(
        semanticLabel: semantic,
        empty: vm.isEmpty ? l10n.text('nightCtrChartNoFrames') : null,
        lines: <SeriesChartLine>[for (final line in vm.lines) _line(line)],
        markers: _markers(vm),
        highlights: <SeriesChartHighlight>[
          for (final point in rejected) SeriesChartHighlight(point.t, point.y!),
        ],
        from: vm.from,
        to: vm.to,
      ),
      legend: vm.isEmpty
          ? null
          : _legend(
              context,
              vm,
              marks: <(String, SeriesChartTone)>[
                if (afTimes.isNotEmpty)
                  (l10n.text('nightCtrMarkAf'), SeriesChartTone.muted),
                if (rejected.isNotEmpty)
                  (l10n.text('nightCtrMarkRejected'), SeriesChartTone.error),
              ],
            ),
    );
  }
}

class _GuideChart extends ConsumerWidget {
  const _GuideChart();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final vm = ref.watch(nightGuideSeriesProvider);
    final title = l10n.text('nightCtrChartGuide');
    final ra = _values(_lineOf(vm, NightSeriesId.guideRa));
    final dec = _values(_lineOf(vm, NightSeriesId.guideDec));
    final dithers =
        vm.markers.where((m) => m.kind == SeriesMarkerKind.dither).length;
    // RA and Dec share one scale, centered on zero error.
    final peak = <double>[...ra, ...dec].fold<double>(
      0,
      (worst, v) => math.max(worst, v.abs()),
    );
    final span = math.max(peak, 0.5);

    double rms(List<double> values) => values.isEmpty
        ? 0
        : math.sqrt(
            values.fold<double>(0, (sum, v) => sum + v * v) / values.length,
          );
    final from = vm.from;
    final to = vm.to;
    final minutes = from == null || to == null
        ? null
        : math.max(1, to.difference(from).inSeconds / 60).round();

    final semantic = vm.isEmpty
        ? l10n.text('nightCtrSemNoData', params: {'title': title})
        : _join(<String>[
            if (minutes != null)
              l10n.text(
                'nightCtrSemGuide',
                params: <String, String>{'minutes': '$minutes'},
              )
            else
              l10n.text('nightCtrSemGuideNoSpan'),
            if (ra.isNotEmpty)
              l10n.text(
                'nightCtrSemRms',
                params: <String, String>{
                  'axis': l10n.text('nightSessionGuideRa'),
                  'value': rms(ra).toStringAsFixed(2),
                },
              ),
            if (dec.isNotEmpty)
              l10n.text(
                'nightCtrSemRms',
                params: <String, String>{
                  'axis': l10n.text('nightSessionGuideDec'),
                  'value': rms(dec).toStringAsFixed(2),
                },
              ),
            if (dithers > 0)
              l10n.text(
                'nightCtrSemDithers',
                params: <String, String>{'count': '$dithers'},
              ),
          ]);

    return _Cell(
      title: title,
      // The guide samples are PHD2 pixels until PHD2's pixel scale is exposed
      // to the app. P9: label arcseconds once the scale is known (plan N4).
      note: l10n.text('nightCtrChartGuideNote'),
      body: _ChartBody(
        semanticLabel: semantic,
        empty: vm.isEmpty ? l10n.text('nightCtrChartNoGuiding') : null,
        lines: <SeriesChartLine>[
          for (final line in vm.lines) _line(line, minY: -span, maxY: span),
        ],
        markers: _markers(vm),
        from: from,
        to: to,
        zeroLineY: 0,
      ),
      legend: vm.isEmpty
          ? null
          : _legend(
              context,
              vm,
              marks: <(String, SeriesChartTone)>[
                if (dithers > 0)
                  (l10n.text('nightCtrMarkDither'), SeriesChartTone.secondary),
              ],
            ),
    );
  }
}

class _TemperatureChart extends ConsumerWidget {
  const _TemperatureChart();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final vm = ref.watch(nightTemperatureSeriesProvider);
    final title = l10n.text('nightCtrChartTemp');
    final focuserTemp = _values(_lineOf(vm, NightSeriesId.focuserTemp));
    final position = _values(_lineOf(vm, NightSeriesId.focuserPosition));
    final sensor = _values(_lineOf(vm, NightSeriesId.sensorTemp));

    String range(
            String nameKey, List<double> values, String Function(double) f) =>
        l10n.text(
          'nightCtrSemRange',
          params: <String, String>{
            'name': l10n.text(nameKey),
            'from': f(values.first),
            'to': f(values.last),
          },
        );

    final semantic = vm.isEmpty
        ? l10n.text('nightCtrSemNoData', params: {'title': title})
        : _join(<String>[
            if (focuserTemp.isNotEmpty)
              range('nightCtrSemFocuserTemp', focuserTemp, nightCelsius),
            if (position.isNotEmpty)
              range(
                'nightCtrSemFocuserPos',
                position,
                (v) => nightGrouped(v.round()),
              ),
            if (sensor.isNotEmpty)
              range('nightCtrSemSensor', sensor, nightCelsius),
          ]);
    final from = vm.from;

    return _Cell(
      title: title,
      note: from == null
          ? null
          : l10n.text(
              'nightCtrSince',
              params: <String, String>{'time': nightClockHm(from)},
            ),
      body: _ChartBody(
        semanticLabel: semantic,
        empty: vm.isEmpty ? l10n.text('nightCtrChartNoTemps') : null,
        lines: <SeriesChartLine>[for (final line in vm.lines) _line(line)],
        markers: _markers(vm),
        from: vm.from,
        to: vm.to,
      ),
      legend: vm.isEmpty ? null : _legend(context, vm),
    );
  }
}
