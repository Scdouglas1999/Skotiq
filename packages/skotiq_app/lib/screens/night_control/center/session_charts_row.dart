// The chart row under the strip.
//
// During and after a run: HFR · stars per frame with autofocus and rejected
// marks, guide error (arcseconds when the guider reports its scale, pixels
// otherwise) with dither marks, temperature · focus. Before a run
// (TonightReady.dc.html): the last autofocus curve, the guider's idle card
// with Start looping / Open PHD2, and the cooling ramp. Each chart has value
// and clock scales (chart_axes.dart), and its legend drops its least useful
// entries rather than truncate. Every chart carries a semantics sentence
// built from the same data it draws.
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
import 'chart_axes.dart';
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
    this.noteFallbacks = const <String>[],
    this.noteColor,
    this.trailing,
    this.legend,
  });

  final String title;
  final String? note;

  /// Shorter forms of [note], longest first, used when it does not fit
  /// beside the title; the last one shortens with an ellipsis.
  final List<String> noteFallbacks;

  /// In place of [note]: a control on the title line, such as the guide
  /// chart's span.
  final Widget? trailing;
  final Color? noteColor;
  final Widget body;

  /// One line under the chart; text in it gets the legend style.
  final Widget? legend;

  static double _textWidth(BuildContext context, String text, TextStyle style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final width = tp.width;
    tp.dispose();
    return width;
  }

  double _titleWidth(BuildContext context, TextStyle style, double max) =>
      math.min(_textWidth(context, title, style), max);

  /// [note], or the first of [noteFallbacks] that fits [room].
  String _fittedNote(BuildContext context, double room) {
    final candidates = <String>[note!, ...noteFallbacks];
    for (final candidate in candidates) {
      if (_textWidth(context, candidate, SkotiqTypography.captionSm) <= room) {
        return candidate;
      }
    }
    return candidates.last;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final titleStyle = SkotiqTypography.labelStrongSm.copyWith(
      color: colors.textPrimary,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 7, 10, 6),
      child: LayoutBuilder(builder: (context, constraints) {
        final titleMax = constraints.maxWidth * 0.7;
        final column = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // The title keeps its words; the note shortens first.
            Row(
              children: <Widget>[
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: titleMax),
                  child: Semantics(
                    header: true,
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: titleStyle,
                    ),
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Expanded(
                  child: trailing != null
                      // Room for the control, which is laid over the line
                      // below so its touch area can reach into the chart.
                      ? const SizedBox(
                          height: SegmentedControl.denseSegmentHeight,
                        )
                      : note == null
                          ? const SizedBox.shrink()
                          : Text(
                              _fittedNote(
                                context,
                                constraints.maxWidth -
                                    _titleWidth(context, titleStyle, titleMax) -
                                    SkotiqTokens.spaceSm,
                              ),
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
            const SizedBox(height: 4),
            Expanded(child: body),
            if (legend != null) ...<Widget>[
              const SizedBox(height: 3),
              DefaultTextStyle(
                style: SkotiqTypography.captionSm.copyWith(
                  color: colors.textMuted,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                child: legend!,
              ),
            ],
          ],
        );
        final control = trailing;
        if (control == null) return column;
        final titleWidth = _titleWidth(context, titleStyle, titleMax);
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            column,
            Positioned(
              top: 0,
              right: 0,
              width: math.max(
                0,
                constraints.maxWidth - titleWidth - SkotiqTokens.spaceSm,
              ),
              child: Align(alignment: Alignment.topRight, child: control),
            ),
          ],
        );
      }),
    );
  }
}

