// Pure guide-star finder for the framing canvas.
//
// Given the framing render-path's own sky <-> screen projection
// ([FramingSkyProjection], `framing_hips_projection.dart`) and the equipment
// field of view, this picks the bright catalog stars that fall inside the FOV
// rectangle and are usable as autoguider guide stars, and reports where each
// projects on the canvas so an overlay can mark them. It is the testable core of
// the framing "guide-star finder" overlay.
//
// Why this lives here (skotiq_core models, pure Dart):
//
//  * It reuses the SAME projection the survey background, FOV reticle and HiPS
//    tiles register through, so a marked guide star sits exactly over the pixel
//    the catalog says it occupies — no second, divergent px/deg or sky->screen
//    mapping.
//  * It depends only on `dart:math` / `dart:ui` geometry and
//    [FramingSkyProjection], never on Flutter widgets, Riverpod or the star
//    catalog type, so it is fully unit-testable in isolation and the app layer
//    can adapt whatever catalog star type it has into [GuideStarInput].
//
// The "guide star" selection rule mirrors what an autoguider needs:
//
//  * Bright enough for the guide camera to centroid reliably — a magnitude
//    ceiling ([GuideStarQuery.maxMagnitude], default V < 10) keeps only stars an
//    off-axis / separate guide scope can lock onto. Fainter stars are rejected.
//  * Inside the imaging FOV (the equipment reticle), since the overlay marks
//    candidates within the frame the user is composing. A point is "inside" when
//    its tangent-plane offset from the FOV center is within the FOV half-width /
//    half-height in degrees — computed in sky space (rotation-invariant) so the
//    test does not depend on the reticle's on-screen rotation.
//  * Not the target itself, and de-duplicated, so the marked set is the spread
//    of independent guide options around the field.

import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'framing_hips_projection.dart';

/// A catalog star handed to the guide-star finder.
///
/// A minimal, catalog-agnostic value: RA in hours, Dec in degrees, V magnitude
/// (nullable — stars with no magnitude can never be a guide star and are
/// skipped). [id] / [name] are carried through to the resulting candidate purely
/// for labelling. The app adapts its real catalog `Star` into this so the core
/// stays free of the planetarium catalog type.
class GuideStarInput {
  final String id;
  final String name;
  final double raHours;
  final double decDegrees;

  /// V magnitude; `null` when the catalog has no photometry for the star.
  final double? magnitude;

  const GuideStarInput({
    required this.id,
    required this.name,
    required this.raHours,
    required this.decDegrees,
    this.magnitude,
  });
}

/// Parameters for the guide-star search.
class GuideStarQuery {
  /// Brightest-allowed magnitude *ceiling*: a star qualifies when its magnitude
  /// is at or below this (smaller magnitude == brighter). Default V < 10 keeps
  /// stars a guide camera can centroid reliably.
  final double maxMagnitude;

  /// FOV width, in degrees, of the imaging frame the candidates must fall in.
  final double fovWidthDeg;

  /// FOV height, in degrees, of the imaging frame.
  final double fovHeightDeg;

  /// Maximum number of candidates to return (the brightest are kept). Caps the
  /// painted markers so a dense field does not flood the overlay.
  final int maxCandidates;

  /// Sky center, in RA hours, of the FOV rectangle candidates must fall inside.
  ///
  /// `null` (the default) means the projection's look-direction center — the
  /// long-standing behavior where the reticle sits at the view center. When the
  /// user has dragged the FOV box off-center, the overlay passes the reticle's
  /// AIM here so "inside the frame" is measured against where the box actually
  /// is, not where the camera is looking.
  final double? centerRaHours;

  /// Dec counterpart of [centerRaHours]; when only one of the pair is supplied
  /// the projection's center is used for the missing axis.
  final double? centerDecDegrees;

  const GuideStarQuery({
    this.maxMagnitude = 10.0,
    required this.fovWidthDeg,
    required this.fovHeightDeg,
    this.maxCandidates = 12,
    this.centerRaHours,
    this.centerDecDegrees,
  });
}

/// A bright star inside the FOV that can serve as a guide star, with its
/// on-canvas projection.
class GuideStarCandidate {
  final String id;
  final String name;
  final double raHours;
  final double decDegrees;
  final double magnitude;

  /// Where the star projects on the framing canvas, in logical pixels — the
  /// same projection the survey background and FOV reticle use, so the marker
  /// lands on the imagery to the pixel.
  final Offset screenPosition;

