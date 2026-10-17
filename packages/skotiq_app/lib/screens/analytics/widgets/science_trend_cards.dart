import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'adaptive_chart_container.dart';
import 'chart_axis.dart';

/// Card: Zero-Point trend across the current session.
///
/// Y axis is mag (higher is better — fainter stars detectable). The line
/// is drawn from all calibrated frames in chronological order, with the
/// uncalibrated frames dropped on the floor so the trend reflects what
/// the photometric model actually believes about the sky tonight.
///
/// Why this matters: a smoothly rising ZP across the night says
/// transparency is improving (or you came out of moonlight or twilight);
/// a sudden drop says clouds rolled in. NINA/SGP plot HFR over time but
/// neither plots ZP.
class ZeroPointTrendCard extends StatelessWidget {
  final SkotiqColors colors;
  final List<FramePhotometricCalibrationRow> calibrations;

  const ZeroPointTrendCard({
    super.key,
    required this.colors,
    required this.calibrations,
  });

  @override
  Widget build(BuildContext context) {
    final points = <_TrendPoint>[];
    for (final c in calibrations) {
      final zp = c.zeroPoint;
      if (zp == null || !zp.isFinite || !c.isCalibrated) continue;
      points.add(_TrendPoint(c.timestamp, zp));
    }
    points.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    return _TrendCardShell(
      colors: colors,
      icon: LucideIcons.gauge,
      title: 'Zero point over time',
      subtitle:
          'Higher = fainter stars detectable at the same exposure. Rises mean '
          'transparency is improving; sudden drops typically indicate '
          'clouds.',
      points: points,
      lineColor: colors.success,
      yLabel: 'ZP (mag)',
      formatY: (v) => v.toStringAsFixed(2),
      emptyMessage:
          'No calibrated frames yet. The trend appears once at least one '
          'frame fits a photometric model.',
    );
  }
}

/// Card: rolling plate-solve success rate across the current session.
///
/// Computed as a sliding window (default 8 frames) over the captured-image
/// stream — at frame N the value is the fraction of the last 8 frames
/// that returned a WCS. This is much more diagnostic than the raw cumulative
/// rate because it shows *when* solving started failing, which is usually
/// the moment clouds appeared or guiding drifted past tolerance.
/// HFR trend from accepted light frames (classic session quality metric).
class HfrTrendCard extends StatelessWidget {
  final SkotiqColors colors;
  final List<DbCapturedImage> lightFrames;

  const HfrTrendCard({
    super.key,
    required this.colors,
    required this.lightFrames,
  });

  @override
  Widget build(BuildContext context) {
    final points = <_TrendPoint>[];
    final sorted = lightFrames
        .where((img) => img.isAccepted && img.hfr != null)
        .toList(growable: false)
      ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
    for (final img in sorted) {
      points.add(_TrendPoint(img.capturedAt, img.hfr!));
    }

    // Frames that DO carry star metrics and were left out because the grader
    // rejected them. Saying "HFR appears once star metrics are recorded" for
    // those sends the user hunting a star-detection problem that is not there.
    final rejectedWithHfr =
        lightFrames.where((img) => !img.isAccepted && img.hfr != null).length;

    return _TrendCardShell(
      colors: colors,
      icon: LucideIcons.focus,
      title: 'HFR over time',
      subtitle:
          'Half-flux radius of detected stars per frame. Spikes usually mean '
          'focus drift, seeing degradation, or clouds. '
          '${_populationNote(rejectedWithHfr)}',
      points: points,
      lineColor: colors.warning,
      yLabel: 'HFR (px)',
      formatY: (v) => v.toStringAsFixed(2),
      emptyMessage: rejectedWithHfr > 0
          ? 'No accepted frames with star metrics — '
              '$rejectedWithHfr frame${rejectedWithHfr == 1 ? '' : 's'} '
              'with HFR ${rejectedWithHfr == 1 ? 'was' : 'were'} rejected.'
          : 'HFR appears once star metrics are recorded on captures.',
    );
  }
}