/// A chart with its scales filling the body, or a quiet line when there is
/// nothing to draw.
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
    this.leftUnit = '',
    this.rightGrouped = false,
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

  /// See [NightChartAxes].
  final String leftUnit;
  final bool rightGrouped;

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
    return NightChartAxes(
      lines: lines,
      markers: markers,
      highlights: highlights,
      from: from,
      to: to,
      zeroLineY: zeroLineY,
      semanticLabel: semanticLabel,
      leftUnit: leftUnit,
      rightGrouped: rightGrouped,
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

/// The legend line: what each line is, its latest numbers and the marks.
/// At a narrow cell the least useful entries go first (plain numbers, then
/// marks) so the line keys always fit whole.
Widget _legend(
  BuildContext context,
  NightSeriesVm vm, {
  List<_Mark> marks = const <_Mark>[],
  Set<String> keep = const <String>{},
}) {
  final colors = context.skotiqColors;
  final l10n = context.l10n;
  final entries = <_LegendEntry>[];
  for (final item in vm.legend) {
    final id = _legendLine[item.label.key];
    final line = id == null ? null : _lineOf(vm, id);
    entries.add(
      _LegendEntry(
        text: item.label.resolve(l10n),
        value: item.value,
        swatch: line == null
            ? null
            : line.dashed
                ? _SwatchKind.dashed
                : _SwatchKind.line,
        swatchColor: line == null
            ? null
            : SeriesChart.colorFor(_tone(line.tone), colors),
        rank: line == null && !keep.contains(item.label.key) ? 2 : 0,
      ),
    );
  }
  for (final mark in marks) {
    final color = SeriesChart.colorFor(mark.tone, colors);
    entries.add(
      _LegendEntry(
        text: mark.label,
        swatch: mark.dot ? _SwatchKind.dot : _SwatchKind.marker,
        swatchColor: color,
        textColor: mark.dot ? color : null,
        rank: mark.rank,
      ),
    );
  }
  return _FitLegend(entries: entries);
}

/// A legend key for something marked on a chart rather than a line: a
/// vertical (autofocus, dither) or a dot (rejected, off scale).
@immutable
class _Mark {
  const _Mark(this.label, this.tone, {this.dot = false, this.rank = 1});

  final String label;
  final SeriesChartTone tone;
  final bool dot;

  /// As [_LegendEntry.rank]: 2 gives the key up before the lines' numbers.
  final int rank;
}

@immutable
class _LegendEntry {
  const _LegendEntry({
    required this.text,
    this.value,
    required this.rank,
    this.swatch,
    this.swatchColor,
    this.textColor,
  });

  final String text;

  /// The latest number after [text]; the first thing a key line gives up.
  final String? value;

  /// 0 keeps longest (a line's key), 2 goes first (a plain number).
  final int rank;
  final _SwatchKind? swatch;
  final Color? swatchColor;
  final Color? textColor;
}

/// One legend line fitted to its width. Plain numbers go first, then each
/// line key's number (the scale beside the chart still gives it), then the
/// marks, then line keys from the end; one entry always stays.
class _FitLegend extends StatelessWidget {
  const _FitLegend({required this.entries});

  final List<_LegendEntry> entries;

  static const String _gap = '  ';

  static double _swatchWidth(_SwatchKind kind) => switch (kind) {
        _SwatchKind.line => 10,
        _SwatchKind.dashed => 10,
        _SwatchKind.marker => 1.5,
        _SwatchKind.dot => 6,
      };

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    double measure(String text) {
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

    String label(_LegendEntry e, bool withValue) =>
        withValue && e.value != null ? '${e.text} ${e.value}' : e.text;

    return LayoutBuilder(builder: (context, constraints) {
      final max = constraints.maxWidth;
      final gap = measure(_gap);
      final kept = List<bool>.filled(entries.length, true);
      final withValue = List<bool>.filled(entries.length, true);
      double width(int i) {
        final swatch = entries[i].swatch;
        // Text.rich scales a WidgetSpan with the text, so the swatch does too.
        return measure(label(entries[i], withValue[i])) +
            (swatch == null ? 0 : scaler.scale(_swatchWidth(swatch) + 4));
      }

      double total() {
        var sum = 0.0;
        var count = 0;
        for (var i = 0; i < entries.length; i++) {
          if (!kept[i]) continue;
          sum += width(i);
          count++;
        }
        return sum + gap * math.max(0, count - 1);
      }

      // A few pixels of slack for the swatches' placeholder rounding.
      bool fits() => total() <= max - 4;
      int keptCount() => kept.where((k) => k).length;
      void dropRank(int rank) {
        for (var i = entries.length - 1; i >= 0 && !fits(); i--) {
          if (entries[i].rank == rank && keptCount() > 1) kept[i] = false;
        }
      }

      dropRank(2);
      for (var i = entries.length - 1; i >= 0 && !fits(); i--) {
        if (entries[i].rank == 0) withValue[i] = false;
      }
      dropRank(1);
      dropRank(0);

      final spans = <InlineSpan>[];
      for (var i = 0; i < entries.length; i++) {
        if (!kept[i]) continue;
        final e = entries[i];
        if (spans.isNotEmpty) spans.add(const TextSpan(text: _gap));
        final swatch = e.swatch;
        if (swatch != null) spans.add(_swatch(swatch, e.swatchColor!));
        spans.add(
          TextSpan(
            text: label(e, withValue[i]),
            style: TextStyle(color: e.textColor),
          ),
        );
      }
      return Text.rich(TextSpan(children: spans));
    });
  }
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
        leftUnit: ' px',
        rightGrouped: true,
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
              marks: <_Mark>[
                if (afTimes.isNotEmpty)
                  _Mark(l10n.text('nightCtrMarkAf'), SeriesChartTone.muted),
                if (rejected.isNotEmpty)
                  _Mark(
                    l10n.text('nightCtrMarkRejected'),
                    SeriesChartTone.error,
                    dot: true,
                  ),
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
    final window = ref.watch(nightGuideWindowProvider);
    // Arcseconds only when the guider reports its pixel scale.
    final arcsec = ref.watch(nightGuideScaleProvider) != null;
    String unit(String key) => arcsec ? '${key}Arcsec' : key;
    final title = l10n.text('nightCtrChartGuide');
    final ra = _values(_lineOf(vm, NightSeriesId.guideRa));
    final dec = _values(_lineOf(vm, NightSeriesId.guideDec));
    final dithers =
        vm.markers.where((m) => m.kind == SeriesMarkerKind.dither).length;
    // RA and Dec share one scale, centered on zero error, sized to the
    // usual error rather than the worst step; see nightGuideSpan.
    final span = nightGuideSpan(<double>[...ra, ...dec]);
    final scale = nightGuideChartLines(vm, span);

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
                unit(
                  window == NightGuideWindow.night
                      ? 'nightCtrSemGuideNight'
                      : 'nightCtrSemGuide',
                ),
                params: <String, String>{'minutes': '$minutes'},
              )
            else
              l10n.text(unit('nightCtrSemGuideNoSpan')),
            if (ra.isNotEmpty)
              l10n.text(
                unit('nightCtrSemRms'),
                params: <String, String>{
                  'axis': l10n.text('nightSessionGuideRa'),
                  'value': rms(ra).toStringAsFixed(2),
                },
              ),
            if (dec.isNotEmpty)
              l10n.text(
                unit('nightCtrSemRms'),
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
            if (scale.offScale > 0)
              l10n.text(
                'nightCtrSemOffScale',
                params: <String, String>{'count': '${scale.offScale}'},
              ),
          ]);

    return _Cell(
      title: title,
      trailing: const _GuideWindowPicker(),
      body: _ChartBody(
        leftUnit: arcsec ? '″' : ' px',
        semanticLabel: semantic,
        empty: vm.isEmpty ? l10n.text('nightCtrChartNoGuiding') : null,
        lines: scale.lines,
        markers: _markers(vm),
        highlights: scale.offScaleMarks,
        from: from,
        to: to,
        zeroLineY: 0,
      ),
      legend: vm.isEmpty
          ? null
          : _legend(
              context,
              vm,
              keep: const <String>{'nightSessionGuideRms'},
              marks: <_Mark>[
                if (dithers > 0)
                  // The dashed verticals read without a key; the numbers
                  // do not.
                  _Mark(
                    l10n.text('nightCtrMarkDither'),
                    SeriesChartTone.secondary,
                    rank: 2,
                  ),
                if (scale.offScale > 0)
                  _Mark(
                    l10n.text('nightCtrMarkOffScale'),
                    SeriesChartTone.warning,
                    dot: true,
                  ),
              ],
            ),
    );
  }
}

