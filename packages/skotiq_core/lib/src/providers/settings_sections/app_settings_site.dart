part of '../settings_provider.dart';

/// P1 — Observer-location "unset" detection.
///
/// Latitude/longitude/elevation default to 0.0 when the user has never
/// entered a location (the DB seed and every loader fall back to 0.0). The
/// point (0°, 0°) is in the Gulf of Guinea — a perfectly valid coordinate,
/// but in practice it is the unmistakable signature of "never configured".
/// A whole night planned for that point (rise/set times, moon separation,
/// meridian flips, FITS SITELAT/SITELONG) is silently wrong.
///
/// This extension exposes a loud, model-level signal so pre-flight / Smart
/// Night / scheduler code can block (or warn) before computing a night for
/// coordinates the user never actually set. It deliberately lives at the
/// model level (no UI here) so every consumer shares one definition of
/// "location not set".
extension LocationUnsetDetection on AppSettingsState {
  /// Tolerance (in degrees) around the null island within which we treat the
  /// coordinate as unset rather than a deliberate (0,0) choice. ~1.1 km at the
  /// equator — far tighter than any real observing site a user would pick on
  /// purpose, but wide enough to absorb float round-trips through the DAO's
  /// string storage.
  static const double _unsetEpsilonDeg = 0.01;

  /// True when the observer latitude AND longitude are both effectively zero,
  /// i.e. the user has never set a real location. Elevation is ignored on
  /// purpose: many valid sites are at (or near) sea level, so a 0 m elevation
  /// alone must NOT mark the location unset.
  bool get isLocationUnset =>
      latitude.abs() < _unsetEpsilonDeg && longitude.abs() < _unsetEpsilonDeg;

  /// Convenience inverse of [isLocationUnset] for readability at call sites
  /// that gate on a *configured* location.
  bool get isLocationSet => !isLocationUnset;
}

extension ObserverSiteOfSettings on AppSettingsState {
  /// Whether the operator has actually given Skotiq an observing site.
  ///
  /// See [siteLocationIsSet] for why the origin is the sentinel. Prefer this
  /// (or [observerSite]) over re-testing [latitude] and [longitude] at the call
  /// site: the hand-rolled copies of that comparison drifted, which is how
  /// Settings → Location came to print `0 °` as a settled coordinate while the
  /// Dashboard beside it said "Set an observing location".
  bool get hasObserverLocation => siteLocationIsSet(latitude, longitude);

  /// The configured site, or null when none has been set.
  ///
  /// This is the null-vs-zero seam: [latitude] and [longitude] are
  /// non-nullable doubles that a fresh profile fills with 0.0, so they cannot
  /// themselves express "the user never chose". Anything that renders a
  /// position, or derives an altitude / azimuth / twilight from one, should
  /// take it from here and show an honest empty state for null.
  ObserverLocation? get observerSite => hasObserverLocation
      ? ObserverLocation(
          latitude: latitude,
          longitude: longitude,
          elevation: elevation,
        )
      : null;
}

/// Canonical "is there an observing site?" test.
///
/// A fresh profile seeds `observer_latitude` / `observer_longitude` /
/// `observer_elevation` at 0.0 before the user has been asked anything, so the
/// stored coordinates always parse to a *valid* position — 0°, 0° is a real
/// point, in the Gulf of Guinea, about 600 km off Ghana. Nothing observes from
/// there, so the origin is the app's documented "not set" sentinel, exactly as
/// `targetCoordinatesUnset` treats a Target node's 0h/+0° birth coordinates.
///
/// The cost is that an operator genuinely at 0°, 0° reads as unset; nudging
/// either value by a millionth of a degree (the precision the Location editor
/// already exposes) claims it back.
bool siteLocationIsSet(double latitude, double longitude) =>
    latitude != 0.0 || longitude != 0.0;
