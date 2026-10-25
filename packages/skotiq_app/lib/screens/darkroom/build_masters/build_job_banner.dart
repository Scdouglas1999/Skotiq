import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'job_views.dart';

/// A one-line status of the background master build, with a way back to it.
class BuildJobBanner extends ConsumerWidget {
  const BuildJobBanner({super.key, required this.onOpen});
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final job = ref.watch(darkroomBuildJobsProvider);
    if (job == null) return const SizedBox.shrink();
    final (tone, title, message) = switch (job.stage) {
      DarkroomJobStage.framing => (
          BannerTone.info,
          'Checking framing for ${job.target}.',
          '${job.framesDone} of ${job.framesTotal} lights registered.',
        ),
      DarkroomJobStage.building || DarkroomJobStage.exporting => (
          BannerTone.info,
          'Building masters for ${job.target}.',
          '${job.message}. ${job.overallDone} of ${job.overallTotal} lights. ${describeEta(job.eta)}.',
        ),
      DarkroomJobStage.awaitingReview => (
          BannerTone.warning,
          'Framing for ${job.target} is ready to review.',
          job.message,
        ),
      DarkroomJobStage.done => (
          BannerTone.success,
          'Masters for ${job.target} are ready.',
          'They are in the Masters tab.',
        ),
      DarkroomJobStage.failed || DarkroomJobStage.stopped => (
          BannerTone.error,
          'The master build for ${job.target} did not finish.',
          job.error ?? job.message,
        ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceLg,
        vertical: SkotiqTokens.spaceSm,
      ),
      child: SkotiqBanner(
        tone: tone,
        title: title,
        message: message,
        action: SkotiqButton(
          label: 'Open',
          size: ButtonSize.small,
          variant: ButtonVariant.secondary,
          onPressed: onOpen,
        ),
        onDismiss: job.active
            ? null
            : () => ref.read(darkroomBuildJobsProvider.notifier).dismiss(),
      ),
    );
  }
}
