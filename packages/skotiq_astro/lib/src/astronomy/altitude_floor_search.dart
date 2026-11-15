import 'astronomy_calculations.dart';
import 'visibility_models.dart';

/// The altitude a target must clear toward an azimuth, in degrees: the site's
/// altitude floor as a function of direction.
typedef AltitudeFloorAt = double Function(double azimuthDegrees);

/// The altitude floor as samples by azimuth, interpolated linearly around the
/// compass: the form the app sends to the run and to background isolates.
/// One sample is the same floor in every direction.
class AltitudeFloorSamples {
  const AltitudeFloorSamples(this.azimuths, this.altitudes);

  /// The same floor in every direction.
  AltitudeFloorSamples.flat(double altitudeDeg)
    : azimuths = const [0.0],
      altitudes = [altitudeDeg];

  /// Ascending, in 0..360.
  final List<double> azimuths;
  final List<double> altitudes;

  double? get _flatAltitude => altitudes.length == 1 ? altitudes[0] : null;

  /// Whether the floor is the same in every direction.
  bool get isFlat => _flatAltitude != null;

  /// The floor in degrees toward [azimuthDeg].
  double at(double azimuthDeg) {
    final flat = _flatAltitude;
    if (flat != null) return flat;
    var az = azimuthDeg % 360.0;
    if (az < 0) az += 360.0;
    final n = azimuths.length;
    // The first sample at or past the azimuth; the one before it wraps.
    var hi = 0;
    while (hi < n && azimuths[hi] < az) {
      hi++;
    }
    final lo = (hi - 1 + n) % n;
    final loAz = hi == 0 ? azimuths[lo] - 360.0 : azimuths[lo];
    hi %= n;
    final hiAz = hi == 0 && az > azimuths[0]
        ? azimuths[0] + 360.0
        : azimuths[hi];
    final span = hiAz - loAz;
    if (span <= 0) return altitudes[lo];
    final t = (az - loAz) / span;
    return altitudes[lo] + t * (altitudes[hi] - altitudes[lo]);
  }
}

/// Whether a J2000 target is above the floor in the direction it stands at
/// [at].
bool targetIsAboveFloor(
  AltitudeFloorAt floorAt, {
  required double raDeg,
  required double decDeg,
  required DateTime at,
  required double latitudeDeg,
  required double longitudeDeg,
}) {
  final (alt, az) = AstronomyCalculations.objectAltAz(
    raDeg: raDeg,
    decDeg: decDeg,
    dt: at,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
  );
  return alt >= floorAt(az);
}

/// How finely a crossing of the floor is searched for.
const Duration _crossingStep = Duration(minutes: 1);

/// The first time in [from]..[until] that the target is above the floor
/// ([above]) or below it: [from] itself when it already is, null when it
/// never is.
DateTime? firstTimeAgainstFloor(
  AltitudeFloorAt floorAt, {
  required double raDeg,
  required double decDeg,
  required DateTime from,
  required DateTime until,
  required double latitudeDeg,
  required double longitudeDeg,
  required bool above,
}) {
  for (var at = from; !at.isAfter(until); at = at.add(_crossingStep)) {
    final isAbove = targetIsAboveFloor(
      floorAt,
      raDeg: raDeg,
      decDeg: decDeg,
      at: at,
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
    );
    if (isAbove == above) return at;
  }
  return null;
}

/// The longest stretch within [from]..[until] that the target stays above the
/// floor. Null when it never clears the floor in that span.
({DateTime start, DateTime end})? longestWindowAboveFloor(
  AltitudeFloorAt floorAt, {
  required double raDeg,
  required double decDeg,
  required DateTime from,
  required DateTime until,
  required double latitudeDeg,
  required double longitudeDeg,
}) {
  ({DateTime start, DateTime end})? longest;
  DateTime? cursor = from;
  while (cursor != null && cursor.isBefore(until)) {
    final start = firstTimeAgainstFloor(
      floorAt,
      raDeg: raDeg,
      decDeg: decDeg,
      from: cursor,
      until: until,
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
      above: true,
    );
    if (start == null) break;
    cursor = firstTimeAgainstFloor(
      floorAt,
      raDeg: raDeg,
      decDeg: decDeg,
      from: start,
      until: until,
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
      above: false,
    );
    final end = cursor ?? until;
    if (longest == null ||
        end.difference(start) > longest.end.difference(longest.start)) {
      longest = (start: start, end: end);
    }
  }
  return longest;
}

/// When a target clears and leaves the floor in the 24 hours centered on
/// [center], with its transit: [ObjectVisibility] measured against the floor
/// in the direction the target stands instead of against one altitude. A
/// target above the floor for the whole span is circumpolar; one that is
/// already above at its start has no rise time, and one still above at its
/// end no set time.
ObjectVisibility objectVisibilityAboveFloor(
  AltitudeFloorAt floorAt, {
  required double raDeg,
  required double decDeg,
  required DateTime center,
  required double latitudeDeg,
  required double longitudeDeg,
}) {
  final geometry = AstronomyCalculations.calculateObjectVisibilityAround(
    raDeg: raDeg,
    decDeg: decDeg,
    center: center,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
  );
  final from = center.subtract(const Duration(hours: 12));
  final until = center.add(const Duration(hours: 12));
  final above = longestWindowAboveFloor(
    floorAt,
    raDeg: raDeg,
    decDeg: decDeg,
    from: from,
    until: until,
    latitudeDeg: latitudeDeg,
    longitudeDeg: longitudeDeg,
  );
  final upAtStart = above != null && above.start == from;
  final upAtEnd = above != null && above.end == until;
  return ObjectVisibility(
    riseTime: above == null || upAtStart ? null : above.start,
    transitTime: geometry.transitTime,
    setTime: above == null || upAtEnd ? null : above.end,
    transitAltitude: geometry.transitAltitude,
    isCircumpolar: upAtStart && upAtEnd,
    neverRises: above == null,
  );
}
