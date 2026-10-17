// ignore_for_file: unused_element, unused_field

part of '../sky_renderer.dart';

/// The compass points labelled on the horizon, as (label, azimuth degrees).
///
/// Cardinals come first so that when the eight points crowd together at a wide
/// field of view the cardinals win the collision test and the intercardinals
/// are the ones dropped.
const List<(String, double)> _compassPoints = [
  ('N', 0.0),
  ('E', 90.0),
  ('S', 180.0),
  ('W', 270.0),
  ('NE', 45.0),
  ('SE', 135.0),
  ('SW', 225.0),
  ('NW', 315.0),
];

/// Pure geometry of the lunar phase drawing.
///
/// Kept out of the canvas code so the phase construction can be verified
/// without rendering: a wrong terminator formula draws a plausible moon and no
/// compile-time or smoke test catches it.
class MoonPhaseGeometry {
  MoonPhaseGeometry._();

  /// Semi-minor axis of the terminator ellipse, as a fraction of the lunar
  /// radius, for illuminated fraction [illumination] (0 = new, 1 = full).
  ///
  /// The terminator is the great circle dividing the lit and dark hemispheres;
  /// projected onto the sky it is an ellipse that shares the disc's semi-major
  /// axis and has semi-minor axis `R * |2k - 1|`. That follows directly from
  /// the definition `k = (1 + cos(phase angle)) / 2`, so the phase angle's
  /// cosine *is* `2k - 1` and no further trigonometry belongs here. Wrapping it
  /// in another cosine makes the phase non-monotonic — first quarter comes out
  /// as a full-width dark ellipse, i.e. a new moon.
  static double terminatorSemiAxisFraction(double illumination) {
    if (!illumination.isFinite) return 0.0;
    return (2 * illumination.clamp(0.0, 1.0) - 1).abs();
  }

  /// Fraction of the disc that the phase construction actually paints lit.
  ///
  /// The construction is a lit half-disc on the bright-limb side, plus half of
  /// the terminator ellipse past first quarter (`k > 0.5`) or minus half of it
  /// before first quarter. Since the ellipse has area `pi * R^2 * |2k - 1|`,
  /// this reduces analytically to `k` — which is what makes the rendered phase
  /// both correct and monotonic, and is what the unit test pins.
  static double litDiscFraction(double illumination) {
    if (!illumination.isFinite) return 0.0;
    final k = illumination.clamp(0.0, 1.0);
    final halfEllipse = terminatorSemiAxisFraction(k) / 2;
    return k >= 0.5 ? 0.5 + halfEllipse : 0.5 - halfEllipse;
  }

  /// Position angle of the Moon's bright limb, in degrees measured from
  /// celestial north through east.
  ///
  /// The bright limb points at the Sun, so this is exactly the position angle
  /// of the Sun as seen from the Moon (Meeus, *Astronomical Algorithms*, ch.
  /// 48) — the same great-circle bearing [AstronomyCalculations.positionAngle]
  /// already computes, rather than a second copy of the formula.
  static double brightLimbPositionAngleDeg({
    required double sunRaDeg,
    required double sunDecDeg,
    required double moonRaDeg,
    required double moonDecDeg,
  }) => AstronomyCalculations.positionAngle(
    ra1Deg: moonRaDeg,
    dec1Deg: moonDecDeg,
    ra2Deg: sunRaDeg,
    dec2Deg: sunDecDeg,
  );
}

/// Scene geometry the painter derives from its own state, exposed so the
/// compass and lunar-phase layers can be asserted against real sky positions
/// instead of only being eyeballed in a rendered frame.
extension SkyCanvasPainterSceneGeometry on SkyCanvasPainter {
  /// The projection origin and pixels-per-degree scale that `_paint` hands to
  /// every layer, recomputed for the layers that only receive the canvas size.
  (Offset, double) _projectionFrame(Size size) => (
    Offset(size.width / 2, size.height / 2),
    math.min(size.width, size.height) / 2 / (viewState.fieldOfView / 2),
  );

  /// Screen positions of the compass points on the true horizon (altitude 0)
  /// for this painter's site, time and view, keyed by label.
  ///
  /// A point is omitted when it projects behind the viewer or lands off the
  /// canvas. Projection goes through [_celestialToScreen], which already
  /// branches on [SkyViewMode], so the labels follow the sky identically in the
  /// equatorial and horizontal views.
  Map<String, Offset> cardinalScreenPositions(Size size) {
    final (center, scale) = _projectionFrame(size);
    final lst = _lstHours;
    final positions = <String, Offset>{};

    for (final (label, azimuth) in _compassPoints) {
      final (ra, dec) = AstronomyCalculations.horizontalToEquatorial(
        altDeg: 0,
        azDeg: azimuth,
        latitudeDeg: latitude,
        lstHours: lst,
      );
      final offset = _celestialToScreen(
        CelestialCoordinate(ra: ra / 15, dec: dec),
        center,
        scale,
      );
      if (offset == null) continue;
      if (offset.dx < 0 ||
          offset.dx > size.width ||
          offset.dy < 0 ||
          offset.dy > size.height) {
        continue;
      }
      positions[label] = offset;
    }

    return positions;
  }

  /// Canvas rotation (radians) that puts the Moon's bright limb on the side
  /// facing the Sun, or null when it cannot be determined.
  ///
  /// The bright limb's position angle is defined against the local celestial
  /// north/east frame, so the frame is probed numerically through the painter's
  /// own projector: project the Moon, then a point a tenth of a degree north
  /// and a tenth of a degree east of it. Deriving both basis vectors this way
  /// (rather than assuming north is screen-up) keeps the orientation right
  /// under every projection, view mode, view rotation and axis flip without
  /// re-deriving the handedness of each.
  double? moonBrightLimbScreenAngle(Size size) {
    final sun = sunPosition;
    final moon = moonPosition;
    if (sun == null || moon == null) return null;

    final (moonRaDeg, moonDecDeg, _) = moon;
    final cosDec = math.cos(moonDecDeg * SkyCanvasPainter._deg2rad);
    // Near the pole the east probe's RA step blows up; the Moon never gets
    // there, so bail to the caller's fallback instead of guessing.
    if (cosDec < 0.01) return null;

    final (center, scale) = _projectionFrame(size);
    Offset? project(double raDeg, double decDeg) => _celestialToScreen(
      CelestialCoordinate(ra: raDeg / 15, dec: decDeg),
      center,
      scale,
    );

    const probeDeg = 0.1;
    final moonScreen = project(moonRaDeg, moonDecDeg);
    final northScreen = project(moonRaDeg, moonDecDeg + probeDeg);
    final eastScreen = project(moonRaDeg + probeDeg / cosDec, moonDecDeg);
    if (moonScreen == null || northScreen == null || eastScreen == null) {
      return null;
    }

    final north = northScreen - moonScreen;
    final east = eastScreen - moonScreen;
    if (north.distance < 1e-9 || east.distance < 1e-9) return null;

    final chi =
        MoonPhaseGeometry.brightLimbPositionAngleDeg(
          sunRaDeg: sun.$1,
          sunDecDeg: sun.$2,
          moonRaDeg: moonRaDeg,
          moonDecDeg: moonDecDeg,
        ) *
        SkyCanvasPainter._deg2rad;

    final limb =
        (north / north.distance) * math.cos(chi) +
        (east / east.distance) * math.sin(chi);
    if (limb.distance < 1e-9) return null;

    final angle = math.atan2(limb.dy, limb.dx);
    return angle.isFinite ? angle : null;
  }
}
