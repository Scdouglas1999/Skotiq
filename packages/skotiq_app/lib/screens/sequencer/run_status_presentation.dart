/// The one place a durable `sequence_runs.status` becomes words a person reads.
///
/// The stored values are state-machine tokens: `paused-stopped` means "stopped
/// with the checkpoint preserved", a fact about resumability rather than about
/// what the operator did. Printed verbatim it claims an operator pause nobody
/// performed.
///
/// Every surface that shows a run outcome goes through here, so the vocabulary
/// stays the product's rather than the schema's.
library;

import 'package:skotiq_core/skotiq_core.dart' show isSequenceCancelledNotice;

/// Human label for a durable run status.
///
/// Unknown tokens (a status added to the executor before this map) degrade to
/// a readable form rather than vanishing: hyphens become spaces and the first
/// letter is capitalised.
String runStatusLabel(String status) {
  switch (status) {
    case 'completed':
      return 'Completed';
    case 'failed':
      return 'Failed';
    case 'aborted':
      return 'Aborted';
    case 'stopped':
      return 'Stopped';
    case 'paused-stopped':
      // Stopped by the operator, checkpoint kept, so the run can be resumed.
      return 'Stopped (resumable)';
    case 'interrupted':
      return 'Interrupted';
    case 'running':
      return 'Running';
    case 'paused':
      return 'Paused';
    case 'finalizing':
      return 'Finishing up';
  }
  final words = status.replaceAll('-', ' ').replaceAll('_', ' ').trim();
  if (words.isEmpty) return 'Unknown';
  return words[0].toUpperCase() + words.substring(1);
}

/// One sentence explaining what a run status MEANS, in one shared vocabulary.
///
/// History carries seven outcome chips, five of which mean "the run did not
/// finish" — Failed, Aborted, Stopped, Stopped (resumable), Interrupted. In
/// five unrelated words, nothing on screen says how they differ, and the
/// distinctions are real: they call for different operator responses. So they
/// are defined once, in parallel phrasing — every not-finished status opens
/// with the same clause, and the difference follows the dash.
String runStatusMeaning(String status) {
  switch (status) {
    case 'completed':
      return 'Finished every planned frame.';
    case 'running':
      return 'Under way right now.';
    case 'paused':
      return 'Under way, held at the operator\'s request.';
    case 'finalizing':
      return 'Under way, writing its final results.';
    case 'failed':
      return 'Did not finish — the sequencer hit an error it could not '
          'recover from.';
    case 'aborted':
      return 'Did not finish — a safety rule or a trigger ended it.';
    case 'stopped':
      return 'Did not finish — you stopped it, and no checkpoint was kept.';
    case 'paused-stopped':
      return 'Did not finish — you stopped it, and the checkpoint was kept so '
          'it can be resumed.';
    case 'interrupted':
      return 'Did not finish — the app or the machine went down mid-run; this '
          'was reconciled at the next start.';
  }
  return 'Run status recorded as "$status".';
}

/// True when [status] means the operator ended the run themselves.
///
/// A deliberate Stop is the one terminal state that is not a fault, and the
/// surfaces that describe the run have to agree about that.
bool runWasStoppedByOperator(String status) =>
    status == 'stopped' || status == 'paused-stopped';

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
/// Identity in, identity out for every non-stop outcome.
List<String> runErrorMessagesFor(String status, List<String> messages) {
  if (!runWasStoppedByOperator(status)) return messages;
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

/// Removes the generated bridge wrapper while retaining the actual failure.
String runFailureMessage(String raw) => raw.replaceAllMapped(
      RegExp(r'SkotiqError\.\w+\(field0: (.*)\)', dotAll: true),
      (match) => match.group(1)!,
    );
