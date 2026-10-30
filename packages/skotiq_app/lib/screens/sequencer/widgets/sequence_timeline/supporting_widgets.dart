part of '../sequence_timeline.dart';

/// Helper class for twilight regions
class _TwilightRegion {
  final double startFraction;
  final double endFraction;
  final Color color;

  const _TwilightRegion({
    required this.startFraction,
    required this.endFraction,
    required this.color,
  });
}

/// Individual block in the timeline
class _TimelineBlock extends StatefulWidget {
  final SkotiqColors colors;
  final TimelineSegment segment;

  const _TimelineBlock({
    required this.colors,
    required this.segment,
  });

  @override
  State<_TimelineBlock> createState() => _TimelineBlockState();
}

class _TimelineBlockState extends State<_TimelineBlock> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final color = _getSegmentColor();

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Tooltip(
        message: '${widget.segment.name}\n${_formatSegmentDuration()}',
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(horizontal: 0.5),
          decoration: BoxDecoration(
            color: _isHovered ? color : color.withValues(alpha: 0.7),
            border: _isHovered
                ? Border.all(
                    // absolute: lightening hover ring over the data-colored segment
                    color: ImageOverlayColors.foreground.withValues(alpha: 0.5),
                    width: 1)
                : null,
          ),
          child: widget.segment.duration > 60
              ? Center(
                  child: Text(
                    _getShortLabel(),
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize9,
                      fontWeight: FontWeight.w600,
                      // absolute: label over the data-colored segment fill (legibility)
                      color:
                          ImageOverlayColors.foreground.withValues(alpha: 0.9),
                    ),
                    overflow: TextOverflow.clip,
                  ),
                )
              : null,
        ),
      ),
    );
  }

  Color _getSegmentColor() {
    if (widget.segment.customColor != null) {
      return widget.segment.customColor!;
    }

    switch (widget.segment.type) {
      case TimelineSegmentType.exposure:
        return widget.colors.primary;
      case TimelineSegmentType.focus:
        return widget.colors.warning;
      case TimelineSegmentType.dither:
        return widget.colors.info;
      case TimelineSegmentType.wait:
        return widget.colors.textMuted;
      case TimelineSegmentType.slew:
        return widget.colors.accent;
      case TimelineSegmentType.flip:
        return widget.colors.error;
      case TimelineSegmentType.filter:
        return widget.colors.success;
      case TimelineSegmentType.instruction:
        return widget.colors.textSecondary;
    }
  }

  String _getShortLabel() {
    switch (widget.segment.type) {
      case TimelineSegmentType.exposure:
        return 'EXP';
      case TimelineSegmentType.focus:
        return 'AF';
      case TimelineSegmentType.dither:
        return 'D';
      case TimelineSegmentType.wait:
        return 'W';
      case TimelineSegmentType.slew:
        return 'SLW';
      case TimelineSegmentType.flip:
        return 'MF';
      case TimelineSegmentType.filter:
        return 'F';
      case TimelineSegmentType.instruction:
        return '';
    }
  }

  String _formatSegmentDuration() {
    final secs = widget.segment.duration;
    if (secs >= 3600) {
      return '${(secs / 3600).toStringAsFixed(1)}h';
    } else if (secs >= 60) {
      return '${(secs / 60).toStringAsFixed(0)}m';
    }
    return '${secs.toStringAsFixed(0)}s';
  }
}

/// Legend item
class _LegendItem extends StatelessWidget {
  final SkotiqColors colors;
  final Color color;
  final String label;

  const _LegendItem({
    required this.colors,
    required this.color,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline2),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize10,
            color: colors.textMuted,
          ),
        ),
      ],
    );
  }
}
