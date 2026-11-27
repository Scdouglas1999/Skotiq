import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/database.dart'
    show SequenceRun, SequenceRunStatusOfRow;
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/snackbar_helper.dart';

/// The run checkpoint that can be continued, or null. A run that was stopped,
/// failed or ended early keeps its checkpoint; History offers to continue it
/// rather than raising it as an interruption at every launch.
final continuableCheckpointProvider =
    FutureProvider.autoDispose<CheckpointInfo?>((ref) async {
  ref.watch(sequenceExecutionStateProvider);
  final backend = ref.watch(backendProvider);
  try {
    final info = await backend.getCheckpointInfo();
    return info != null && info.canResume ? info : null;
  } catch (_) {
    return null;
  }
});

/// The id of the run [info] was saved from, or null when that run is not one
/// that can be continued.
///
/// The host keeps one checkpoint and every run overwrites it, so it belongs
/// to the newest run started before it was saved, whatever that run's plan;
/// a run that ended earlier than another started never owns it. A completed
/// run has nothing left to continue.
@visibleForTesting
int? checkpointOwner(CheckpointInfo info, Iterable<SequenceRun> runs) {
  final saved = info.timestamp.toUtc();
  SequenceRun? owner;
  for (final run in runs) {
    final started = run.startedAt.toUtc();
    if (started.isAfter(saved)) continue;
    if (owner == null || started.isAfter(owner.startedAt.toUtc())) {
      owner = run;
    }
  }
  if (owner == null ||
      owner.sequenceName != info.sequenceName ||
      owner.runStatus == SequenceRunStatus.completed) {
    return null;
  }
  return owner.id;
}

/// "Continue" on a History row whose run can be picked up from its
/// checkpoint. Restoring loads the plan and its progress; nothing moves until
/// the operator presses Start.
class ContinueRunButton extends ConsumerWidget {
  const ContinueRunButton({super.key, required this.runId});

  /// The History row's `sequence_runs.id`.
  final int runId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(continuableCheckpointProvider).valueOrNull;
    final runs = ref.watch(sequenceRunsProvider).valueOrNull;
    if (info == null ||
        runs == null ||
        !ref.watch(sequenceExecutionStateProvider).canStart ||
        checkpointOwner(info, runs) != runId) {
      return const SizedBox.shrink();
    }
    final frames = info.completedExposures;
    return Tooltip(
      message: 'Loads this run again at frame $frames. Nothing moves until '
          'you press Start.',
      child: SkotiqButton(
        label: 'Continue run',
        icon: LucideIcons.playCircle,
        variant: ButtonVariant.secondary,
        size: ButtonSize.small,
        onPressed: () => _restore(context, ref, info),
      ),
    );
  }

  Future<void> _restore(
    BuildContext context,
    WidgetRef ref,
    CheckpointInfo info,
  ) async {
    try {
      await ref.read(sequenceExecutorProvider).restoreFromCheckpoint();
      if (!context.mounted) return;
      final frames = info.completedExposures;
      context.showSuccessSnackBar(
        'Restored ${info.sequenceName} at $frames '
        '${frames == 1 ? 'frame' : 'frames'}. Nothing moves until you press '
        'Start.',
      );
    } catch (e) {
      if (!context.mounted) return;
      context.showErrorSnackBar(
          'Could not restore the run: ${userFacingError(e)}');
    }
  }
}
