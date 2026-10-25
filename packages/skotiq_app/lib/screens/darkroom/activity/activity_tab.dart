import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../build_masters/job_views.dart';

/// The Darkroom's running build, the builds waiting for a decision, the
/// night-end history and the night-end automation settings.
class DarkroomActivityTab extends ConsumerWidget {
  const DarkroomActivityTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final job = ref.watch(darkroomBuildJobsProvider);
    if (job == null) {
      return const Center(
        child: EmptyState(
          icon: SkotiqIcons.activity,
          title: 'No build running',
          body: 'Master builds started from a target show their progress here.',
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(SkotiqTokens.space2xl),
      child: job.stage == DarkroomJobStage.done
          ? BuildResultPanel(job: job, onError: (_) {})
          : BuildProgressPanel(job: job),
    );
  }
}
