import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../tours/tour_target.dart';
import 'session_chart.dart';

/// The four charts of a session's accepted light frames (HFR, guiding RMS,
/// focuser position, sensor temperature) under a line saying which frames
/// they plot, or one panel saying there is nothing to plot.
class SessionChartGrid extends StatelessWidget {
  const SessionChartGrid({
    super.key,
    required this.frames,
    required this.stacked,
    this.tourTargets = false,
  });

  /// Every frame of the session; the charts plot the accepted lights.
  final List<DbCapturedImage> frames;

  /// One chart per row (phone) rather than two.
  final bool stacked;

  /// Whether the charts carry the tutorial's spotlight keys. Only one grid on
  /// screen may.
  final bool tourTargets;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final images = sessionChartFrames(frames);
    final excluded = frames.length - images.length;
    final anythingToPlot = images.any(
      (image) =>
          image.hfr != null ||
          image.guidingRmsTotal != null ||
          image.focuserPosition != null ||
          image.sensorTemp != null,
    );
    if (!anythingToPlot) {
      return _NothingToChart(accepted: images.length, excluded: excluded);
    }
    final hfr = HfrChart(
      key: tourTargets ? TourTarget.analyticsHfrChart.key : null,
      images: images,
    );
    final guiding = GuidingRmsChart(
      key: tourTargets ? TourTarget.analyticsGuidingChart.key : null,
      images: images,
    );
    final focuser = FocuserPositionChart(images: images);
    final temperature = TemperatureChart(images: images);
    final population = Container(
      width: double.infinity,
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceMd),
      child: Text(
        excluded == 0
            ? 'All four charts plot the same ${images.length} accepted light frames.'
            : 'All four charts plot the same ${images.length} accepted light frames '
                '· $excluded excluded (rejected or calibration)',
        style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
      ),
    );
    const gap = SizedBox(
      height: SkotiqTokens.spaceLg,
      width: SkotiqTokens.spaceLg,
    );

    if (stacked) {
      return Column(
        children: [population, hfr, gap, guiding, gap, focuser, gap, temperature],
      );
    }
    return Column(
      children: [
        population,
        Row(children: [Expanded(child: hfr), gap, Expanded(child: guiding)]),
        gap,
        Row(
          children: [Expanded(child: focuser), gap, Expanded(child: temperature)],
        ),
      ],
    );
  }
}

class _NothingToChart extends StatelessWidget {
  const _NothingToChart({required this.accepted, required this.excluded});

  /// Accepted light frames in the session.
  final int accepted;

  /// Frames left out of the charts: rejected lights and calibration frames.
  final int excluded;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final what = accepted == 0
        ? 'No accepted light frames to chart'
        : 'None of the $accepted accepted light frames recorded HFR, '
            'guiding RMS, focuser position or sensor temperature';
    return SkotiqPanel(
      child: Row(
        children: [
          Icon(
            LucideIcons.lineChart,
            size: SkotiqTokens.iconSm,
            color: colors.textMuted,
          ),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: Text(
              excluded == 0
                  ? what
                  : '$what · $excluded excluded (rejected or calibration)',
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