  const GuideStarCandidate({
    required this.id,
    required this.name,
    required this.raHours,
    required this.decDegrees,
    required this.magnitude,
    required this.screenPosition,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is GuideStarCandidate &&
        other.id == id &&
        other.name == name &&
        other.raHours == raHours &&
        other.decDegrees == decDegrees &&
        other.magnitude == magnitude &&
        other.screenPosition == screenPosition;
  }

  @override
  int get hashCode =>
      Object.hash(id, name, raHours, decDegrees, magnitude, screenPosition);

  @override
  String toString() =>
      'GuideStarCandidate(id: $id, name: $name, '
      'mag: $magnitude, screen: $screenPosition)';
}

/// Selects bright catalog stars usable as guide stars within the FOV centered
/// on [query]'s center (defaulting to [projection]'s look-direction), and
/// projects each onto the canvas.
///
/// A star qualifies when ALL of:
///  * it has a magnitude and that magnitude is `<= query.maxMagnitude`
///    (bright enough to centroid);
///  * its tangent-plane angular offset from the FOV center is within the FOV
///    half-extents — i.e. it lies inside the imaging frame. The inside test is
///    done in *sky* space (RA folded in by `cos(dec)`), so it is independent of
///    the reticle's on-screen rotation and zoom;
///  * it is not (numerically) the FOV center itself (the target), so the target
///    star is never mis-marked as its own guide star.
///
/// Returned candidates are de-duplicated by [GuideStarInput.id] and sorted
/// brightest-first, capped at [query.maxCandidates]. The screen position of each
/// is computed through [projection] so it registers with the survey background
/// and FOV overlay.
List<GuideStarCandidate> findGuideStarCandidates({
  required FramingSkyProjection projection,
  required Iterable<GuideStarInput> stars,
  required GuideStarQuery query,
}) {
  final halfWidthDeg = query.fovWidthDeg.abs() / 2.0;
  final halfHeightDeg = query.fovHeightDeg.abs() / 2.0;
  if (halfWidthDeg <= 0 || halfHeightDeg <= 0) return const [];

  // The FOV center the inside test is measured against: the query's explicit
  // center when the overlay passes the dragged reticle's aim, else the
  // projection's look-direction (view-center target).
  final centerRaHours = query.centerRaHours ?? projection.centerRaHours;
  final centerDecDeg = query.centerDecDegrees ?? projection.centerDecDegrees;
  final cosDec = math.cos(centerDecDeg * math.pi / 180.0);
  // Match the projection's pole clamp so RA-folding stays finite near the poles.
  final safeCosDec = cosDec.abs() > 0.01
      ? cosDec
      : (cosDec.isNegative ? -0.01 : 0.01);

  final seen = <String>{};
  final candidates = <GuideStarCandidate>[];

  for (final star in stars) {
    final mag = star.magnitude;
    if (mag == null || mag > query.maxMagnitude) continue;
    if (!seen.add(star.id)) continue;

    // Tangent-plane offset from the FOV center, in degrees of sky.
    final dRaHours = _shortestRaHours(star.raHours - centerRaHours);
    final dRaDeg = dRaHours * 15.0 * safeCosDec;
    final dDecDeg = star.decDegrees - centerDecDeg;

    // Reject the target itself: a star sitting essentially at the center is the
    // framed object, not a guide candidate.
    if (dRaDeg.abs() < 1e-6 && dDecDeg.abs() < 1e-6) continue;

    // Inside the imaging frame (rotation-invariant sky-space test).
    if (dRaDeg.abs() > halfWidthDeg || dDecDeg.abs() > halfHeightDeg) continue;

    candidates.add(
      GuideStarCandidate(
        id: star.id,
        name: star.name,
        raHours: star.raHours,
        decDegrees: star.decDegrees,
        magnitude: mag,
        screenPosition: projection.raDecToScreen(star.raHours, star.decDegrees),
      ),
    );
  }

  // Brightest first; cap the painted set.
  candidates.sort((a, b) => a.magnitude.compareTo(b.magnitude));
  if (candidates.length > query.maxCandidates) {
    return candidates.sublist(0, query.maxCandidates);
  }
  return candidates;
}

/// Signed RA difference in hours normalized to the shortest path across the
/// 0h/24h seam, identical to `FramingSkyProjection._deltaRaHours`.
double _shortestRaHours(double rawDeltaHours) {
  var d = rawDeltaHours % 24.0;
  if (d > 12.0) d -= 24.0;
  if (d < -12.0) d += 24.0;
  return d;
}
