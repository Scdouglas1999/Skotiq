/// Two-step atomic delivery of one file into a directory.
///
/// The steps are separate calls on purpose. [stage] copies the bytes to a
/// staged name in the SAME directory and verifies them; [commit] renames
/// that staged file onto the final name. Nothing ever writes the final name
/// directly, so a process killed at any instant leaves either the previous
/// file or no file — never a half-written one under the name a user will open.
///
/// Rename is atomic only within one filesystem, which is why the staged file
/// is a sibling of the destination rather than a system temp file.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'delivery_artifact.dart';
import 'delivery_failure.dart';

/// Suffix marking a staged, not-yet-committed delivery. A kill between
/// [AtomicFileWrite.stage] and [AtomicFileWrite.commit] leaves one of these
/// behind; the next attempt for the same job and file overwrites it, so the
/// litter is bounded by the number of files in flight.
const String kStagedDeliverySuffix = '.nsdelivery-part';

/// Re-type [failure] — raised reading a file that lives in the DESTINATION —
/// by asking which side actually went away.
///
/// [sha256OfFile] cannot know whose file it is holding, so it calls every
/// unreadable path [DeliveryFailureKind.sourceMissing]: terminal, and phrased
/// as the rig having lost the master. Every file delivery reads BACK — the
/// staged copy, the name already sitting at the destination — is on the far
/// side, so that verdict blames the night's data for an unmounted NAS and
/// records `failed` on an attempt the sweep would have survived.
///
/// [sourcePath] is stat-ed here, at failure time, rather than trusted from the
/// describe pass minutes ago: a source still on the rig means the failure is on
/// the DESTINATION side, which is exactly the failure another attempt fixes.
///
/// WHICH destination-side failure is then read off [destinationFile] and the
/// directory holding it, not inferred. "The destination went away" is a claim
/// about the SHARE, and a drop folder watched by a sync agent that unlinks
/// `.nsdelivery-part` files milliseconds after they appear produced exactly
/// that sentence while `ls` on the directory answered normally in the same
/// second. The sibling arm, [AtomicFileWrite._copyFailure], stats the directory
/// before saying it; this one now does too, and when the directory is still
/// there it says what is actually true — one file at the destination did not
/// survive, which the next sweep re-stages.
///
/// [failure] comes from [sha256OfFile], whose message already names the file it
/// could not read, so the destination path is not repeated here — what is
/// added is the verdict on the OTHER side.
Future<DeliveryFailure> destinationReadFailure({
  required String sourcePath,
  required File destinationFile,
  required DeliveryFailure failure,
}) async {
  final cause = failure.cause ?? failure;
  if (!await File(sourcePath).exists()) {
    return DeliveryFailure(
      DeliveryFailureKind.sourceMissing,
      '${failure.message}. $sourcePath is no longer on the rig either, so the '
      'artifact itself is gone',
      cause: cause,
    );
  }
  if (failure.kind == DeliveryFailureKind.permissionDenied) {
    return DeliveryFailure(
      DeliveryFailureKind.permissionDenied,
      '${failure.message}. That is the destination\'s copy and $sourcePath is '
      'still on the rig, so the destination is what refused the read',
      cause: cause,
    );
  }
  final directory = destinationFile.parent;
  if (!await directory.exists()) {
    return DeliveryFailure(
      DeliveryFailureKind.destinationUnreachable,
      '${failure.message}. That is the destination\'s copy, $sourcePath is '
      'still on the rig and ${directory.path} is no longer on the filesystem, '
      'so the destination went away, not the artifact',
      cause: cause,
    );
  }
  // The share is up and one file on it is not. Retryable, like the sibling
  // arm's unclassified copy failure: the next sweep stages this file again.
  if (!await destinationFile.exists()) {
    return DeliveryFailure(
      DeliveryFailureKind.transportFailure,
      '${failure.message}. That is the destination\'s copy, $sourcePath is '
      'still on the rig and ${directory.path} is still on the filesystem, so '
      '${_removedAtDestination(destinationFile)}',
      cause: cause,
    );
  }
  return DeliveryFailure(
    DeliveryFailureKind.transportFailure,
    '${failure.message}. That is the destination\'s copy, $sourcePath is still '
    'on the rig and both ${directory.path} and that copy are still on the '
    'filesystem, so the read failed on the one file rather than on the '
    'destination',
    cause: cause,
  );
}

