/// The wire vocabulary of the native frame watch: the per-frame assessment
/// (plate solve, drift from the target, guide RMS, sky background, horizon
/// obstruction) and the confirmed-obstruction report.
///
/// Both travel as sequencer `InstructionProgressStructured` events with their
/// own `detail_kind`, like a performed dither (see `run_dither_event.dart`).
/// [SequencerRunEvent] decodes them as [FrameAssessed] and
/// [HorizonObstructionDetected].
library;

/// `detail_kind` of one frame's assessment. Must stay equal to the native
/// bridge's constant.
const String frameAssessedDetailKind = 'FrameAssessed';

/// `detail_kind` of a confirmed horizon obstruction. Must stay equal to the
/// native bridge's constant.
const String horizonObstructionDetailKind = 'HorizonObstruction';

/// Start of the exclusion reason of a frame whose solved center was too far
/// from the target. Shared with the native frame watch.
const String frameExclusionOffTargetPrefix = 'Off target:';

/// Start of the exclusion reason of a frame taken through an obstruction
/// (trees, a roof). Shared with the native frame watch.
const String frameExclusionObstructedPrefix = 'Obstructed:';

/// Why a frame no longer counts, as the frame lists badge it.
enum FrameExclusionKind { offTarget, obstructed }

/// The exclusion a stored `rejection_reason` names, or null when it names
/// none. A reason may carry earlier grader text before the exclusion, joined
/// with `; `, so every segment is checked.
FrameExclusionKind? frameExclusionKindOf(String? rejectionReason) {
  if (rejectionReason == null || rejectionReason.isEmpty) return null;
  for (final segment in rejectionReason.split('; ')) {
    final s = segment.trimLeft();
    if (s.startsWith(frameExclusionOffTargetPrefix)) {
      return FrameExclusionKind.offTarget;
    }
    if (s.startsWith(frameExclusionObstructedPrefix)) {
      return FrameExclusionKind.obstructed;
    }
  }
  return null;
}