/// The guide chart's lines on a scale of plus and minus [span]: thinned to
/// what the chart can draw, broken where guiding paused, and with every
/// point beyond the scale held at its edge and marked there, so a dither or
/// a lost star reads as off scale instead of flattening the trace.
@visibleForTesting
({
  List<SeriesChartLine> lines,
  List<SeriesChartHighlight> offScaleMarks,
  int offScale,
}) nightGuideChartLines(NightSeriesVm vm, double span) {
  final lines = <SeriesChartLine>[];
  final marks = <SeriesChartHighlight>[];
  var offScale = 0;
  for (final line in vm.lines) {
    final points = <(DateTime, double?)>[];
    for (final point in nightGuideTrace(line.points)) {
      final y = point.y;
      if (y != null && y.abs() > span) {
        final edge = y.sign * span;
        points.add((point.t, edge));
        marks.add(
          SeriesChartHighlight(point.t, edge, tone: SeriesChartTone.warning),
        );
      } else {
        points.add((point.t, y));
      }
    }
    for (final point in line.points) {
      final y = point.y;
      if (y != null && y.abs() > span) offScale++;
    }
    lines.add(
      SeriesChartLine(
        points: points,
        tone: _tone(line.tone),
        minY: -span,
        maxY: span,
      ),
    );
  }
  return (lines: lines, offScaleMarks: marks, offScale: offScale);
}

