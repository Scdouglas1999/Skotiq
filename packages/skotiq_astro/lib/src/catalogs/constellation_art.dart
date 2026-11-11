import '../coordinate_system.dart';

part 'constellation_art/figures_early.dart';
part 'constellation_art/figures_late.dart';

/// A single path segment for a constellation art figure.
/// Each segment is either a moveTo (starting a new sub-path) or a lineTo/curveTo.
sealed class ArtPathSegment {
  const ArtPathSegment();
}

/// Move to a celestial coordinate (starts a new sub-path)
class ArtMoveTo extends ArtPathSegment {
  final CelestialCoordinate point;
  const ArtMoveTo(this.point);
}

/// Line to a celestial coordinate
class ArtLineTo extends ArtPathSegment {
  final CelestialCoordinate point;
  const ArtLineTo(this.point);
}

/// Quadratic bezier curve to a celestial coordinate via a control point.
/// Control point is in celestial coordinates (RA hours, Dec degrees).
class ArtQuadTo extends ArtPathSegment {
  final CelestialCoordinate control;
  final CelestialCoordinate point;
  const ArtQuadTo(this.control, this.point);
}

/// Close the current sub-path back to the last moveTo
class ArtClose extends ArtPathSegment {
  const ArtClose();
}

/// Art overlay definition for a single constellation.
/// Each figure is composed of one or more closed or open paths that suggest
/// the mythological figure associated with the constellation. Vertices are
/// anchored to (or offset from) the constellation's named star positions.
class ConstellationArtData {
  /// IAU three-letter abbreviation (matches ConstellationData.abbreviation)
  final String abbreviation;

  /// Ordered path segments that form the figure outline
  final List<ArtPathSegment> segments;

  const ConstellationArtData({
    required this.abbreviation,
    required this.segments,
  });
}

/// Procedural constellation art figures for the 20 most recognizable
/// constellations. Each figure is a stylized outline suggesting the
/// mythological character, built from celestial coordinates anchored to
/// the constellation's prominent stars.
class ConstellationArt {
  static List<ConstellationArtData> get all => _figures;

  static ConstellationArtData? findByAbbreviation(String abbr) {
    final lower = abbr.toLowerCase();
    return _figures
        .where((f) => f.abbreviation.toLowerCase() == lower)
        .firstOrNull;
  }

  // Helper to create coordinates concisely
  static CelestialCoordinate _c(double ra, double dec) =>
      CelestialCoordinate(ra: ra, dec: dec);
}
