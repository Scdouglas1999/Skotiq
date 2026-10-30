import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart' as planetarium;
import 'package:skotiq_ui/skotiq_ui.dart';

/// Toggle for timeline view visibility.
final timelineVisibleProvider = StateProvider<bool>((ref) => false);

/// Timer-free twilight lookup for sequencer pre-session simulation.
///
/// The planetarium's `twilightTimesProvider` intentionally follows the live
/// observation clock, which starts a periodic timer. The sequencer only needs
/// tonight's dark-window boundary from app settings, so compute it directly.
final preSessionTwilightTimesProvider =
    Provider<planetarium.TwilightTimes?>((ref) {
  final settings = ref.watch(appSettingsProvider).valueOrNull;
  final hasLocation = settings != null && settings.hasObserverLocation;
  if (!hasLocation) return null;

  return planetarium.AstronomyCalculations.calculateTwilightTimes(
    date: DateTime.now(),
    latitudeDeg: settings.latitude,
    longitudeDeg: settings.longitude,
  );
});

/// Provider that computes the shared pre-session simulation timeline.
final sequenceTimelineProvider = Provider<PreSessionSimulationResult?>((ref) {
  final sequence = ref.watch(currentSequenceProvider);
  if (sequence == null) return null;

  final settings = ref.watch(appSettingsProvider).valueOrNull;
  final twilight = ref.watch(preSessionTwilightTimesProvider);
  final hasLocation = settings != null && settings.hasObserverLocation;
  // Shared overhead model — see the same construction in
  // preflight_validation_dialog.dart. Two surfaces describing one sequence
  // must not bill it differently.
  return PreSessionSimulator(
    estimator: SequenceTimeEstimator(
      overhead: ref.watch(sequencerOverheadConfigProvider),
    ),
  ).simulate(
    sequence,
    start: DateTime.now(),
    latitude: hasLocation ? settings.latitude : null,
    longitude: hasLocation ? settings.longitude : null,
    minAltitude: settings?.effectiveHorizonDeg ?? 20.0,
    darkWindowStart: twilight?.astronomicalDusk,
    darkWindowEnd: twilight?.astronomicalDawn,
  );
});

/// Horizontal timeline view showing each node as a colored bar.
/// Width of each bar proportional to estimated duration.
/// Current execution position shown as a vertical line.
class VisualTimeline extends ConsumerWidget {
  final SkotiqColors colors;

  const VisualTimeline({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final simulation = ref.watch(sequenceTimelineProvider);
    final progress = ref.watch(sequenceProgressProvider);
    final sequence = ref.watch(currentSequenceProvider);
    final segments =
        simulation?.segments ?? const <PreSessionSimulationSegment>[];

    if (sequence == null || simulation == null) {
      return Container(
        height: 120,
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(top: BorderSide(color: colors.border)),
        ),
        child: Center(
          child: Text(
            'No timeline data available',
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize12, color: colors.textMuted),
          ),
        ),
      );
    }

    if (segments.isEmpty) {
      if (simulation.issues.isNotEmpty) {
        final firstIssue = simulation.issues.first;
        final issueColor = switch (firstIssue.severity) {
          PreSessionSimulationSeverity.error => colors.error,
          PreSessionSimulationSeverity.warning => colors.warning,
          PreSessionSimulationSeverity.info => colors.info,
        };
        final issueIcon = switch (firstIssue.severity) {
          PreSessionSimulationSeverity.error => LucideIcons.xCircle,
          PreSessionSimulationSeverity.warning => LucideIcons.alertTriangle,
          PreSessionSimulationSeverity.info => LucideIcons.info,
        };
        return Container(
          height: 120,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: colors.surface,
            border: Border(top: BorderSide(color: colors.border)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(issueIcon, size: 16, color: issueColor),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Simulation issue',
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize12,
                        fontWeight: FontWeight.w700,
                        color: issueColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      firstIssue.message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize12,
                        color: colors.textSecondary,
                      ),
                    ),
                    if (simulation.issues.length > 1) ...[
                      const SizedBox(height: 4),
                      Text(
                        '+${simulation.issues.length - 1} more '
                        'issue${simulation.issues.length - 1 == 1 ? '' : 's'}',
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize11,
                          color: colors.textMuted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      }

      return Container(
        height: 120,
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(top: BorderSide(color: colors.border)),
        ),
        child: Center(
          child: Text(
            'No timeline data available',
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize12, color: colors.textMuted),
          ),
        ),
      );
    }

