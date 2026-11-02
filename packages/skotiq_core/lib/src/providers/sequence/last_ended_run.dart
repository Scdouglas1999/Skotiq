import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/sequence/sequence_models.dart';
import 'sequence_progress.dart';
import 'sequence_selection.dart';

/// A run that ended this session: which plan it ran and when it ended.
class LastEndedRun {
  const LastEndedRun({required this.sequenceId, required this.endedAt});

  final String sequenceId;
  final DateTime endedAt;
}

bool _isLive(SequenceExecutionState state) => switch (state) {
  SequenceExecutionState.running ||
  SequenceExecutionState.paused ||
  SequenceExecutionState.recovering ||
  SequenceExecutionState.stopping ||
  SequenceExecutionState.finalizing => true,
  _ => false,
};

/// The last run that ended this session, whether it completed, failed, was
/// stopped or ended at dawn; null before any, and cleared when the next run
/// starts. On a linked client it follows the host's run state.
///
/// A stopped or dawn-ended run settles in the same `idle` state as a plan
/// that never ran; this is what tells them apart, so the night keeps its
/// results until the next start or until another plan is loaded.
final lastEndedRunProvider =
    NotifierProvider<LastEndedRunNotifier, LastEndedRun?>(
      LastEndedRunNotifier.new,
    );

class LastEndedRunNotifier extends Notifier<LastEndedRun?> {
  @override
  LastEndedRun? build() {
    ref.listen<SequenceExecutionState>(sequenceExecutionStateProvider, (
      previous,
      next,
    ) {
      if (_isLive(next) && (previous == null || !_isLive(previous))) {
        state = null;
        return;
      }
      if (previous != null && _isLive(previous) && next.canStart) {
        final sequenceId = ref.read(currentSequenceProvider)?.id;
        if (sequenceId == null) return;
        state = LastEndedRun(sequenceId: sequenceId, endedAt: DateTime.now());
      }
    });
    return null;
  }
}
