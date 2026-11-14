// When a run is stopped whatever its plan says: the park before dawn.
//
// The plan estimates (Tonight's plan card and ETA, the Sequencer's totals and
// row durations) bound a "loop until stopped" block by its target's window;
// the dawn park bounds the night itself, so a window that would run past it
// ends there.
import 'package:skotiq_astro/skotiq_astro.dart';
import '../settings_provider.dart' show siteLocationIsSet;

/// How long before astronomical dawn the dawn rule parks a running run, as
/// `WeatherSafetyNotifier` applies it.
const Duration kParkBeforeDawnLead = Duration(minutes: 30);

/// When the dawn rule parks a running run: [kParkBeforeDawnLead] before the
/// next astronomical dawn at the site. Null when the site has no
/// astronomical dawn (a night that never gets fully dark).
///
/// "Next" the way the rule reads it: last night's dawn while it is still
/// ahead (after midnight), otherwise tonight's.
DateTime? dawnParkTime({
  required DateTime now,
  required double latitude,
  required double longitude,
}) => AstronomyCalculations.nextDawn(
  now: now,
  latitudeDeg: latitude,
  longitudeDeg: longitude,
)?.subtract(kParkBeforeDawnLead);

/// When a run started at [now] is stopped by the dawn park, or null when
/// "Park before dawn" is off, the site is unset, or no dawn comes.
DateTime? planRunEndsBy({
  required bool parkBeforeDawn,
  required double? latitude,
  required double? longitude,
  required DateTime now,
}) {
  if (!parkBeforeDawn || latitude == null || longitude == null) return null;
  if (!siteLocationIsSet(latitude, longitude)) return null;
  return dawnParkTime(now: now, latitude: latitude, longitude: longitude);
}
