part of '../preflight_validation_dialog.dart';

/// The segment bar: one proportional band per simulated node, inside the
/// simulation `well`.
class _SimulationTimeline extends StatelessWidget {
  final SkotiqColors colors;
  final PreSessionSimulationResult simulation;

  const _SimulationTimeline({
    required this.colors,
    required this.simulation,
  });

  /// The bar's height in logical pixels — the same 18px band the visual
  /// timeline uses, so the two read as one instrument.
  static const double barHeight = 18;

  @override
  Widget build(BuildContext context) {
    final totalMs = simulation.duration.inMilliseconds;
    if (totalMs <= 0) return const SizedBox.shrink();

    return ClipRRect(
      borderRadius: SkotiqTokens.borderRadiusXs,
      child: SizedBox(
        height: barHeight,
        child: Row(
          children: [
            for (final segment in simulation.segments)
              Expanded(
                flex: segment.duration.inMilliseconds.clamp(1, totalMs),
                child: Tooltip(
                  message:
                      '${segment.nodeName}: ${DurationFormat.of(segment.duration, style: DurationStyle.compact)}',
                  child: Container(
                    margin: const EdgeInsets.only(right: 1),
                    color: _colorFor(segment),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Color _colorFor(PreSessionSimulationSegment segment) {
    switch (segment.nodeType) {
      case 'TakeExposure':
        return colors.primary;
      case 'SmartExposure':
        return colors.info;
      case 'Autofocus':
        return colors.warning;
      case 'SlewToTarget':
      case 'CenterTarget':
        return colors.success;
      default:
        return colors.textMuted;
    }
  }
}

/// One simulation issue, on the same row metrics as a validation issue.
class _SimulationIssueRow extends StatelessWidget {
  final SkotiqColors colors;
  final PreSessionSimulationIssue issue;

  const _SimulationIssueRow({
    required this.colors,
    required this.issue,
  });

  @override
  Widget build(BuildContext context) {
    final tone = switch (issue.severity) {
      PreSessionSimulationSeverity.error => colors.error,
      PreSessionSimulationSeverity.warning => colors.warning,
      PreSessionSimulationSeverity.info => colors.info,
    };
    final icon = switch (issue.severity) {
      PreSessionSimulationSeverity.error => SkotiqIcons.error,
      PreSessionSimulationSeverity.warning => SkotiqIcons.warning,
      PreSessionSimulationSeverity.info => SkotiqIcons.info,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceXs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: SkotiqTokens.iconGlyphRow, color: tone),
          const SizedBox(width: ListRow.gap),
          Expanded(
            child: Text(
              issue.message,
              style:
                  SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
