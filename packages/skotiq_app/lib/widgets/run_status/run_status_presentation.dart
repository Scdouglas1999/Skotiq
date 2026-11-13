/// The one place a run status becomes the words, color and icon a person
/// sees. The stored values are record tokens (`paused-stopped` is "stopped
/// with the checkpoint kept"), never shown as they are.
library;

import 'package:flutter/widgets.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/errors.dart' show userFacingError;
import 'package:skotiq_core/models.dart'
    show SequenceRunStatus, isSequenceCancelledNotice;
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

/// Human label for a stored run or session status.
///
/// A token that is not a run status (a session's `active` or `error`, or one
/// a newer build wrote) reads as itself: hyphens become spaces and the first
/// letter is capitalized.
String runStatusTokenLabel(String token) {
  final status = SequenceRunStatus.tryParse(token);
  if (status != null) return runStatusLabel(status);
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
        'Did not finish — the sequencer hit an error it could not recover '
            'from.',
      SequenceRunStatus.aborted =>
        'Did not finish — a safety rule or a trigger ended it.',
      SequenceRunStatus.stopped =>
        'Did not finish — you stopped it, and no checkpoint was kept.',
      SequenceRunStatus.stoppedResumable =>
        'Did not finish — you stopped it, and the checkpoint was kept so it '
            'can be resumed.',
      SequenceRunStatus.interrupted =>
        'Did not finish — the app or the machine went down mid-run; this was '
            'reconciled at the next start.',
    };

/// The color a run status is shown in. A status this build does not know is
/// muted.
Color runStatusColor(SkotiqColors colors, SequenceRunStatus? status) =>
    switch (status) {
      SequenceRunStatus.completed => colors.success,
      SequenceRunStatus.failed => colors.error,
      SequenceRunStatus.aborted => colors.warning,
      SequenceRunStatus.running || SequenceRunStatus.paused => colors.info,
      SequenceRunStatus.stopped ||
      SequenceRunStatus.stoppedResumable ||
      SequenceRunStatus.interrupted ||
      null =>
        colors.textMuted,
    };

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

/// True when [message] is the run-cancelled notice rather than a fault.
///
/// The executor records "Sequence cancelled" in the run's error list because
/// that is how the native run ends on a Stop. Rendered verbatim under a red
/// "Errors" heading — in a report titled "Stopped (resumable)" — it reports the
/// operator's own button press as a critical failure. Recognised here so the
/// outcome-aware surfaces can drop it; it is never dropped for a run that
/// failed or aborted on its own.
///
/// The match is EXACT, and that is the whole point. A substring test on
/// "cancelled" also swallows real faults the stack emits — "Temperature
/// compensation cancelled", "Cancelled: Target", "focuser move was canceled by
/// the driver", "slew canceled by the mount (limit switch)" — so a Stop after
/// any of those would hide the Errors section entirely. The notice is a fixed
/// string, so nothing is lost by recognising only the fixed strings.
///
/// [isSequenceCancelledNotice] (skotiq_core) is the shared spelling test;
/// this adds the operator-phrased variants the durable run rows can also carry.
bool isRunCancellationNotice(String message) {
  if (isSequenceCancelledNotice(message)) return true;
  final m = message.trim().toLowerCase();
  return m == 'stopped by user' ||
      m == 'stopped by the user' ||
      m == 'stopped by operator' ||
      m == 'stopped by the operator' ||
      m == 'stopped by request';
}

/// The messages worth showing as errors for a run that ended with [status].
///
/// Identity in, identity out for every outcome but an operator stop.
List<String> runErrorMessagesFor(
  SequenceRunStatus? status,
  List<String> messages,
) {
  if (status == null || !status.stoppedByOperator) return messages;
  return messages.where((m) => !isRunCancellationNotice(m)).toList();
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

/// A failure as recorded on a run, in words for the operator.
String runFailureMessage(String raw) => userFacingError(raw);