/// What a destination-side file's disappearance means, told apart by the name.
///
/// Nothing but [AtomicFileWrite.stage] writes [kStagedDeliverySuffix], so a
/// missing one is this attempt's own copy being taken out from under it — the
/// shape a folder-watching sync agent or scanner produces. Any other name is a
/// file an earlier delivery committed, which something at the destination has
/// since removed.
String _removedAtDestination(File file) {
  if (file.path.endsWith(kStagedDeliverySuffix)) {
    return 'the staged copy was removed while this delivery was writing it — '
        'something on the destination side is deleting '
        '$kStagedDeliverySuffix files';
  }
  return 'the file already at that name was removed between being found and '
      'being read — something on the destination side is deleting what '
      'delivery has written';
}

/// A staged copy waiting to be committed onto its final name.
class AtomicFileWrite {
  /// Final path the file takes on [commit].
  final String finalPath;

  /// Path the bytes are written to first, a sibling of [finalPath].
  final String stagedPath;

  /// Checksum of the bytes as they were read back from [stagedPath].
  final String stagedChecksum;

  const AtomicFileWrite({
    required this.finalPath,
    required this.stagedPath,
    required this.stagedChecksum,
  });

  /// Copy [artifact] into [directory] as [deliveredName] under a staged name,
  /// and verify the bytes that landed hash to [DeliveryFile.checksum].
  ///
  /// [deliveredName] is the name the destination sees, which is the rig's own
  /// name carrying that destination's rig-identity component — see
  /// `DeliveryNaming`. It is passed in rather than read off [artifact] because
  /// one artifact is delivered to several destinations, and each of them may
  /// namespace it differently.
  ///
  /// The staged name is derived from [jobId] and [deliveredName], so a retry of
  /// the same delivery reuses it instead of accumulating one staged file per
  /// attempt.
  ///
  /// A checksum mismatch removes the staged file and throws — a partial copy
  /// is never left where a later attempt could mistake it for progress.
  static Future<AtomicFileWrite> stage({
    required DeliveryFile artifact,
    required String deliveredName,
    required Directory directory,
    required int jobId,
  }) async {
    final finalPath = p.join(directory.path, deliveredName);
    final stagedPath = p.join(
      directory.path,
      '.$deliveredName.$jobId$kStagedDeliverySuffix',
    );
    final staged = File(stagedPath);

    try {
      await File(artifact.sourcePath).copy(stagedPath);
    } on FileSystemException catch (error) {
      throw await _copyFailure(
        artifact: artifact,
        deliveredName: deliveredName,
        directory: directory,
        staged: staged,
        error: error,
      );
    }

    final String landed;
    try {
      landed = await sha256OfFile(staged);
    } on DeliveryFailure catch (failure) {
      final typed = await destinationReadFailure(
        sourcePath: artifact.sourcePath,
        destinationFile: staged,
        failure: failure,
      );
      throw DeliveryFailure(
        typed.kind,
        '${typed.message}${await _remove(staged)}',
        cause: typed.cause,
      );
    }
    if (landed != artifact.checksum) {
      throw DeliveryFailure(
        DeliveryFailureKind.checksumMismatch,
        'The copy of $deliveredName in ${directory.path} hashes to '
        '$landed, not ${artifact.checksum}${await _remove(staged)}',
      );
    }

    return AtomicFileWrite(
      finalPath: finalPath,
      stagedPath: stagedPath,
      stagedChecksum: landed,
    );
  }

  /// Rename the staged copy onto [finalPath].
  ///
  /// This is the only call that creates the final name, and it is one
  /// filesystem operation.
  Future<void> commit() async {
    try {
      await File(stagedPath).rename(finalPath);
    } on PathAccessException catch (error) {
      throw DeliveryFailure(
        DeliveryFailureKind.permissionDenied,
        'Renaming onto $finalPath is not permitted',
        cause: error,
      );
    } on FileSystemException catch (error) {
      // Same question the copy asks, for the same event: the rename is the
      // last thing a vanishing share breaks, and it is the same vanish the
      // sibling files in this transfer already reported.
      final directory = p.dirname(finalPath);
      if (!await Directory(directory).exists()) {
        throw DeliveryFailure(
          DeliveryFailureKind.destinationUnreachable,
          'Renaming ${p.basename(stagedPath)} onto ${p.basename(finalPath)} '
          'failed (${fileSystemReason(error)}) and $directory is no longer on '
          'the filesystem, so the destination went away',
          cause: error,
        );
      }
      throw DeliveryFailure(
        DeliveryFailureKind.transportFailure,
        'Renaming ${p.basename(stagedPath)} onto ${p.basename(finalPath)} '
        'failed: ${fileSystemReason(error)}',
        cause: error,
      );
    }
  }