/// 2 min · 5 min · 15 min · Night on the guide chart's title line; the short
/// labels when the long ones do not fit.
class _GuideWindowPicker extends ConsumerWidget {
  const _GuideWindowPicker();

  static const List<(NightGuideWindow, String, String)> _items =
      <(NightGuideWindow, String, String)>[
    (
      NightGuideWindow.twoMinutes,
      'nightCtrGuideWindow2',
      'nightCtrGuideWindow2Short'
    ),
    (
      NightGuideWindow.fiveMinutes,
      'nightCtrGuideWindow5',
      'nightCtrGuideWindow5Short'
    ),
    (
      NightGuideWindow.fifteenMinutes,
      'nightCtrGuideWindow15',
      'nightCtrGuideWindow15Short'
    ),
    (
      NightGuideWindow.night,
      'nightCtrGuideWindowNight',
      'nightCtrGuideWindowNightShort'
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final window = ref.watch(nightGuideWindowProvider);
    final selected = _items.indexWhere((item) => item.$1 == window);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(builder: (context, constraints) {
      double width(List<String> labels) {
        var total = SegmentedControl.gap * (labels.length - 1);
        for (final label in labels) {
          final tp = TextPainter(
            text: TextSpan(text: label, style: SkotiqTypography.labelStrongSm),
            textScaler: scaler,
            textDirection: TextDirection.ltr,
            maxLines: 1,
          )..layout();
          total += tp.width + 2 * SegmentedControl.denseSegmentPadding;
          tp.dispose();
        }
        return total;
      }

      final long = <String>[for (final item in _items) l10n.text(item.$2)];
      final labels = width(long) <= constraints.maxWidth
          ? long
          : <String>[for (final item in _items) l10n.text(item.$3)];
      return FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerRight,
        child: SegmentedControl(
          dense: true,
          semanticLabel: l10n.text('nightCtrGuideWindow'),
          segments: labels,
          selectedIndex: selected,
          onSelected: (i) =>
              ref.read(nightGuideWindowProvider.notifier).state = _items[i].$1,
        ),
      );
    });
  }
}

