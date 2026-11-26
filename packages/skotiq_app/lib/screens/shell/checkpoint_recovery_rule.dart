import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart' show kContinueSessionMaxAge;

// The one rule for raising a checkpoint as an interrupted run, shared by the
// desktop shell and the phone: the phone kept its own looser check and
// offered "An interrupted sequence was found" for a run the operator had
// stopped a minute earlier.

/// Whether launch offers to recover [info]'s run: only a run the app died
/// under. A run that was stopped, failed or ended early keeps its checkpoint
/// and is continued from History instead of being raised as an interruption.
///
/// Nor a run with nothing to recover (no frame taken) or one older than the
/// Continue Session window: a "Recover Sequence? (0 frames)" prompt for a
/// days-old checkpoint offers to restore nothing.
bool offersCheckpointRecovery(CheckpointInfo? info, {DateTime? now}) =>
    info != null &&
    info.canResume &&
    info.wasInterrupted &&
    (info.completedExposures > 0 || info.completedIntegrationSecs > 0) &&
    checkpointAgeSeconds(info, now: now) <= kContinueSessionMaxAge.inSeconds;

/// How old [info]'s checkpoint is now, from its save time. A host that
/// reports a cached age keeps reporting the age it had when first read.
int checkpointAgeSeconds(CheckpointInfo info, {DateTime? now}) {
  final age = (now ?? DateTime.now())
      .toUtc()
      .difference(info.timestamp.toUtc())
      .inSeconds;
  return age < 0 ? 0 : age;
}
