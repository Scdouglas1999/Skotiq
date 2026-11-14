import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A single guide data point for the graph
class GuideDataPoint {
  final DateTime timestamp;
  final double raError;
  final double decError;
  final double? raPulse;
  final double? decPulse;

  const GuideDataPoint({
    required this.timestamp,
    required this.raError,
    required this.decError,
    this.raPulse,
    this.decPulse,
  });
}

/// Static contract for an option rendered by [GuideGraphAdvanced]'s scale
/// selector. Both scale enums implement this so the selector can read `label`
/// through a typed interface instead of a `dynamic` dispatch.
abstract interface class GraphScaleOption {
  /// Human-readable label shown in the selector trigger and menu.
  String get label;
}

/// Time scale options for the graph
enum GraphTimeScale implements GraphScaleOption {
  oneMinute(Duration(minutes: 1), '1m'),
  fiveMinutes(Duration(minutes: 5), '5m'),
  fifteenMinutes(Duration(minutes: 15), '15m'),
  thirtyMinutes(Duration(minutes: 30), '30m');

  final Duration duration;
  @override
  final String label;

  const GraphTimeScale(this.duration, this.label);
}

/// The Y-scale selector's text in the unit the graph is plotted in, so the
/// selector and the axis agree (`±2"` in arcseconds, `±2 px` in pixels).
String yScaleLabel(GraphYScale scale, String valueUnit) =>
    '±${_axisNumber(scale.arcsec)}$valueUnit';