    // Calculate total duration
    final firstStart = simulation.start;
    final lastEnd = simulation.end;
    final totalDuration = simulation.duration;
    final totalSecs = totalDuration.inSeconds.toDouble();

    if (totalSecs <= 0) {
      return Container(
        height: 120,
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border(top: BorderSide(color: colors.border)),
        ),
        child: Center(
          child: Text(
            'Sequence has no estimated duration',
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize12, color: colors.textMuted),
          ),
        ),
      );
    }

    // Each target header gets its own timeline row. The default 140px panel
    // holds up to 6 rows; grow it past that so 7+ targets (e.g. a 3x3
    // distributed mosaic = 9 panels) all render instead of being clipped below
    // the canvas.
    final targetRowCount = segments.map((s) => s.targetHeaderId).toSet().length;
    final panelHeight =
        targetRowCount <= 6 ? 140.0 : 140.0 + (targetRowCount - 6) * 22.0;

    return Container(
      height: panelHeight,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                Icon(LucideIcons.ganttChart, size: 14, color: colors.primary),
                const SizedBox(width: 8),
                Text(
                  'Timeline',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize12,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  _formatTotalDuration(totalDuration),
                  style: TextStyle(
                      fontSize: SkotiqTypography.fontSize11,
                      color: colors.textMuted),
                ),
                const Spacer(),
                // Close button
                GestureDetector(
                  onTap: () {
                    ref.read(timelineVisibleProvider.notifier).state = false;
                  },
                  child: Icon(LucideIcons.x, size: 14, color: colors.textMuted),
                ),
              ],
            ),
          ),

          // Timeline bars - scrollable horizontally
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // The painter spreads the whole night across this width, so a
                // fixed 800px floor squeezed the run into the first fifth of a
                // wide window and left the rest of the panel blank. Fill the
                // viewport first (minus the scroll view's own padding), then
                // grow past it for long sequences.
                final trackWidth = math.max(
                  constraints.maxWidth - 32,
                  (totalSecs / 60 * 4).clamp(800, 4000).toDouble(),
                );
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(
                    width: trackWidth,
                    child: CustomPaint(
                      painter: _TimelinePainter(
                        colors: colors,
                        segments: segments,
                        firstStart: firstStart,
                        totalSecs: totalSecs,
                        progress: progress,
                        sequence: sequence,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                );
              },
            ),
          ),

          // Time axis labels
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  DateFormat('HH:mm').format(firstStart),
                  style: TextStyle(
                      fontSize: SkotiqTypography.fontSize10,
                      color: colors.textMuted),
                ),
                Text(
                  DateFormat('HH:mm').format(
                    firstStart.add(Duration(seconds: (totalSecs / 4).round())),
                  ),
                  style: TextStyle(
                      fontSize: SkotiqTypography.fontSize10,
                      color: colors.textMuted),
                ),
                Text(
                  DateFormat('HH:mm').format(
                    firstStart.add(Duration(seconds: (totalSecs / 2).round())),
                  ),
                  style: TextStyle(
                      fontSize: SkotiqTypography.fontSize10,
                      color: colors.textMuted),
                ),
                Text(
                  DateFormat('HH:mm').format(
                    firstStart
                        .add(Duration(seconds: (totalSecs * 3 / 4).round())),
                  ),
                  style: TextStyle(
                      fontSize: SkotiqTypography.fontSize10,
                      color: colors.textMuted),
                ),
                Text(
                  DateFormat('HH:mm').format(lastEnd),
                  style: TextStyle(
                      fontSize: SkotiqTypography.fontSize10,
                      color: colors.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatTotalDuration(Duration d) {
    final hours = d.inHours;
    final mins = d.inMinutes % 60;
    if (hours > 0) return '${hours}h ${mins}m total';
    return '${mins}m total';
  }
}

class _TimelinePainter extends CustomPainter {
  final SkotiqColors colors;
  final List<PreSessionSimulationSegment> segments;
  final DateTime firstStart;
  final double totalSecs;
  final SequenceProgress progress;
  final Sequence sequence;

  _TimelinePainter({
    required this.colors,
    required this.segments,
    required this.firstStart,
    required this.totalSecs,
    required this.progress,
    required this.sequence,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const topMargin = 4.0;
    final barAreaHeight = size.height - topMargin;

    // Group timings by target header for stacking
    // Each target gets its own row
    final targetGroups = <String?, List<PreSessionSimulationSegment>>{};
    for (final segment in segments) {
      targetGroups.putIfAbsent(segment.targetHeaderId, () => []).add(segment);
    }

    final rowCount = targetGroups.isEmpty ? 1 : targetGroups.length;
    final rowHeight = (barAreaHeight / rowCount).clamp(12.0, 30.0);
    const barGap = 1.0;

    // Draw time grid lines
    _drawTimeGrid(canvas, size, topMargin);

    // Draw bars for each target group
    int rowIndex = 0;
    for (final entry in targetGroups.entries) {
      final y = topMargin + rowIndex * rowHeight;

      for (final segment in entry.value) {
        final startOffset =
            segment.start.difference(firstStart).inSeconds.toDouble();
        final durationSecs = segment.duration.inSeconds.toDouble();

        final x = (startOffset / totalSecs) * size.width;
        final w = ((durationSecs / totalSecs) * size.width)
            .clamp(2.0, double.infinity);

        // Determine color from node category
        final node = sequence.nodes[segment.nodeId];
        Color barColor;
        if (node != null) {
          switch (node.category) {
            case NodeCategory.instruction:
              barColor = colors.primary;
              break;
            case NodeCategory.trigger:
              barColor = colors.warning;
              break;
            case NodeCategory.logic:
              barColor = colors.accent;
              break;
            case NodeCategory.target:
              barColor = colors.warning;
              break;
          }
        } else {
          barColor = colors.textMuted;
        }

        // Highlight based on execution status
        final nodeStatus = progress.nodeStatuses[segment.nodeId];
        if (nodeStatus == NodeStatus.running) {
          barColor = colors.info;
        } else if (nodeStatus == NodeStatus.success) {
          barColor = colors.success;
        } else if (nodeStatus == NodeStatus.failure) {
          barColor = colors.error;
        }

        final rect = Rect.fromLTWH(x, y + barGap, w, rowHeight - barGap * 2);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
              rect, const Radius.circular(SkotiqTokens.radiusXs)),
          Paint()
            ..color = barColor.withValues(alpha: 0.7)
            ..style = PaintingStyle.fill,
        );

        // Draw node name label if bar is wide enough
        if (w > 40) {
          final labelColor =
              ThemeData.estimateBrightnessForColor(barColor) == Brightness.dark
                  ? ImageOverlayColors.foreground
                  : ImageOverlayColors.shadow;
          final textPainter = TextPainter(
            text: TextSpan(
              text: segment.nodeName,
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize9,
                color: labelColor,
                fontWeight: FontWeight.w500,
              ),
            ),
            maxLines: 1,
            textDirection: TextDirection.ltr,
          );
          textPainter.layout(maxWidth: w - 6);
          textPainter.paint(
            canvas,
            Offset(x + 3,
                y + barGap + (rowHeight - barGap * 2 - textPainter.height) / 2),
          );
        }
      }

      rowIndex++;
    }

    // Draw current execution position line
    if (progress.currentNodeId != null) {
      final currentTiming =
          segments.where((t) => t.nodeId == progress.currentNodeId).firstOrNull;
      if (currentTiming != null) {
        final elapsed =
            DateTime.now().difference(currentTiming.start).inSeconds;
        final startOffset =
            currentTiming.start.difference(firstStart).inSeconds.toDouble();
        final xPos = ((startOffset + elapsed) / totalSecs) * size.width;

        canvas.drawLine(
          Offset(xPos, 0),
          Offset(xPos, size.height),
          Paint()
            ..color = colors.info
            ..strokeWidth = 2.0,
        );

        // Draw small triangle at top
        final path = Path()
          ..moveTo(xPos - 4, 0)
          ..lineTo(xPos + 4, 0)
          ..lineTo(xPos, 6)
          ..close();
        canvas.drawPath(
          path,
          Paint()
            ..color = colors.info
            ..style = PaintingStyle.fill,
        );
      }
    }
  }

  void _drawTimeGrid(Canvas canvas, Size size, double topMargin) {
    // Draw 4 evenly spaced grid lines
    final gridPaint = Paint()
      ..color = colors.border.withValues(alpha: 0.5)
      ..strokeWidth = 0.5;

    for (int i = 1; i < 4; i++) {
      final x = size.width * i / 4;
      canvas.drawLine(
        Offset(x, topMargin),
        Offset(x, size.height),
        gridPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_TimelinePainter oldDelegate) {
    return oldDelegate.segments != segments || oldDelegate.progress != progress;
  }
}