/// Uniformity CV trend from frame-quality maps.
class UniformityTrendCard extends StatelessWidget {
  final SkotiqColors colors;
  final List<ScienceFrameQualityMetricsRow> frameMetrics;

  /// Frames the user rejected. Their metrics rows are dropped so this card and
  /// [HfrTrendCard] beside it describe the same frames.
  final Set<int> rejectedImageIds;

  const UniformityTrendCard({
    super.key,
    required this.colors,
    required this.frameMetrics,
    this.rejectedImageIds = const {},
  });

  @override
  Widget build(BuildContext context) {
    final points = <_TrendPoint>[];
    var excluded = 0;
    final sorted = frameMetrics.toList(growable: false)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    for (final m in sorted) {
      if (!m.uniformityCv.isFinite) continue;
      final imageId = m.capturedImageId;
      if (imageId != null && rejectedImageIds.contains(imageId)) {
        excluded++;
        continue;
      }
      points.add(_TrendPoint(m.timestamp, m.uniformityCv));
    }

    return _TrendCardShell(
      colors: colors,
      icon: LucideIcons.layoutGrid,
      title: 'Field uniformity (CV)',
      subtitle:
          'Background brightness coefficient of variation. Values above ~0.28 '
          'often indicate gradients from vignetting or moon glow. '
          '${_populationNote(excluded)}',
      points: points,
      lineColor: colors.primary,
      yLabel: 'CV',
      formatY: (v) => v.toStringAsFixed(3),
      emptyMessage: excluded > 0
          ? 'No accepted frames with uniformity maps — '
              '$excluded frame${excluded == 1 ? '' : 's'} '
              '${excluded == 1 ? 'was' : 'were'} rejected.'
          : 'Uniformity maps appear once frame-quality processing is enabled.',
    );
  }
}

/// Names the population the Field Quality cards plot, and how many frames the
/// grader kept out of it. Both cards carry it so the section reads as one
/// statement instead of two charts over different frames.
String _populationNote(int excluded) {
  if (excluded <= 0) return 'Accepted frames only.';
  return 'Accepted frames only ($excluded rejected, not plotted).';
}

class SolveRateTrendCard extends StatelessWidget {
  final SkotiqColors colors;
  final List<DbCapturedImage> lightFrames;
  final int windowSize;

  const SolveRateTrendCard({
    super.key,
    required this.colors,
    required this.lightFrames,
    this.windowSize = 8,
  });

  @override
  Widget build(BuildContext context) {
    final sorted = lightFrames.toList(growable: false)
      ..sort((a, b) => a.capturedAt.compareTo(b.capturedAt));
    final points = <_TrendPoint>[];
    if (sorted.length >= 2) {
      for (var i = 0; i < sorted.length; i++) {
        final start = math.max(0, i + 1 - windowSize);
        final window = sorted.sublist(start, i + 1);
        final solved =
            window.where((img) => img.isPlateSolved).length / window.length;
        points.add(_TrendPoint(sorted[i].capturedAt, solved * 100.0));
      }
    }

    return _TrendCardShell(
      colors: colors,
      icon: LucideIcons.crosshair,
      title: 'Plate-solve rate (rolling)',
      subtitle:
          'Fraction of the last $windowSize frames that solved. A dip is the '
          'fastest indicator that clouds, guiding excursions, or focus drift '
          'are starting to affect the session.',
      points: points,
      lineColor: colors.info,
      yLabel: 'Solve rate (%)',
      minY: 0,
      maxY: 100,
      formatY: (v) => '${v.toStringAsFixed(0)}%',
      emptyMessage:
          'Need at least 2 light frames before a rolling solve-rate trend '
          'is meaningful.',
    );
  }
}

class _TrendPoint {
  final DateTime timestamp;
  final double value;
  _TrendPoint(this.timestamp, this.value);
}