/// Focus · temperature, as two bands on one clock: the focuser position in
/// steps above the temperature in °C, autofocus runs marked through both.
/// The title line says when the last run was and how far it moved the
/// focuser; the legend says how far the temperature has moved since.
class _TemperatureChart extends ConsumerWidget {
  const _TemperatureChart();

  /// The narrowest position scale, in steps, so a focuser that holds still
  /// is a flat line rather than noise blown up to the full band.
  static const double minPositionSpan = 20;

  /// The narrowest temperature scale, in °C.
  static const double minTempSpan = 2;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final vm = ref.watch(nightTemperatureSeriesProvider);
    final title = l10n.text('nightCtrChartTemp');
    final position = _lineOf(vm, NightSeriesId.focuserPosition);
    final focuserTemp = _lineOf(vm, NightSeriesId.focuserTemp);
    final sensorTemp = _lineOf(vm, NightSeriesId.sensorTemp);
    // The focuser's probe follows the air around the optics; the sensor is
    // the stand-in when there is no probe.
    final useFocuserTemp = _values(focuserTemp).isNotEmpty;
    final temp = useFocuserTemp ? focuserTemp : sensorTemp;
    final tempId =
        useFocuserTemp ? NightSeriesId.focuserTemp : NightSeriesId.sensorTemp;
    final tempValues = _values(temp);
    final positionValues = _values(position);
    final afRuns = <SeriesMarker>[
      for (final marker in vm.markers)
        if (marker.kind == SeriesMarkerKind.autofocus) marker,
    ];
    final shift = nightLastFocusShift(vm, temperature: tempId);
    final empty = tempValues.isEmpty && positionValues.isEmpty;

    String signedSteps(int steps) =>
        steps == 0 ? '0' : nightSignedDelta(steps.toDouble(), 0);
    String signedCelsius(double delta) => '${nightSignedDelta(delta, 1)} °C';

    final semantic = empty
        ? l10n.text('nightCtrSemNoData', params: {'title': title})
        : _join(<String>[
            if (positionValues.isNotEmpty)
              l10n.text(
                'nightCtrSemRange',
                params: <String, String>{
                  'name': l10n.text('nightCtrSemFocuserPos'),
                  'from': nightGrouped(positionValues.first.round()),
                  'to': nightGrouped(positionValues.last.round()),
                },
              ),
            if (tempValues.isNotEmpty)
              l10n.text(
                'nightCtrSemRange',
                params: <String, String>{
                  'name': l10n.text(
                    useFocuserTemp
                        ? 'nightCtrSemFocuserTemp'
                        : 'nightCtrSemSensor',
                  ),
                  'from': nightCelsius(tempValues.first),
                  'to': nightCelsius(tempValues.last),
                },
              ),
            if (afRuns.isNotEmpty)
              l10n.text(
                'nightCtrSemAfCount',
                params: <String, String>{'count': '${afRuns.length}'},
              ),
            if (shift?.steps case final steps?)
              l10n.text(
                'nightCtrSemAfShift',
                params: <String, String>{
                  'time': nightClockHm(shift!.at),
                  'steps': signedSteps(steps),
                },
              ),
            if (shift?.tempSince case final delta?)
              l10n.text(
                'nightCtrSemTempSinceAf',
                params: <String, String>{'delta': signedCelsius(delta)},
              ),
          ]);

    // The note: the last autofocus and its move, else the chart's start.
    final from = vm.from;
    final String? note;
    final noteFallbacks = <String>[];
    if (shift != null) {
      final steps = shift.steps;
      if (steps != null) {
        noteFallbacks.addAll(<String>[
          l10n.text(
            'nightCtrFocusLastAfMove',
            params: <String, String>{'steps': signedSteps(steps)},
          ),
          l10n.text(
            'nightCtrFocusLastAfAt',
            params: <String, String>{'time': nightClockHm(shift.at)},
          ),
        ]);
      }
    }
    if (shift != null) {
      final steps = shift.steps;
      note = steps == null
          ? l10n.text(
              'nightCtrFocusLastAfAt',
              params: <String, String>{'time': nightClockHm(shift.at)},
            )
          : l10n.text(
              'nightCtrFocusLastAf',
              params: <String, String>{
                'time': nightClockHm(shift.at),
                'steps': signedSteps(steps),
              },
            );
    } else {
      note = from == null
          ? null
          : l10n.text(
              'nightCtrSince',
              params: <String, String>{'time': nightClockHm(from)},
            );
    }

