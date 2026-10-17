/// Why one file failed to reach one destination.
///
/// Delivery never throws into the dawn pipeline: the master row commits first
/// and a destination that is unreachable at 06:00 is a fact about the network,
/// not about the night's data. Every failure is therefore caught at the
/// [DeliveryService] boundary, turned into one of these, written to
/// `delivery_journal.last_error`, and surfaced in the morning report.
///
/// The kind is what callers match on. A message alone cannot answer "will
/// another attempt help?" — [DeliveryFailureKind.retryable] does, and it is
/// what decides between `retrying` and `failed` in the journal.
library;

import 'dart:convert';
import 'dart:io';

import '../../models/darkroom/delivery.dart';

/// [error]'s own sentence with the operating system's reason attached.
///
/// `FileSystemException.message` names only the act — `Cannot copy file to
/// '/drop/master.fits'`, `Failed to open file` — and the reason lives in
/// `osError`.
/// Reporting the act alone produced journal rows, morning-report problems and
/// Settings status lines that all read
/// `insufficientSpace: Copying X to Y failed: Cannot copy file to Z`: the kind
/// prefix was the only thing naming a mechanism, and for every other errno
/// even that was `transportFailure`, which names nothing. The reason was
/// always in hand — the ENOSPC classification is made by reading
/// `osError.errorCode` one line earlier — it simply never reached the
/// operator's sentence.
///
/// The errno rides along because two different failures share one wording
/// often enough to matter when someone reads the journal a week later.
String fileSystemReason(FileSystemException error) {
  final osError = error.osError;
  if (osError == null) return error.message;
  final reason = osError.message.trim();
  if (reason.isEmpty) return error.message;
  return '${error.message} — $reason (errno ${osError.errorCode})';
}

/// The mechanism that stopped a delivery.
enum DeliveryFailureKind {
  /// The source artifact is gone from the rig — a deleted master, a renamed
  /// output directory. No later attempt finds it.
  sourceMissing,

  /// The destination root does not exist right now: an unmounted NAS, a
  /// removed drive, a remote directory that was deleted. A later attempt may
  /// find it mounted again.
  destinationUnreachable,

  /// The destination filesystem has less free space than the artifact needs.
  /// Retried, because space is freed by other things finishing.
  insufficientSpace,

  /// The bytes that landed do not hash to the source's checksum. The partial
  /// is removed and the file is retried, because a truncated transfer is the
  /// usual cause.
  checksumMismatch,

  /// A file already sits at the final name with DIFFERENT content. Delivery
  /// copies and never overwrites, so this is terminal until the operator
  /// resolves it — another attempt would make exactly the same refusal.
  destinationConflict,

  /// The OS refused the read or the write. Terminal: permissions do not
  /// change between two attempts a few minutes apart, and retrying hides the
  /// misconfiguration behind a retry counter.
  permissionDenied,

  /// The transport needs key material that `SecretsStore` does not hold, or
  /// the destination row names no `secret_ref` at all.
  credentialMissing,

  /// The host key the server presented differs from the one pinned on the
  /// destination row. Terminal, and loud: this is what a man-in-the-middle
  /// looks like.
  hostKeyMismatch,

  /// The external tool this transport drives is absent from the machine
  /// (no `sftp`/`ssh` binary), or the remote side offers no digest command to
  /// verify with. Terminal until the operator installs it.
  transportToolMissing,

  /// The transport can express the request but this build cannot perform it
  /// with the credentials given — SFTP password authentication, which
  /// OpenSSH refuses non-interactively. Terminal, and names the substitute.
  authMethodUnavailable,

  /// The destination's `config_json` does not describe a place to write:
  /// no path, no host, no peer id.
  configurationInvalid,

  /// The transport failed in a way that another attempt may survive — a
  /// dropped connection, a timeout, a non-zero exit with no clearer cause.
  transportFailure;

  /// Whether another attempt can plausibly succeed.
  ///
  /// A terminal kind is written to the journal as `failed` on its FIRST
  /// attempt: burning the retry budget on a refusal that is identical every
  /// time turns one honest error into an hour of noise.
  bool get retryable {
    switch (this) {
      case DeliveryFailureKind.destinationUnreachable:
      case DeliveryFailureKind.insufficientSpace:
      case DeliveryFailureKind.checksumMismatch:
      case DeliveryFailureKind.transportFailure:
        return true;
      case DeliveryFailureKind.sourceMissing:
      case DeliveryFailureKind.destinationConflict:
      case DeliveryFailureKind.permissionDenied:
      case DeliveryFailureKind.credentialMissing:
      case DeliveryFailureKind.hostKeyMismatch:
      case DeliveryFailureKind.transportToolMissing:
      case DeliveryFailureKind.authMethodUnavailable:
      case DeliveryFailureKind.configurationInvalid:
        return false;
    }
  }
}

/// One file's delivery failure, carrying the mechanism and the sentence the
/// morning report prints.
class DeliveryFailure implements Exception {
  /// The mechanism that stopped the delivery.
  final DeliveryFailureKind kind;

  /// Operator-facing sentence naming what happened and where.
  final String message;

  /// The underlying error, when there was one to keep.
  final Object? cause;

  const DeliveryFailure(this.kind, this.message, {this.cause});

  /// Whether another attempt can plausibly succeed.
  bool get retryable => kind.retryable;

  /// The single line written to `delivery_journal.last_error`. The kind is
  /// part of it so a report reading only the journal can still say why.
  String get journalText => '${kind.name}: $message';

  @override
  String toString() => 'DeliveryFailure(${kind.name}): $message';
}

/// [destination]'s `config_json` as the map its transport reads.
///
/// Every transport decodes the same column, and the two ways it can refuse to
/// decode are the same configuration error: text that is not JSON at all, and
/// JSON that is not an object. Both are
/// [DeliveryFailureKind.configurationInvalid] — TERMINAL. A bare `jsonDecode`
/// raised `FormatException` here instead, which [DeliveryService] can only
/// read as an unclassified transport failure: RETRYABLE. A destination whose
/// configuration cannot be parsed was then re-attempted on the whole backoff
/// schedule, spending the night's budget on a row whose text is identical
/// every time, and the operator's sentence was the parser's
/// (`FormatException: Unexpected character (at character 1)`) rather than one
/// naming the column and the row.
///
/// [what] names the destination kind in the operator's words ("watched-folder
/// destination"), so the sentence says which row to open.
Map<String, Object?> decodeDeliveryConfig(
  ArtifactDestination destination, {
  required String what,
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(destination.configJson);
  } on FormatException catch (error) {
    throw DeliveryFailure(
      DeliveryFailureKind.configurationInvalid,
      'This $what stores configuration that is not JSON (${error.message}), '
      'so there is nothing to deliver to. Open it in Settings > Delivery and '
      'save it again',
      cause: error,
    );
  }
  if (decoded is! Map) {
    throw DeliveryFailure(
      DeliveryFailureKind.configurationInvalid,
      'This $what stores configuration that is JSON but not an object, so it '
      'names no place to write',
    );
  }
  return decoded.cast<String, Object?>();
}
