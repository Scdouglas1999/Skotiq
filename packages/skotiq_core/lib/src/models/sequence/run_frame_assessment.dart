/// The wire vocabulary of the run's structured reports beyond a step's own
/// progress: a performed dither, the native frame watch's per-frame
/// assessment (plate solve, drift from the target, guide RMS, sky background,
/// horizon obstruction) and the confirmed-obstruction report.
///
/// Each travels as a sequencer `InstructionProgressStructured` event with its
/// own `detail_kind`, so none needs a wire type of its own. The readers are in
/// `backend/sequencer_run_events.dart`.
library;

import 'package:skotiq_bridge/skotiq_bridge.dart'
    show wireMap, wireOptBool, wireOptDouble, wireOptInt, wireOptString;

/// `detail_kind` of one dither the run performed, whoever asked for it (a
/// Dither node, a Smart Exposure plan's cadence, a burst's dither-every, the
/// Dither Interval trigger). Must stay equal to the native bridge's
/// `DITHER_PERFORMED_DETAIL_KIND`.
const String ditherPerformedDetailKind = 'DitherPerformed';

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

/// The native frame watch's verdict on one saved frame: where it solved, how
/// far from the target, the guide RMS during the exposure, the sky level, and
/// whether it must stop counting.
class FrameAssessment {
  const FrameAssessment({
    required this.solveAttempted,
    required this.plateSolved,
    required this.offTarget,
    required this.obstructed,
    this.savePath,
    this.filter,
    this.exposureSecs,
    this.wasAccepted,
    this.solvedRaDeg,
    this.solvedDecDeg,
    this.solvedRotationDeg,
    this.solvedPixelScale,
    this.offsetArcmin,
    this.guideRmsTotal,
    this.guideRmsSamples,
    this.backgroundAdu,
    this.starCount,
    this.altitudeDeg,
    this.azimuthDeg,
    this.pierSide,
    this.exclusionReason,
  });

  /// The assessment a `FrameAssessed` report carries. A flag the payload does
  /// not carry was not reported as true.
  factory FrameAssessment.fromJson(Object? raw) {
    final json = wireMap(raw);
    return FrameAssessment(
      savePath: wireOptString(json, 'save_path'),
      filter: wireOptString(json, 'filter'),
      exposureSecs: wireOptDouble(json, 'exposure_secs'),
      wasAccepted: wireOptBool(json, 'was_accepted'),
      solveAttempted: wireOptBool(json, 'solve_attempted') == true,
      plateSolved: wireOptBool(json, 'plate_solved') == true,
      solvedRaDeg: wireOptDouble(json, 'solved_ra_deg'),
      solvedDecDeg: wireOptDouble(json, 'solved_dec_deg'),
      solvedRotationDeg: wireOptDouble(json, 'solved_rotation_deg'),
      solvedPixelScale: wireOptDouble(json, 'solved_pixel_scale'),
      offsetArcmin: wireOptDouble(json, 'offset_arcmin'),
      guideRmsTotal: wireOptDouble(json, 'guide_rms_total'),
      guideRmsSamples: wireOptInt(json, 'guide_rms_samples'),
      backgroundAdu: wireOptDouble(json, 'background_adu'),
      starCount: wireOptInt(json, 'star_count'),
      altitudeDeg: wireOptDouble(json, 'altitude_deg'),
      azimuthDeg: wireOptDouble(json, 'azimuth_deg'),
      pierSide: wireOptString(json, 'pier_side'),
      offTarget: wireOptBool(json, 'off_target') == true,
      obstructed: wireOptBool(json, 'obstructed') == true,
      exclusionReason: wireOptString(json, 'exclusion_reason'),
    );
  }

  /// The path the frame's `captured_images` row was written with: the save
  /// path when accepted, the reject path when the grader rejected it.
  final String? savePath;
  final String? filter;
  final double? exposureSecs;

  /// The grader's verdict, before any exclusion below; null when the payload
  /// did not say.
  final bool? wasAccepted;
  final bool solveAttempted;
  final bool plateSolved;

  /// Solved center in degrees (RA too), rotation in degrees, scale in
  /// arcsec per pixel.
  final double? solvedRaDeg;
  final double? solvedDecDeg;
  final double? solvedRotationDeg;
  final double? solvedPixelScale;

  /// Distance of the solved center from the target.
  final double? offsetArcmin;

  /// RMS of the guider's total-RMS samples over the exposure, in the
  /// guider's units.
  final double? guideRmsTotal;
  final int? guideRmsSamples;
  final double? backgroundAdu;
  final int? starCount;
  final double? altitudeDeg;
  final double? azimuthDeg;
  final String? pierSide;
  final bool offTarget;
  final bool obstructed;

  /// Non-null when the frame must no longer count; starts with
  /// [frameExclusionOffTargetPrefix] or [frameExclusionObstructedPrefix].
  final String? exclusionReason;

  bool get isExcluded => exclusionReason != null && exclusionReason!.isNotEmpty;
}

/// A confirmed obstruction (trees, a roof) the run met while imaging, where
/// it began on the sky and what the run did about it.
class HorizonObstruction {
  const HorizonObstruction({
    required this.altitudeDeg,
    required this.azimuthDeg,
    this.targetName,
    this.latitude,
    this.longitude,
    this.verdict,
    this.action,
    this.message,
  });

  /// The obstruction a `HorizonObstruction` report carries; null when it does
  /// not say where on the sky it began.
  static HorizonObstruction? fromJson(Object? raw) {
    final json = wireMap(raw);
    final altitude = wireOptDouble(json, 'altitude_deg');
    final azimuth = wireOptDouble(json, 'azimuth_deg');
    if (altitude == null || azimuth == null) return null;
    return HorizonObstruction(
      altitudeDeg: altitude,
      azimuthDeg: azimuth,
      targetName: wireOptString(json, 'target_name'),
      latitude: wireOptDouble(json, 'latitude'),
      longitude: wireOptDouble(json, 'longitude'),
      verdict: wireOptString(json, 'verdict'),
      action: wireOptString(json, 'action'),
      message: wireOptString(json, 'message'),
    );
  }

  final double altitudeDeg;
  final double azimuthDeg;
  final String? targetName;

  /// The run's site; null when the executor did not know it.
  final double? latitude;
  final double? longitude;
  final String? verdict;

  /// `next_target` or `end_of_night`.
  final String? action;

  /// The operator-facing sentence.
  final String? message;
}
