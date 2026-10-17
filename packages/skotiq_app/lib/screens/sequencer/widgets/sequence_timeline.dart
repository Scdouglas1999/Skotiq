import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
// Hide TwilightTimes from the core barrel — scheduler's sky_calculations
// exports its own; this widget consumes the planetarium's TwilightTimes via
// AstronomyCalculations.calculateTwilightTimes(...).
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

part 'sequence_timeline/segment_and_mini.dart';
part 'sequence_timeline/full_timeline.dart';
part 'sequence_timeline/supporting_widgets.dart';

/// A horizontal timeline visualization of the sequence
class SequenceTimeline extends ConsumerWidget {
  final SkotiqColors colors;
  final bool showMiniVersion;

  /// Optional start time for the sequence. If provided, the timeline will show
  /// actual clock times. If null, shows relative times from 0:00.
  final DateTime? startTime;

  /// Whether to show astronomical overlay bands (twilight zones)
  final bool showAstronomicalOverlay;

  const SequenceTimeline({
    required this.colors,
    this.showMiniVersion = false,
    this.startTime,
    this.showAstronomicalOverlay = true,
    super.key,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sequence = ref.watch(currentSequenceProvider);
    final executionState = ref.watch(sequenceExecutionStateProvider);

    if (sequence == null || sequence.nodes.isEmpty) {
      return _buildEmptyState();
    }

    final isRunning = executionState == SequenceExecutionState.running ||
        executionState == SequenceExecutionState.paused;

    final sessionStart =
        isRunning ? ref.watch(sessionStateProvider).startTime : null;
    final timelineStart = startTime ?? sessionStart ?? DateTime.now();
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final hasLocation = settings != null && settings.hasObserverLocation;
    final estimator = SequenceTimeEstimator(
      overhead: ref.watch(sequencerOverheadConfigProvider),
    );
    final segments = _buildTimelineSegments(
      sequence,
      estimator,
      timelineStart,
      latitude: hasLocation ? settings.latitude : null,
      longitude: hasLocation ? settings.longitude : null,
    );
    final totalDuration = estimator
            .estimateTotalDuration(
              sequence,
              timelineStart,
              latitude: hasLocation ? settings.latitude : null,
              longitude: hasLocation ? settings.longitude : null,
            )
            .inMilliseconds /
        1000.0;

    final renderedDuration = segments.fold<double>(
      0,
      (total, segment) => total + segment.duration,
    );
    final unexpandedDuration = totalDuration - renderedDuration;
    if (unexpandedDuration > 0.001) {
      segments.add(
        TimelineSegment(
          nodeId: '__unexpanded_time__',
          name: 'Scheduled or repeated time',
          duration: unexpandedDuration,
          type: TimelineSegmentType.instruction,
        ),
      );
    }

    if (showMiniVersion) {
      return _MiniTimeline(
        colors: colors,
        segments: segments,
        totalDuration: totalDuration,
        isRunning: isRunning,
      );
    }

    return _FullTimeline(
      colors: colors,
      segments: segments,
      totalDuration: totalDuration,
      isRunning: isRunning,
      startTime: startTime,
      showAstronomicalOverlay: showAstronomicalOverlay,
      sequence: sequence,
    );
  }

  Widget _buildEmptyState() {
    return Container(
      height: 60,
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: Center(
        child: Text(
          'No sequence nodes to visualize',
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize12,
            color: colors.textMuted,
          ),
        ),
      ),
    );
  }

  List<TimelineSegment> _buildTimelineSegments(
    Sequence sequence,
    SequenceTimeEstimator estimator,
    DateTime timelineStart, {
    double? latitude,
    double? longitude,
  }) {
    final timings = estimator.estimateSequenceTiming(
      sequence,
      timelineStart,
      latitude: latitude,
      longitude: longitude,
    );
    final segments = <TimelineSegment>[];
    var cursor = timelineStart;
    for (final timing in timings) {
      if (timing.estimatedStart.isAfter(cursor)) {
        segments.add(
          TimelineSegment(
            nodeId: '__gap_${segments.length}__',
            name: 'Scheduled or repeated time',
            duration:
                timing.estimatedStart.difference(cursor).inMilliseconds / 1000,
            type: TimelineSegmentType.wait,
          ),
        );
      }
      if (timing.duration.inMilliseconds > 0) {
        segments.add(_segmentForTiming(sequence, timing));
      }
      if (timing.estimatedEnd.isAfter(cursor)) cursor = timing.estimatedEnd;
    }
    return segments;
  }

  TimelineSegment _segmentForTiming(Sequence sequence, NodeTiming timing) {
    final node = sequence.nodes[timing.nodeId];
    final type = switch (node) {
      ExposureNode() || SmartExposureNode() => TimelineSegmentType.exposure,
      AutofocusNode() => TimelineSegmentType.focus,
      DitherNode() => TimelineSegmentType.dither,
      DelayNode() || WaitTimeNode() => TimelineSegmentType.wait,
      SlewNode() || CenterNode() => TimelineSegmentType.slew,
      MeridianFlipNode() => TimelineSegmentType.flip,
      FilterChangeNode() => TimelineSegmentType.filter,
      _ => TimelineSegmentType.instruction,
    };
    final customColor = node is ExposureNode && node.filter != null
        ? _getFilterColor(node.filter!)
        : null;
    return TimelineSegment(
      nodeId: timing.nodeId,
      name: timing.nodeName,
      duration: timing.duration.inMilliseconds / 1000.0,
      type: type,
      customColor: customColor,
    );
  }

  Color? _getFilterColor(String filter) {
    switch (filter.toLowerCase()) {
      case 'l':
      case 'luminance':
        return const Color(0xFFFFFFFF);
      case 'r':
      case 'red':
        return const Color(0xFFEF4444);
      case 'g':
      case 'green':
        return const Color(0xFF22C55E);
      case 'b':
      case 'blue':
        return const Color(0xFF3B82F6);
      case 'ha':
      case 'h-alpha':
        return const Color(0xFFB91C1C);
      case 'oiii':
        return const Color(0xFF14B8A6);
      case 'sii':
        return const Color(0xFFEA580C);
      default:
        return null;
    }
  }
}
