import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/network_backend.dart';
import '../../models/sequence/sequence_models.dart';
import '../backend_provider.dart';
import '../runtime_mirror/channels/run_record_channel.dart'
    show runRecordChannelKey;
import '../runtime_mirror/client_runtime_mirror.dart';
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

/// When the current or last run started, as this app saw it start (on a
/// linked client, as the host saw it); null before any run this session.
/// Frames captured before it belong to earlier runs.
final runStartedAtProvider = StateProvider<DateTime?>((ref) => null);

/// The last run that ended this session, whether it completed, failed, was
/// stopped or ended at dawn; null before any, and cleared when the next run
/// starts. On a linked client it is the host's.
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
      // A linked client that has the host's record follows it; the host saw
      // the run start and end, this client may not have.
      if (_followsHost) return;
      if (_isLive(next) && (previous == null || !_isLive(previous))) {
        state = null;
        ref.read(runStartedAtProvider.notifier).state = DateTime.now();
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

  bool get _followsHost =>
      ref.read(backendProvider) is NetworkBackend &&
      ref
          .read(clientRuntimeMirrorStateProvider)
          .hasApplied(runRecordChannelKey);

  /// Show the imaging host's last ended run on a linked client.
  void mirrorHost(LastEndedRun? run) => state = run;
}
