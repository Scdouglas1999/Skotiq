import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'activity_panel.dart';

/// Every build waiting at the framing check, current or held.
List<DarkroomBuildJob> waitingBuilds(
  DarkroomBuildJob? current,
  List<DarkroomBuildJob> held,
) =>
    [
      if (current != null && current.stage == DarkroomJobStage.awaitingReview)
        current,
      for (final h in held)
        if (h.target != current?.target ||
            current?.stage != DarkroomJobStage.awaitingReview)
          h,
    ];

/// Builds held at the framing check: the field they would keep, the frames
/// that limit it, and the way to the check.
class WaitingPanel extends ConsumerWidget {
  const WaitingPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final waiting = waitingBuilds(
      ref.watch(darkroomBuildJobsProvider),
      ref.watch(darkroomHeldBuildsProvider),
    );
    return ActivityPanel(
      key: const ValueKey('darkroom_activity_waiting'),
      title: 'Waiting for you',
      note: waiting.isEmpty
          ? null
          : '${waiting.length} build${waiting.length == 1 ? '' : 's'} held '
              'at the framing check',
      child: waiting.isEmpty
          ? const ActivityQuiet(
              'Nothing is waiting. A build whose shared field falls below '
              'the minimum stops here for you to decide.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < waiting.length; i++)
                  _WaitingRow(job: waiting[i], last: i == waiting.length - 1),
              ],
            ),
    );
  }
}

class _WaitingRow extends ConsumerWidget {
  const _WaitingRow({required this.job, required this.last});

  final DarkroomBuildJob job;
  final bool last;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final preview = job.preview;
    final kept = preview == null
        ? null
        : '${(preview.retainedArea * 100).toStringAsFixed(1)}%';
    final minimum = preview == null
        ? null
        : '${(preview.minRetainedArea * 100).toStringAsFixed(0)}%';
    final limiting = preview?.limiting.length ?? 0;
    void open() {
      final jobs = ref.read(darkroomBuildJobsProvider.notifier);
      if (!jobs.busy) jobs.reviewHeld(job.target);
      context.go(darkroomFramingRoute(job.target));
    }

    return Container(
      key: ValueKey('darkroom_activity_waiting_${job.target}'),
      padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceMd),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  job.target,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SkotiqTypography.bodyStrong.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
              if (kept != null)
                Text(
                  '$kept kept, $minimum needed',
                  style: SkotiqTypography.monoXs.copyWith(
                    color: colors.warning,
                  ),
                ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            [
              if (limiting > 0)
                '$limiting frame${limiting == 1 ? '' : 's'} limit the field.',
              if (job.nightRunId != null)
                'Held by the night-end build of ${nightLabel(job.startedAt)}.'
              else
                'Held since ${clockLabel(job.startedAt)}.',
            ].join(' '),
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Wrap(
            spacing: SkotiqTokens.spaceSm,
            runSpacing: SkotiqTokens.spaceSm,
            children: [
              SkotiqButton(
                key: ValueKey('darkroom_activity_open_framing_${job.target}'),
                label: 'Open the framing check',
                icon: SkotiqIcons.frame,
                size: ButtonSize.small,
                onPressed: open,
              ),
              SkotiqButton(
                label: 'Do not build',
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: () => ref
                    .read(darkroomBuildJobsProvider.notifier)
                    .discardHeld(job.target),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
