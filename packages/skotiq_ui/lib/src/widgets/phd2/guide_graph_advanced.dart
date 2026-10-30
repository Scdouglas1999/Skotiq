import '../../theme/skotiq_tokens.dart';
import 'package:flutter/material.dart';

import '../../theme/skotiq_colors.dart';
import '../../theme/skotiq_typography.dart';
import '../../utils/touch_target.dart';

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
            child: LayoutBuilder(
              builder: (context, constraints) {
                return CustomPaint(
                  size: Size(constraints.maxWidth, constraints.maxHeight),
                  painter: _GraphPainter(
                    colors: colors,
                    data: data,
                    timeScale: timeScale,
                    yScale: yScale,
                    showRa: showRa,
                    showDec: showDec,
                    showPulses: showPulses,
                    valueUnit: valueUnit,
                  ),
                );
              },
            ),
          ),
        ),
      ],
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
                value: yScale.label,
                items: GraphYScale.values,
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
  }) {
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
            (item) => item.label == value,
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
            return PopupMenuItem<T>(value: item, child: Text(item.label));
          }).toList(),
        ),
      ],
    );
  }
}

/// Platform touch minimum for the graph's compact popup selectors.
double _touchTargetFloor(BuildContext context) =>
    SkotiqTouchTarget.minExtent(context);

class _GraphPainter extends CustomPainter {
  final SkotiqColors colors;
  final List<GuideDataPoint> data;
  final GraphTimeScale timeScale;
  final GraphYScale yScale;
  final bool showRa;
  final bool showDec;
  final bool showPulses;

  /// Unit suffix for the Y-axis labels. The scale steps themselves are
  /// unit-agnostic numbers; the caller says whether the errors it supplied are
  /// arcseconds or guide-camera pixels.
  final String valueUnit;

  static const double leftMargin = 35;
  static const double bottomMargin = 20;
  static const double topMargin = 5;
  static const double rightMargin = 5;

  /// Clear space required between two stacked Y-axis labels.
  static const double _yLabelGap = 2;

  /// How many ticks to step between drawn Y-axis labels, or null when even the
  /// thinnest set would not clear [_yLabelGap].
  ///
  /// The plot area collapses hard on a phone — the panel header, the scale
  /// selector row and the card gutters take a fixed slice out of the graph
  /// pane, so a banner-squeezed viewport can leave under 20 dp of plot. All
  /// five labels drawn there stacked `±2" / 1.0" / 0 / -1.0" / -2"` into one
  /// illegible smear. Thinning to the extremes-plus-zero (and then to nothing)
  /// keeps whatever is drawn readable at any height, and measuring the laid-out
  /// label rather than assuming its size keeps that true at any text scale.
  ///
  /// Strides are restricted to divisors of [divisions] so the first and last
  /// tick — the ones that name the scale — are always among those drawn.
  static int? _yAxisLabelStride({
    required double graphHeight,
    required int divisions,
    required double labelHeight,
  }) {
    final pitch = graphHeight / divisions;
    for (final stride in const [1, 2]) {
      if (divisions % stride != 0) continue;
      if (pitch * stride >= labelHeight + _yLabelGap) return stride;
    }
    return null;
  }