/// A scale value with no trailing `.0`: `2`, `1`, `0.5`.
String _axisNumber(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

/// Y-axis scale options for the graph
enum GraphYScale implements GraphScaleOption {
  one(1.0, '±1"'),
  two(2.0, '±2"'),
  four(4.0, '±4"'),
  eight(8.0, '±8"');

  final double arcsec;
  @override
  final String label;

  const GraphYScale(this.arcsec, this.label);
}

/// Advanced guiding graph widget that displays RA/Dec error traces over time
class GuideGraphAdvanced extends StatelessWidget {
  /// List of guide data points (newest last)
  final List<GuideDataPoint> data;

  /// Time scale for X-axis
  final GraphTimeScale timeScale;

  /// Y-axis scale in arcseconds
  final GraphYScale yScale;

  /// Whether to show RA trace
  final bool showRa;

  /// Whether to show Dec trace
  final bool showDec;

  /// Whether to show pulse duration overlay
  final bool showPulses;

  /// Current RMS values for the statistics bar, already converted into
  /// [rmsUnit]. `null` means "not measured yet" and renders as an em dash —
  /// a fabricated 0.00 here reads as flawless guiding.
  final double? rmsRa;
  final double? rmsDec;
  final double? rmsTotal;

  /// Unit suffix for the RMS readouts. The guider reports residuals in pixels;
  /// callers convert to arcseconds only when a pixel scale is known, so the
  /// suffix travels with the value instead of being hard-coded to arcsec.
  final String rmsUnit;

  /// Unit suffix for the plotted errors / Y-axis labels. Same contract as
  /// [rmsUnit]: the axis must not claim arcseconds when it is plotting raw
  /// guide-camera pixels.
  final String valueUnit;

  /// Callback when time scale is changed
  final void Function(GraphTimeScale)? onTimeScaleChanged;

  /// Callback when Y scale is changed
  final void Function(GraphYScale)? onYScaleChanged;

  const GuideGraphAdvanced({
    super.key,
    required this.data,
    this.timeScale = GraphTimeScale.fiveMinutes,
    this.yScale = GraphYScale.two,
    this.showRa = true,
    this.showDec = true,
    this.showPulses = false,
    this.rmsRa,
    this.rmsDec,
    this.rmsTotal,
    this.rmsUnit = '"',
    this.valueUnit = '"',
    this.onTimeScaleChanged,
    this.onYScaleChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;

    return Column(
      children: [
        // Graph controls and RMS stats
        _buildControlsBar(context),
        const SizedBox(height: 4),
        // Main graph
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: colors.background,
              border: Border.all(color: colors.border),
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
            ),
            padding: const EdgeInsets.all(8),
            child: _plot(),
          ),
        ),
      ],
    );
  }

  /// The error traces against time before now (now at the right edge, older
  /// samples scrolling left, as PHD2 draws it) on a fixed symmetric scale. An
  /// excursion past the scale sits on its edge rather than leaving the plot.
  Widget _plot() {
    final now = DateTime.now();
    final span = timeScale.duration.inMilliseconds / 1000.0;
    final limit = yScale.arcsec;
    List<Offset> trace(double Function(GuideDataPoint) error) => <Offset>[
          for (final point in data)
            if (now.difference(point.timestamp).inMilliseconds / 1000.0 <= span)
              Offset(
                -now.difference(point.timestamp).inMilliseconds / 1000.0,
                error(point).clamp(-limit, limit),
              ),
        ];
    return SkotiqChart(
      semanticLabel: 'Guide error over the last ${timeScale.label}, '
          '${yScaleLabel(yScale, valueUnit)} full scale',
      series: <ChartSeries>[
        if (showRa)
          ChartSeries(
            points: trace((p) => p.raError),
            label: 'RA',
            tone: SeriesChartTone.error,
          ),
        if (showDec)
          ChartSeries(
            points: trace((p) => p.decError),
            label: 'Dec',
            tone: SeriesChartTone.tertiary,
          ),
      ],
      x: ChartAxis(
        kind: ChartAxisKind.elapsed,
        min: -span,
        max: 0,
        maxTicks: 6,
      ),
      y: ChartAxis(
        min: -limit,
        max: limit,
        ticks: <double>[-limit, -limit / 2, 0, limit / 2, limit],
        format: (v) => v == 0
            ? '0'
            : '${v > 0 ? '+' : '-'}${_axisNumber(v.abs())}$valueUnit',
      ),
      rules: const <ChartRule>[ChartRule.y(0, dashed: false)],
      emptyText: 'No guide steps yet',
    );
  }

  Widget _buildControlsBar(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final colors = context.skotiqColors;
        final isCompact = constraints.maxWidth < 450;
        final isVeryCompact = constraints.maxWidth < 350;

        return Container(
          padding: EdgeInsets.symmetric(
            horizontal: isCompact ? 6 : 8,
            vertical: 4,
          ),
          decoration: BoxDecoration(
            color: colors.surfaceAlt,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
          ),
          child: Row(
            children: [
              // RMS Statistics - hide on very compact screens (shown elsewhere)
              if (!isVeryCompact)
                Flexible(
                  child: ClipRect(
                    child: _buildRmsStats(colors: colors, compact: isCompact),
                  ),
                ),
              if (!isVeryCompact) SizedBox(width: isCompact ? 6 : 8),
              // Time scale selector
              _buildScaleSelector(
                context: context,
                colors: colors,
                label: isCompact ? 'T:' : 'Time:',
                value: timeScale.label,
                items: GraphTimeScale.values,
                onChanged: onTimeScaleChanged,
                compact: isCompact,
              ),
              SizedBox(width: isCompact ? 8 : 16),
              // Y scale selector
              _buildScaleSelector(
                context: context,
                colors: colors,
                label: isCompact ? 'Y:' : 'Scale:',
                value: yScaleLabel(yScale, valueUnit),
                items: GraphYScale.values,
                labelOf: (s) => yScaleLabel(s, valueUnit),
                onChanged: onYScaleChanged,
                compact: isCompact,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRmsStats({required SkotiqColors colors, bool compact = false}) {
    final spacing = compact ? 8.0 : 16.0;
    // The caller already constrains this in a Flexible + ClipRect. When the
    // header row gets tight (narrow guiding panel, side-by-side with the scale
    // selectors), the three RMS readouts can exceed the Flexible's width and
    // log a RenderFlex overflow. Scale the whole block down to fit rather than
    // clip a digit off a number — the values stay legible and aligned left.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildRmsValue(
            'RA',
            rmsRa,
            colors.error,
            colors: colors,
            compact: compact,
          ),
          SizedBox(width: spacing),
          _buildRmsValue(
            'Dec',
            rmsDec,
            colors.info,
            colors: colors,
            compact: compact,
          ),
          SizedBox(width: spacing),
          _buildRmsValue(
            'Tot',
            rmsTotal,
            colors.textPrimary,
            colors: colors,
            bold: true,
            compact: compact,
          ),
        ],
      ),
    );
  }

  Widget _buildRmsValue(
    String label,
    double? value,
    Color color, {
    required SkotiqColors colors,
    bool bold = false,
    bool compact = false,
  }) {
    final fontSize = compact ? 10.0 : 12.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label:',
          style: TextStyle(color: colors.textSecondary, fontSize: fontSize),
        ),
        const SizedBox(width: 2),
        Text(
          value == null ? '—' : '${value.toStringAsFixed(2)}$rmsUnit',
          style: TextStyle(
            color: value == null ? colors.textMuted : color,
            fontSize: fontSize,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ],
    );
  }

  Widget _buildScaleSelector<T extends GraphScaleOption>({
    required BuildContext context,
    required SkotiqColors colors,
    required String label,
    required String value,
    required List<T> items,
    required void Function(T)? onChanged,
    bool compact = false,
    String Function(T item)? labelOf,
  }) {
    final itemLabel = labelOf ?? (T item) => item.label;
    final fontSize = compact ? 10.0 : 12.0;
    final padding = compact
        ? const EdgeInsets.symmetric(horizontal: 6, vertical: 3)
        : const EdgeInsets.symmetric(horizontal: 8, vertical: 4);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(color: colors.textSecondary, fontSize: fontSize),
        ),
        const SizedBox(width: 4),
        PopupMenuButton<T>(
          initialValue: items.firstWhere(
            (item) => itemLabel(item) == value,
            orElse: () => items.first,
          ),
          onSelected: onChanged,
          // The PAINTED pill keeps its compact 21dp height; only the hit box is
          // floored to the platform touch minimum. Measured on the guiding
          // screen at all three phone widths, the two selectors this builds
          // ("5m" 46.0x21.0 and the Y-scale "±2\"" 56.0x21.0) were the smallest
          // interactive targets in the app. Same platform rule as
          // SkotiqButton._minInteractiveExtent: grow on touch only, so the
          // dense desktop graph header does not reflow.
          // A PopupMenuButton with a custom child publishes no role of its
          // own, so without this the selector reads as inert static text to
          // assistive tech.
          //
          // The selected scale goes in the NAME, not only in `value`. Naming
          // it `label` alone and leaving the scale to `SemanticsProperties
          // .value` published nothing at all on Linux: `excludeSemantics`
          // drops the child `Text('5m')`, and an AT-SPI probe of the node
          // reported no Value interface and an empty description, so the tree
          // read `button: Time:` and a grep for `5m` / `15m` / `±2"` over the
          // whole guiding screen returned zero — less than the merged
          // `Time: 5m` node this replaced. `value` stays set for the platforms
          // that do read it.
          child: Semantics(
            button: true,
            enabled: true,
            label: '$label $value',
            value: value,
            excludeSemantics: true,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: _touchTargetFloor(context),
                minHeight: _touchTargetFloor(context),
              ),
              child: Center(
                widthFactor: 1,
                child: Container(
                  padding: padding,
                  decoration: BoxDecoration(
                    color: colors.surfaceHover,
                    borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        value,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: fontSize,
                        ),
                      ),
                      Icon(
                        Icons.arrow_drop_down,
                        color: colors.textPrimary,
                        size: compact ? 14 : 16,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          itemBuilder: (context) => items.map((item) {
            return PopupMenuItem<T>(value: item, child: Text(itemLabel(item)));
          }).toList(),
        ),
      ],
    );
  }
}

/// Platform touch minimum for the graph's compact popup selectors.
double _touchTargetFloor(BuildContext context) =>
    SkotiqTouchTarget.minExtent(context);
