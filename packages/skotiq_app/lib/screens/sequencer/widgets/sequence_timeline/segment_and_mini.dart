part of '../sequence_timeline.dart';

/// Type of timeline segment
enum TimelineSegmentType {
  exposure,
  focus,
  dither,
  wait,
  slew,
  flip,
  filter,
  instruction,
}

/// A segment in the timeline
class TimelineSegment {
  final String nodeId;
  final String name;
  final double duration; // seconds
  final TimelineSegmentType type;
  final Color? customColor;

  const TimelineSegment({
    required this.nodeId,
    required this.name,
    required this.duration,
    required this.type,
    this.customColor,
  });
}

/// Mini timeline for bottom status bar
class _MiniTimeline extends StatelessWidget {
  final SkotiqColors colors;
  final List<TimelineSegment> segments;
  final double totalDuration;
  final bool isRunning;

  const _MiniTimeline({
    required this.colors,
    required this.segments,
    required this.totalDuration,
    required this.isRunning,
  });

  @override
  Widget build(BuildContext context) {
    if (totalDuration == 0) {
      return const SizedBox.shrink();
    }

    return Container(
      height: 16,
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
        child: Row(
          children: segments.map((segment) {
            final widthFraction = segment.duration / totalDuration;
            return Expanded(
              flex: (widthFraction * 1000).round().clamp(1, 1000),
              child: Container(
                color: _getSegmentColor(segment),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Color _getSegmentColor(TimelineSegment segment) {
    if (segment.customColor != null) {
      return segment.customColor!.withValues(alpha: 0.7);
    }

    switch (segment.type) {
      case TimelineSegmentType.exposure:
        return colors.primary.withValues(alpha: 0.7);
      case TimelineSegmentType.focus:
        return colors.warning.withValues(alpha: 0.7);
      case TimelineSegmentType.dither:
        return colors.info.withValues(alpha: 0.7);
      case TimelineSegmentType.wait:
        return colors.textMuted.withValues(alpha: 0.5);
      case TimelineSegmentType.slew:
        return colors.accent.withValues(alpha: 0.7);
      case TimelineSegmentType.flip:
        return colors.error.withValues(alpha: 0.5);
      case TimelineSegmentType.filter:
        return colors.success.withValues(alpha: 0.7);
      case TimelineSegmentType.instruction:
        return colors.textSecondary.withValues(alpha: 0.55);
    }
  }
}
