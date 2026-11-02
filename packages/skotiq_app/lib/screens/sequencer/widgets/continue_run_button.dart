import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';

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

/// Whether [info] is the checkpoint of the run that started at [startedAt] and
/// ended at [endedAt] (or has not recorded an end).
@visibleForTesting
bool checkpointBelongsToRun(
  CheckpointInfo info, {
  required String sequenceName,
  required DateTime startedAt,
  DateTime? endedAt,
}) {
  if (info.sequenceName != sequenceName) return false;
  final saved = info.timestamp.toUtc();
  if (saved.isBefore(startedAt.toUtc())) return false;
  // The run's end is recorded a moment after its checkpoint's last write.
  return endedAt == null ||
      !saved.isAfter(endedAt.toUtc().add(const Duration(minutes: 2)));
}

/// "Continue" on a History row whose run can be picked up from its
/// checkpoint. Restoring loads the plan and its progress; nothing moves until
/// the operator presses Start.
class ContinueRunButton extends ConsumerWidget {
  const ContinueRunButton({
    super.key,
    required this.sequenceName,
    required this.startedAt,
    this.endedAt,
  });

  final String sequenceName;
  final DateTime startedAt;
  final DateTime? endedAt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(continuableCheckpointProvider).valueOrNull;
    if (info == null ||
        !ref.watch(sequenceExecutionStateProvider).canStart ||
        !checkpointBelongsToRun(
          info,
          sequenceName: sequenceName,
          startedAt: startedAt,
          endedAt: endedAt,
        )) {
      return const SizedBox.shrink();
    }
    final frames = info.completedExposures;
    return IconButton(
      onPressed: () => _restore(context, ref, info),
      icon: const Icon(LucideIcons.playCircle, size: 16),
      tooltip: 'Continue this run from frame $frames. Nothing moves until '
          'you press Start.',
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
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
      context.showErrorSnackBar('Could not restore the run: $e');
    }
  }
}
