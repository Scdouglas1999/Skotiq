import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'adaptive_chart_container.dart';

class ScienceTimelineScrubber extends StatefulWidget {
  final SkotiqColors colors;
  final List<ScienceFrameQualityMetricsRow> frameMetrics;
  final ValueChanged<int?>? onFrameSelected;

  const ScienceTimelineScrubber({
    super.key,
    required this.colors,
    required this.frameMetrics,
    this.onFrameSelected,
  });

  @override
  State<ScienceTimelineScrubber> createState() =>
      _ScienceTimelineScrubberState();
}

class _ScienceTimelineScrubberState extends State<ScienceTimelineScrubber> {
  double _slider = 0;

  @override
  Widget build(BuildContext context) {
    final metrics = widget.frameMetrics.toList(growable: false)
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final hasData = metrics.isNotEmpty;
    final selectedIndex =
        hasData ? _slider.round().clamp(0, metrics.length - 1) : 0;
    final selected = hasData ? metrics[selectedIndex] : null;

    return SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Timeline Scrubber',
            style: SkotiqTypography.bodyStrong
                .copyWith(color: widget.colors.textPrimary),
          ),
          const SizedBox(height: 10),
          if (!hasData)
            AdaptiveChartContainer.fixed(
              height: 100,
              child: Center(
                child: Text(
                  'No frame quality metrics yet.',
                  style: SkotiqTypography.body
                      .copyWith(color: widget.colors.textMuted),
                ),
              ),
            )
          else ...[
            AdaptiveChartContainer(
              minHeight: 48,
              preferredHeight: 54,
              maxHeight: 72,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final plotHeight = constraints.maxHeight;
                  final barSpan = math.max(8.0, plotHeight - 10);
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var i = 0; i < metrics.length; i++)
                        Expanded(
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 1.5),
                            child: Container(
                              height: 8 + _normalized(metrics[i].snr) * barSpan,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(
                                    SkotiqTokens.radiusXs),
                                // Both bar states resolve against the theme:
                                // the selected one reads it directly, the
                                // unselected one is a fixed series hue and
                                // needs the red-night remap to match.
                                color: i == selectedIndex
                                    ? SkotiqChartColors.selectedFrame(
                                        widget.colors)
                                    : SkotiqChartColors.forTheme(
                                        SkotiqChartColors.unselectedFrame(),
                                        widget.colors),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            Slider(
              value: _slider.clamp(0, (metrics.length - 1).toDouble()),
              min: 0,
              max: (metrics.length - 1).toDouble(),
              onChanged: (value) {
                setState(() => _slider = value);
                final idx = value.round().clamp(0, metrics.length - 1);
                widget.onFrameSelected?.call(metrics[idx].capturedImageId);
              },
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    selected == null
                        ? 'Frame --'
                        : 'Frame ${selectedIndex + 1}/${metrics.length}',
                    style: SkotiqTypography.caption
                        .copyWith(color: widget.colors.textSecondary),
                  ),
                ),
                if (selected != null)
                  Text(
                    'SNR ${selected.snr.toStringAsFixed(1)} | Clip H ${selected.highClipPercent.toStringAsFixed(2)}%',
                    style: SkotiqTypography.caption
                        .copyWith(color: widget.colors.textMuted),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  double _normalized(double value) {
    if (!value.isFinite) {
      return 0;
    }
    return (math.log(value.clamp(0.01, 1e9)) / math.ln2 / 8.0).clamp(0.0, 1.0);
  }
}
