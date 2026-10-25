import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/darkroom_navigation.dart';
import 'darkroom_targets_model.dart';

/// One line on what a target needs, and the tone it is drawn in.
(String, Color) darkroomTargetStatus(
  DarkroomTarget target,
  DarkroomBuildJob? job,
  SkotiqColors colors,
) {
  if (job != null && job.target == target.key) {
    switch (job.stage) {
      case DarkroomJobStage.framing:
        return ('Checking framing', colors.accent);
      case DarkroomJobStage.building:
      case DarkroomJobStage.exporting:
        return ('Building now', colors.accent);
      case DarkroomJobStage.awaitingReview:
        return ('Framing check waiting for you', colors.warning);
      case DarkroomJobStage.failed:
        return ('Last build failed', colors.error);
      case DarkroomJobStage.stopped:
        return ('Last build stopped', colors.warning);
      case DarkroomJobStage.done:
        break;
    }
  }
  final kept = target.nights.any((n) => n.kept > 0);
  if (!kept && target.masters.isEmpty) {
    return ('No kept subs', colors.textMuted);
  }
  if (target.masters.isEmpty) {
    return ('Not built yet', colors.brandWarm);
  }
  final fresh = target.newNights;
  if (fresh > 0) {
    return (
      '$fresh new night${fresh == 1 ? '' : 's'} to build',
      colors.brandWarm,
    );
  }
  if (target.newSubsInBuiltNights > 0) {
    return (
      '${target.newSubsInBuiltNights} new subs to build',
      colors.brandWarm
    );
  }
  return ('Up to date', colors.success);
}

/// The header chip: what the Darkroom is doing in the background. Opens
/// Activity.
class DarkroomStatusChip extends ConsumerWidget {
  const DarkroomStatusChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final job = ref.watch(darkroomBuildJobsProvider);
    final (value, tone) = switch (job?.stage) {
      null => ('No build running', InstrumentTone.idle),
      DarkroomJobStage.framing => (
          'Checking framing: ${job!.target} '
              '${job.framesDone}/${job.framesTotal}',
          InstrumentTone.primary,
        ),
      DarkroomJobStage.building || DarkroomJobStage.exporting => (
          'Building ${job!.target} ${job.overallDone}/${job.overallTotal}',
          InstrumentTone.primary,
        ),
      DarkroomJobStage.awaitingReview => (
          'Framing check waiting: ${job!.target}',
          InstrumentTone.warning,
        ),
      DarkroomJobStage.done => (
          'Masters ready: ${job!.target}',
          InstrumentTone.success,
        ),
      DarkroomJobStage.failed => (
          'Build failed: ${job!.target}',
          InstrumentTone.error,
        ),
      DarkroomJobStage.stopped => (
          'Build stopped: ${job!.target}',
          InstrumentTone.warning,
        ),
    };
    return InstrumentPill(
      key: const ValueKey('darkroom_status_chip'),
      dotTone: tone,
      value: value,
      maxValueWidth: 320,
      live: job?.active == true,
      semanticLabel: '$value. Open Activity.',
      onTap: () => context.go(darkroomTabLocation(DarkroomTab.activity)),
    );
  }
}
