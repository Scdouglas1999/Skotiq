import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'activity_panel.dart';

/// The build running now: its stage, how far it is, the time left, and Stop.
/// A build that ended (stopped by a restart or by Stop, failed, or done)
/// stays here with what can be done next until it is dismissed.
class RunningBuildPanel extends ConsumerStatefulWidget {
  const RunningBuildPanel({super.key});

  @override
  ConsumerState<RunningBuildPanel> createState() => _RunningBuildPanelState();
}

class _RunningBuildPanelState extends ConsumerState<RunningBuildPanel> {
  bool _stopping = false;
  String? _error;

  Future<void> _act(Future<void> Function() action) async {
    setState(() => _error = null);
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _stop() async {
    setState(() => _stopping = true);
    await _act(ref.read(darkroomBuildJobsProvider.notifier).stop);
  }

  @override
  Widget build(BuildContext context) {
    final job = ref.watch(darkroomBuildJobsProvider);
    if (job == null || !job.active) _stopping = false;
    final shown = job == null || job.stage == DarkroomJobStage.awaitingReview
        ? null
        : job;
    return ActivityPanel(
      key: const ValueKey('darkroom_activity_running'),
      title: shown == null || shown.active ? 'Running build' : 'Last build',
      note: shown?.target,
      child: shown == null
          ? const ActivityQuiet(
              'No build is running. Builds started from a target or at the '
              'end of the night show their progress here.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (shown.active)
                  _Progress(
                    job: shown,
                    stopping: _stopping,
                    onStop: _stopping ? null : _stop,
                  )
                else
                  _Ended(
                    job: shown,
                    onAct: _act,
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: SkotiqTokens.spaceSm),
                    child: Text(
                      _error!,
                      style: SkotiqTypography.bodySm.copyWith(
                        color: context.skotiqColors.error,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// What the stage is called, with the filter and its place in the build.
String runningStageLabel(DarkroomBuildJob job) => switch (job.stage) {
      DarkroomJobStage.framing => 'Framing check: registering every sub',
      DarkroomJobStage.building => job.filter == null
          ? 'Starting the build'
          : 'Building ${job.filter} (${job.filterIndex + 1} of '
              '${job.filterCount})',
      DarkroomJobStage.exporting => 'Cropping every filter to the shared field',
      _ => job.message,
    };

class _Progress extends StatelessWidget {
  const _Progress({
    required this.job,
    required this.stopping,
    required this.onStop,
  });

  final DarkroomBuildJob job;
  final bool stopping;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final total = job.overallTotal;
    final done = job.overallDone.clamp(0, total == 0 ? 0 : total);
    final fraction = total == 0 ? 0.0 : done / total;
    final eta = job.eta;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                runningStageLabel(job),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: SkotiqTypography.bodyStrong.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceMd),
            SkotiqButton(
              key: const ValueKey('darkroom_activity_stop'),
              label: stopping ? 'Stopping' : 'Stop',
              icon: SkotiqIcons.stop,
              variant: ButtonVariant.destructive,
              size: ButtonSize.small,
              isLoading: stopping,
              onPressed: onStop,
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        Semantics(
          label: 'Build progress',
          value: '$done of $total subs',
          child: SkotiqProgressBar(value: fraction),
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        Row(
          children: [
            Text(
              total == 0 ? 'Preparing' : '$done of $total subs',
              style: SkotiqTypography.monoXs.copyWith(
                color: colors.textSecondary,
              ),
            ),
            const Spacer(),
            Text(
              eta == null
                  ? 'Time left: working it out'
                  : 'About ${durationLabel(eta)} left',
              style: SkotiqTypography.monoXs.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ],
        ),
        if (job.nightRunId != null)
          Padding(
            padding: const EdgeInsets.only(top: SkotiqTokens.spaceSm),
            child: Text(
              'Started by the night-end automation at '
              '${clockLabel(job.startedAt)}.',
              style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
            ),
          ),
      ],
    );
  }
}

class _Ended extends ConsumerWidget {
  const _Ended({required this.job, required this.onAct});

  final DarkroomBuildJob job;
  final Future<void> Function(Future<void> Function()) onAct;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final jobs = ref.read(darkroomBuildJobsProvider.notifier);
    final directory = job.directory;
    final resumable = job.stage == DarkroomJobStage.stopped &&
        directory != null &&
        File('$directory${Platform.pathSeparator}plan.json').existsSync();
    final (icon, color, title) = switch (job.stage) {
      DarkroomJobStage.done => (
          SkotiqIcons.success,
          colors.success,
          job.message,
        ),
      DarkroomJobStage.failed => (
          SkotiqIcons.error,
          colors.error,
          'The build failed',
        ),
      _ => (SkotiqIcons.warning, colors.warning, 'The build stopped'),
    };
    final ended = job.finishedAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(icon, size: SkotiqTokens.iconSm, color: color),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: Text(
                title,
                style: SkotiqTypography.bodyStrong.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ),
            if (ended != null)
              Text(
                clockLabel(ended),
                style: SkotiqTypography.monoXs.copyWith(
                  color: colors.textSecondary,
                ),
              ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        Text(
          job.stage == DarkroomJobStage.failed
              ? (job.error ?? job.message)
              : job.stage == DarkroomJobStage.done
                  ? 'Saved in $directory.'
                  : job.message,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        Wrap(
          spacing: SkotiqTokens.spaceSm,
          runSpacing: SkotiqTokens.spaceSm,
          children: [
            if (resumable)
              SkotiqButton(
                key: const ValueKey('darkroom_activity_resume'),
                label: 'Resume',
                icon: SkotiqIcons.play,
                size: ButtonSize.small,
                onPressed: () => onAct(() => jobs.resume(Directory(directory))),
              ),
            SkotiqButton(
              label: 'Open ${job.target}',
              icon: SkotiqIcons.arrowRight,
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: () => context.go(darkroomTargetRoute(job.target)),
            ),
            SkotiqButton(
              key: const ValueKey('darkroom_activity_dismiss'),
              label: 'Dismiss',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: jobs.dismiss,
            ),
          ],
        ),
      ],
    );
  }
}