  /// Remove the staged copy without committing it. Returns the sentence
  /// describing a cleanup that did not succeed, or an empty string.
  Future<String> abandon() => _remove(File(stagedPath));

  /// Type a copy that the operating system refused, by which side it was
  /// complaining about.
  ///
  /// The copy reads the rig and writes the destination, so one
  /// [FileSystemException] can mean either. A full destination is its own
  /// kind; otherwise the SOURCE is stat-ed HERE, because a master that
  /// vanished between the describe pass and this copy is terminal — no later
  /// attempt finds it — while everything else belongs to the destination and
  /// is worth another attempt.
  ///
  /// The DESTINATION directory is stat-ed here too. A share that unmounts
  /// mid-pass is one event, and it reached the journal under two names: the
  /// files whose destination copy was being read back were typed
  /// [DeliveryFailureKind.destinationUnreachable] by [destinationReadFailure],
  /// while the files still waiting to be copied fell through to
  /// [DeliveryFailureKind.transportFailure] — which names no mechanism — for
  /// the same vanished mount that `open` itself calls unreachable. One vanish
  /// now has one type, so a morning report reading the journal says the NAS
  /// went away rather than listing two unrelated-looking faults.
  static Future<DeliveryFailure> _copyFailure({
    required DeliveryFile artifact,
    required String deliveredName,
    required Directory directory,
    required File staged,
    required FileSystemException error,
  }) async {
    final trailer = await _remove(staged);
    // The operator's sentence carries the operating system's own reason, not
    // just the act. `error.message` for a failed copy is "Cannot copy file to
    // '<staged path>'" and nothing more, so a full drive, a read-only mount
    // and a broken symlink all reported the same words; the errno read one
    // line below already proves the reason was in hand.
    final reason = fileSystemReason(error);
    // errno 28 is ENOSPC on every platform Skotiq ships to. A full
    // destination is retried overnight; space is freed by other things
    // finishing.
    if (error.osError?.errorCode == 28) {
      return DeliveryFailure(
        DeliveryFailureKind.insufficientSpace,
        'Copying $deliveredName to ${directory.path} failed: $reason$trailer',
        cause: error,
      );
    }
    if (!await File(artifact.sourcePath).exists()) {
      return DeliveryFailure(
        DeliveryFailureKind.sourceMissing,
        'Copying $deliveredName to ${directory.path} failed '
        '($reason) and ${artifact.sourcePath} is no longer on the '
        'rig$trailer',
        cause: error,
      );
    }
    if (error is PathAccessException) {
      return DeliveryFailure(
        DeliveryFailureKind.permissionDenied,
        'Copying $deliveredName to ${directory.path} is not permitted '
        '($reason); ${artifact.sourcePath} is still on the '
        'rig$trailer',
        cause: error,
      );
    }
    if (!await directory.exists()) {
      return DeliveryFailure(
        DeliveryFailureKind.destinationUnreachable,
        'Copying $deliveredName to ${directory.path} failed ($reason) and '
        '${directory.path} is no longer on the filesystem, so the destination '
        'went away, not the artifact$trailer',
        cause: error,
      );
    }
    return DeliveryFailure(
      DeliveryFailureKind.transportFailure,
      'Copying ${artifact.fileName} to ${directory.path} failed: '
      '$reason; ${artifact.sourcePath} is still on the rig$trailer',
      cause: error,
    );
  }

  /// Delete [file] and return a sentence to append to the failure that is
  /// already being reported, or an empty string when the delete worked.
  ///
  /// A cleanup problem never replaces the delivery failure that caused it —
  /// the operator needs the first cause — so it rides along in the same
  /// message instead of being thrown or dropped.
  static Future<String> _remove(File file) async {
    try {
      if (await file.exists()) await file.delete();
      return '';
    } on FileSystemException catch (error) {
      return ' (the staged copy at ${file.path} could not be removed: '
          '${fileSystemReason(error)}; the next attempt for this job '
          'overwrites it)';
    }
  }
}