    SeriesChartLine band(
      SeriesLineVm line,
      List<double> values,
      double minSpan,
      SeriesChartTone tone,
    ) {
      double? lo;
      double? hi;
      if (values.isNotEmpty) {
        final low = values.reduce(math.min);
        final high = values.reduce(math.max);
        if (high - low < minSpan) {
          final mid = (low + high) / 2;
          lo = mid - minSpan / 2;
          hi = mid + minSpan / 2;
        }
      }
      return SeriesChartLine(
        points: <(DateTime, double?)>[
          for (final point in line.points) (point.t, point.y),
        ],
        tone: tone,
        stepped: line.stepped,
        minY: lo,
        maxY: hi,
      );
    }

    final strips = <NightChartStrip>[
      if (position != null && positionValues.isNotEmpty)
        NightChartStrip(
          lines: <SeriesChartLine>[
            band(position, positionValues, minPositionSpan,
                SeriesChartTone.primary),
          ],
          unit: l10n.text('nightCtrAxisSteps'),
          unitTone: SeriesChartTone.primary,
          grouped: true,
        ),
      if (temp != null && tempValues.isNotEmpty)
        NightChartStrip(
          lines: <SeriesChartLine>[
            band(temp, tempValues, minTempSpan, SeriesChartTone.tertiary),
          ],
          unit: l10n.text('nightCtrAxisCelsius'),
          unitTone: SeriesChartTone.tertiary,
        ),
    ];
    final markers = <SeriesChartMarker>[
      for (final run in afRuns)
        SeriesChartMarker(run.t, tone: SeriesChartTone.muted),
    ];

    final colors = context.skotiqColors;
    final entries = <_LegendEntry>[
      if (positionValues.isNotEmpty)
        _LegendEntry(
          text: l10n.text('nightSessionFocuserPosition'),
          value: nightGrouped(positionValues.last.round()),
          swatch: _SwatchKind.line,
          swatchColor: SeriesChart.colorFor(SeriesChartTone.primary, colors),
          rank: 0,
        ),
      if (tempValues.isNotEmpty)
        _LegendEntry(
          text: l10n.text(
            useFocuserTemp
                ? 'nightSessionFocuserTemp'
                : 'nightSessionSensorTemp',
          ),
          value: nightCelsius(tempValues.last),
          swatch: _SwatchKind.line,
          swatchColor: SeriesChart.colorFor(SeriesChartTone.tertiary, colors),
          rank: 0,
        ),
      if (shift?.tempSince case final delta?)
        _LegendEntry(
          text: l10n.text(
            'nightCtrFocusTempSince',
            params: <String, String>{'delta': signedCelsius(delta)},
          ),
          rank: 0,
        ),
      if (afRuns.isNotEmpty)
        _LegendEntry(
          text: l10n.text('nightCtrMarkAf'),
          swatch: _SwatchKind.marker,
          swatchColor: SeriesChart.colorFor(SeriesChartTone.muted, colors),
          rank: 1,
        ),
    ];

    return _Cell(
      title: title,
      note: note,
      noteFallbacks: noteFallbacks,
      body: empty
          ? _ChartBody(
              semanticLabel: semantic,
              lines: const <SeriesChartLine>[],
              empty: l10n.text('nightCtrChartNoTemps'),
            )
          : NightChartStrips(
              strips: strips,
              markers: markers,
              from: vm.from,
              to: vm.to,
              semanticLabel: semantic,
            ),
      legend: empty ? null : _FitLegend(entries: entries),
    );
  }
}