  _GraphPainter({
    required this.colors,
    required this.data,
    required this.timeScale,
    required this.yScale,
    required this.showRa,
    required this.showDec,
    required this.showPulses,
    required this.valueUnit,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final graphRect = Rect.fromLTRB(
      leftMargin,
      topMargin,
      size.width - rightMargin,
      size.height - bottomMargin,
    );

    // Draw background and grid
    _drawGrid(canvas, size, graphRect);

    // Draw Y-axis labels
    _drawYAxisLabels(canvas, graphRect);

    // Draw X-axis labels
    _drawXAxisLabels(canvas, size, graphRect);

    // Clip to graph area
    canvas.save();
    canvas.clipRect(graphRect);

    // Draw data traces
    if (data.isNotEmpty) {
      if (showRa) {
        _drawTrace(canvas, graphRect, true);
      }
      if (showDec) {
        _drawTrace(canvas, graphRect, false);
      }
    }

    canvas.restore();
  }

  void _drawGrid(Canvas canvas, Size size, Rect graphRect) {
    final paint = Paint()
      ..color = colors.border.withValues(alpha: 0.8)
      ..strokeWidth = 0.5;

    // Draw vertical grid lines (time divisions)
    const numVerticalLines = 4;
    for (int i = 0; i <= numVerticalLines; i++) {
      final x = graphRect.left + (graphRect.width / numVerticalLines) * i;
      canvas.drawLine(
        Offset(x, graphRect.top),
        Offset(x, graphRect.bottom),
        paint,
      );
    }

    // Draw horizontal grid lines (error divisions)
    const numHorizontalLines = 4;
    for (int i = 0; i <= numHorizontalLines; i++) {
      final y = graphRect.top + (graphRect.height / numHorizontalLines) * i;
      // Highlight zero line
      if (i == numHorizontalLines ~/ 2) {
        paint.color = colors.borderHighlight;
        paint.strokeWidth = 1;
      } else {
        paint.color = colors.border.withValues(alpha: 0.8);
        paint.strokeWidth = 0.5;
      }
      canvas.drawLine(
        Offset(graphRect.left, y),
        Offset(graphRect.right, y),
        paint,
      );
    }
  }

  void _drawYAxisLabels(Canvas canvas, Rect graphRect) {
    if (graphRect.height <= 0) return;

    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    // A canvas TextStyle inherits nothing, so the family has to be named here
    // or these tick labels render in whatever the platform default is instead
    // of the app's type. They are numerics, so they take the mono face every
    // other readout uses.
    final style = TextStyle(
      color: colors.textMuted,
      fontSize: SkotiqTypography.fontSize9,
      fontFamily: SkotiqTypography.fontFamilyMono,
    );

    final labels = [
      '+${yScale.arcsec.toStringAsFixed(0)}$valueUnit',
      '+${(yScale.arcsec / 2).toStringAsFixed(1)}$valueUnit',
      '0',
      '-${(yScale.arcsec / 2).toStringAsFixed(1)}$valueUnit',
      '-${yScale.arcsec.toStringAsFixed(0)}$valueUnit',
    ];

    textPainter.text = TextSpan(text: labels.first, style: style);
    textPainter.layout();
    final labelHeight = textPainter.height;

    final divisions = labels.length - 1;
    final stride = _yAxisLabelStride(
      graphHeight: graphRect.height,
      divisions: divisions,
      labelHeight: labelHeight,
    );
    if (stride == null) return;

    for (int i = 0; i <= divisions; i += stride) {
      textPainter.text = TextSpan(text: labels[i], style: style);
      textPainter.layout();

      final y = graphRect.top + (graphRect.height / divisions) * i;
      textPainter.paint(canvas, Offset(2, y - textPainter.height / 2));
    }
  }

  void _drawXAxisLabels(Canvas canvas, Size size, Rect graphRect) {
    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    // The X axis is elapsed time relative to *now*, which sits at the right
    // edge (matching how _drawTrace positions points across `timeScale`):
    // counting back from 0 on the right to -timeScale on the left keeps the
    // newest sample at "now" and scrolls older ones left. This is the PHD2 /
    // NINA convention, and it is stable across repaints — wall-clock MM:SS
    // labels recomputed from DateTime.now() appear to tick up instead.
    final totalSeconds = timeScale.duration.inSeconds;
    const numLabels = 5;

    for (int i = 0; i < numLabels; i++) {
      // i == 0 is the left edge (oldest, -totalSeconds); the last index is the
      // right edge (newest, 0s).
      final secondsAgo = (totalSeconds * (numLabels - 1 - i) / (numLabels - 1))
          .round();
      final label = secondsAgo == 0 ? '0s' : '-${_formatElapsed(secondsAgo)}';

      textPainter.text = TextSpan(
        text: label,
        style: TextStyle(
          color: colors.textMuted,
          fontSize: SkotiqTypography.fontSize9,
          fontFamily: SkotiqTypography.fontFamilyMono,
        ),
      );
      textPainter.layout();

      final x = graphRect.left + (graphRect.width / (numLabels - 1)) * i;
      textPainter.paint(
        canvas,
        Offset(x - textPainter.width / 2, graphRect.bottom + 4),
      );
    }
  }

  /// Format an elapsed-second count for an X-axis tick. Sub-minute spans read
  /// as plain seconds ("30s"); minute-or-longer spans read as "m:ss" so the
  /// 15m / 30m scales stay compact and legible.
  String _formatElapsed(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final minutes = seconds ~/ 60;
    final remSeconds = seconds % 60;
    if (remSeconds == 0) return '${minutes}m';
    return '$minutes:${remSeconds.toString().padLeft(2, '0')}';
  }

  void _drawTrace(Canvas canvas, Rect graphRect, bool isRa) {
    if (data.isEmpty) return;

    final paint = Paint()
      ..color = isRa ? colors.error : colors.info
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;

    final path = Path();
    final now = DateTime.now();
    final startTime = now.subtract(timeScale.duration);
    bool first = true;

    for (final point in data) {
      if (point.timestamp.isBefore(startTime)) continue;

      final timeFraction =
          point.timestamp.difference(startTime).inMilliseconds /
          timeScale.duration.inMilliseconds;
      final x = graphRect.left + graphRect.width * timeFraction.clamp(0.0, 1.0);

      final error = isRa ? point.raError : point.decError;
      final errorFraction = (error / yScale.arcsec).clamp(-1.0, 1.0);
      final y =
          graphRect.top +
          graphRect.height / 2 -
          (errorFraction * graphRect.height / 2);

      if (first) {
        path.moveTo(x, y);
        first = false;
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_GraphPainter oldDelegate) {
    return data != oldDelegate.data ||
        colors != oldDelegate.colors ||
        timeScale != oldDelegate.timeScale ||
        yScale != oldDelegate.yScale ||
        showRa != oldDelegate.showRa ||
        showDec != oldDelegate.showDec ||
        valueUnit != oldDelegate.valueUnit;
  }
}
