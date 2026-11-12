import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'run_record.dart';

/// A run that ended this session: which plan it ran and when it ended.
class LastEndedRun {
  const LastEndedRun({required this.sequenceId, required this.endedAt});

  final String sequenceId;
  final DateTime endedAt;
}

/// When the current or last run started, as this app saw it start (on a
/// linked client, as the host saw it); null before any run this session.
/// Frames captured before it belong to earlier runs.
final runStartedAtProvider = Provider<DateTime?>(
  (ref) => ref.watch(runRecordProvider.select((run) => run.startedAt)),
);

/// The last run that ended this session, whether it completed, failed, was
/// stopped or ended at dawn; null before any, and cleared when the next run
/// starts. On a linked client it is the host's.
final lastEndedRunProvider = Provider<LastEndedRun?>(
  (ref) => ref.watch(runRecordProvider.select((run) => run.lastEnded)),
);
