/// The one place a run or session status becomes the words, color and icon a
/// person sees. The stored values are record tokens (`paused-stopped` is
/// "stopped with the checkpoint kept"), never shown as they are.
library;

import 'package:flutter/widgets.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/models.dart'
    show SequenceRunStatus, SessionStatus, isStoredRunStopNotice;
import 'package:skotiq_ui/skotiq_ui.dart';

/// Human label for a run status.
String runStatusLabel(SequenceRunStatus status) => switch (status) {
      SequenceRunStatus.completed => 'Completed',
      SequenceRunStatus.failed => 'Failed',
      SequenceRunStatus.aborted => 'Aborted',
      SequenceRunStatus.stopped => 'Stopped',
      SequenceRunStatus.stoppedResumable => 'Stopped (resumable)',
      SequenceRunStatus.interrupted => 'Interrupted',
      SequenceRunStatus.running => 'Running',
      SequenceRunStatus.paused => 'Paused',
    };

/// Human label for a stored run status. A token no build of this version
/// writes reads as itself (see [_tokenWords]).
String runStatusTokenLabel(String token) {
  final status = SequenceRunStatus.tryParse(token);
  return status == null ? _tokenWords(token) : runStatusLabel(status);
}

/// Human label for a stored session status: a session a run ended reads as
/// that run's ending.
String sessionStatusLabel(String token) {
  final status = SessionStatus.tryParse(token);
  return switch (status?.runEnding) {
    final run? => runStatusLabel(run),
    null => switch (status) {
        SessionStatus.active => 'Active',
        SessionStatus.error => 'Error',
        _ => _tokenWords(token),
      },
  };
}

/// A token a newer build wrote: hyphens and underscores become spaces and the
/// first letter is capitalized.
String _tokenWords(String token) {
  final words = token.replaceAll('-', ' ').replaceAll('_', ' ').trim();
  if (words.isEmpty) return 'Unknown';
  return words[0].toUpperCase() + words.substring(1);
}

/// One sentence explaining what a run status means.
///
/// Five outcomes mean "the run did not finish", and they call for different
/// operator responses. Each of those opens with the same clause, and the
/// difference follows the dash.
String runStatusMeaning(SequenceRunStatus status) => switch (status) {
      SequenceRunStatus.completed => 'Finished every planned frame.',
      SequenceRunStatus.running => 'Under way right now.',
      SequenceRunStatus.paused => 'Under way, held at the operator\'s request.',
      SequenceRunStatus.failed =>
        'Did not finish: the sequencer hit an error it could not recover '
            'from.',
      SequenceRunStatus.aborted =>
        'Did not finish: a safety rule or a trigger ended it.',
      SequenceRunStatus.stopped =>
        'Did not finish: you stopped it, and no checkpoint was kept.',
      SequenceRunStatus.stoppedResumable =>
        'Did not finish: you stopped it, and the checkpoint was kept so it '
            'can be resumed.',
      SequenceRunStatus.interrupted =>
        'Did not finish: the app or the machine went down mid-run; this was '
            'reconciled at the next start.',
    };

/// The chip tone a run status is shown in. An operator's stop, an
/// interruption and a status this build does not know have no tone.
ChipTone runStatusTone(SequenceRunStatus? status) => switch (status) {
      SequenceRunStatus.completed => ChipTone.success,
      SequenceRunStatus.failed => ChipTone.error,
      SequenceRunStatus.aborted => ChipTone.warning,
      SequenceRunStatus.running ||
      SequenceRunStatus.paused ||
      SequenceRunStatus.stopped ||
      SequenceRunStatus.stoppedResumable ||
      SequenceRunStatus.interrupted ||
      null =>
        ChipTone.neutral,
    };

/// The color a run status is shown in: its tone, info while the run is under
/// way, muted where the tone is neutral.
Color runStatusColor(SkotiqColors colors, SequenceRunStatus? status) =>
    status?.isLive == true
        ? colors.info
        : runStatusTone(status).resolve(colors) ?? colors.textMuted;

/// The chip tone a stored session status is shown in: a session a run ended
/// takes that run's tone.
ChipTone sessionStatusTone(String token) {
  final status = SessionStatus.tryParse(token);
  return switch (status) {
    SessionStatus.active => ChipTone.primary,
    SessionStatus.error => ChipTone.error,
    _ => runStatusTone(status?.runEnding),
  };
}

/// The color a stored session status is shown in.
Color sessionStatusColor(SkotiqColors colors, String token) =>
    sessionStatusTone(token).resolve(colors) ?? colors.textMuted;

/// The icon a run status is shown with.
IconData runStatusIcon(SequenceRunStatus? status) => switch (status) {
      SequenceRunStatus.completed => LucideIcons.checkCircle2,
      SequenceRunStatus.failed => LucideIcons.xCircle,
      SequenceRunStatus.aborted => LucideIcons.alertTriangle,
      SequenceRunStatus.running => LucideIcons.play,
      SequenceRunStatus.paused => LucideIcons.pause,
      SequenceRunStatus.stopped ||
      SequenceRunStatus.stoppedResumable ||
      SequenceRunStatus.interrupted ||
      null =>
        LucideIcons.circle,
    };

/// The messages worth showing as errors for a run that ended with [status].
///
/// Identity in, identity out for every outcome but an operator stop.
List<String> runErrorMessagesFor(
  SequenceRunStatus? status,
  List<String> messages,
) {
  if (status == null || !status.stoppedByOperator) return messages;
  return messages.where((m) => !isStoredRunStopNotice(m)).toList();
}

/// The one message that explains why a failed run ended.
///
/// [terminalCause] is the reason the executor gave on `SequenceFailed`, the
/// first fault of the failure. The cascade in [errors] keeps everything that
/// was reported, in order, so its LAST entry is usually a step the teardown
/// cancelled after the fault ("Change Filter: Operation cancelled" on
/// 2026-09-14), which is never the reason. The last error stands in only for
/// runs recorded before the cause was filed separately.
String? runFailureHeadline({String? terminalCause, List<String>? errors}) {
  final cause = terminalCause?.trim();
  if (cause != null && cause.isNotEmpty) return terminalCause;
  if (errors != null && errors.isNotEmpty) return errors.last;
  return null;
}
