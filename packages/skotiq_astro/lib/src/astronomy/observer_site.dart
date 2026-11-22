/// Whether an observing site has been set.
///
/// A fresh profile seeds the observer latitude and longitude at 0.0 before
/// the user has been asked anything, so stored coordinates always parse to a
/// valid position. 0°, 0° is a real point in the Gulf of Guinea, about 600 km
/// off Ghana, and nothing observes from there, so the origin is the "not set"
/// sentinel, the way a Target node's 0h/+0° birth coordinates are unset.
///
/// An operator genuinely at 0°, 0° reads as unset; nudging either value by a
/// millionth of a degree (the precision the Location editor exposes) claims
/// it back.
bool siteLocationIsSet(double latitude, double longitude) =>
    latitude != 0.0 || longitude != 0.0;

/// A site coordinate from a lookup (internet address, Wi-Fi, a place name)
/// to four decimals of a degree, about 11 m: finer than any lookup places a
/// site, so the digits past it are noise. A coordinate the user types is kept
/// as typed.
double roundSiteEstimate(double degrees) =>
    double.parse(degrees.toStringAsFixed(4));