class _TrendCardShell extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String title;
  final String subtitle;
  final List<_TrendPoint> points;
  final Color lineColor;
  final String yLabel;
  final String Function(double) formatY;
  final double? minY;
  final double? maxY;
  final String emptyMessage;

  const _TrendCardShell({
    required this.colors,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.points,
    required this.lineColor,
    required this.yLabel,
    required this.formatY,
    required this.emptyMessage,
    this.minY,
    this.maxY,
  });

  @override
  Widget build(BuildContext context) {
    return SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: lineColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: SkotiqTypography.bodyStrong
                      .copyWith(color: colors.textPrimary),
                ),
              ),
              if (points.isNotEmpty)
                _LatestPill(
                  colors: colors,
                  label: formatY(points.last.value),
                  color: lineColor,
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: SkotiqTypography.caption
                .copyWith(color: colors.textSecondary, height: 1.4),
          ),
          const SizedBox(height: 12),
          AdaptiveChartContainer(
            preferredHeight: 160,
            child: points.length < 2
                ? _Placeholder(colors: colors, message: emptyMessage)
                : _buildChart(),
          ),
        ],
      ),
    );
  }

  Widget _buildChart() {
    final firstTs = points.first.timestamp;
    final spots = points
        .map((p) => FlSpot(
              p.timestamp.difference(firstTs).inSeconds.toDouble(),
              p.value,
            ))
        .toList();

    final values = points.map((p) => p.value);
    final dataMin = values.reduce(math.min);
    final dataMax = values.reduce(math.max);
    // Snap the axis to tick multiples: with bounds at data +/- 10% and ticks at
    // range/4, fl_chart's boundary label landed a sliver from the outermost
    // tick and the two drew on top of each other ("21.21" over "21.20" on the
    // zero-point card).
    final axis =
        NiceAxis.forRange(minY ?? dataMin, maxY ?? dataMax, padFraction: 0.1);
    final effectiveMinY = minY ?? axis.min;
    final effectiveMaxY = maxY ?? axis.max;
    final yInterval = axis.interval;
    final lastX = spots.last.x == 0 ? 1.0 : spots.last.x;
    // Exact division puts the final tick on the axis end.
    final xInterval = lastX / 4;

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: lastX,
        minY: effectiveMinY,
        maxY: effectiveMaxY,
        borderData: FlBorderData(
          show: true,
          border: Border.all(color: colors.border),
        ),
        gridData: FlGridData(
          horizontalInterval: yInterval,
          verticalInterval: xInterval,
          getDrawingHorizontalLine: (_) =>
              FlLine(color: colors.border.withValues(alpha: 0.3)),
          getDrawingVerticalLine: (_) =>
              FlLine(color: colors.border.withValues(alpha: 0.2)),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: xInterval,
              getTitlesWidget: (value, meta) {
                return Text(
                  elapsedAxisLabel(value),
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textSecondary),
                );
              },
            ),
          ),
          leftTitles: AxisTitles(
            axisNameWidget: Text(
              yLabel,
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textSecondary),
            ),
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 42,
              interval: yInterval,
              getTitlesWidget: (value, meta) => Text(
                formatY(value),
                style: SkotiqTypography.caption
                    .copyWith(color: colors.textSecondary),
              ),
            ),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            color: lineColor,
            barWidth: 2,
            isCurved: false,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: lineColor.withValues(alpha: 0.12),
            ),
          ),
        ],
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => colors.surface,
            getTooltipItems: (touched) => touched.map((spot) {
              final mins = (spot.x / 60).round();
              return LineTooltipItem(
                '${formatY(spot.y)}\n${mins}m into session',
                SkotiqTypography.labelQuiet.copyWith(
                  color: colors.textPrimary,
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}

class _LatestPill extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final Color color;

  const _LatestPill({
    required this.colors,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: SkotiqDecorations.chip(colors, tone: color),
      child: Text(
        label,
        style: SkotiqTypography.caption
            .copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  final SkotiqColors colors;
  final String message;

  const _Placeholder({required this.colors, required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: SkotiqTypography.caption
            .copyWith(color: colors.textSecondary, height: 1.4),
      ),
    );
  }
}
