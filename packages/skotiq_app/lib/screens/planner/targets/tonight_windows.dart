part of 'plan_targets_tab.dart';

/// Tonight's darkness and when one target stands above the site's altitude
/// floor inside it.
@immutable
class _TonightWindow {
  const _TonightWindow({
    required this.sunset,
    required this.dusk,
    required this.dawn,
    required this.sunrise,
    required this.altitudes,
    this.start,
    this.end,
  });

  /// The night in progress or coming: sunset, astronomical dusk and dawn,
  /// sunrise.
  final DateTime sunset;
  final DateTime dusk;
  final DateTime dawn;
  final DateTime sunrise;

  /// The target's altitude in degrees from sunset to sunrise, evenly sampled.
  final List<double> altitudes;

  /// The first and last moment of the longest stretch above the floor; null
  /// when the target never clears it tonight.
  final DateTime? start;
  final DateTime? end;

  bool get isUp => start != null && end != null;

  bool upAt(DateTime t) => isUp && !t.isBefore(start!) && t.isBefore(end!);

  /// The window as fractions of the night, for the window bar.
  CandidateWindow? bar(DateTime now) {
    final span = dawn.difference(dusk).inSeconds;
    if (!isUp || span <= 0) return null;
    double f(DateTime t) => (t.difference(dusk).inSeconds / span).clamp(0, 1);
    return CandidateWindow(start: f(start!), end: f(end!), now: f(now));
  }
}

/// Samples from sunset to sunrise: one every ten minutes of a sixteen-hour
/// night.
const int _kWindowSamples = 96;

/// Tonight's window for every saved target, by target id. Empty when no
/// observing site is set or the sun does not reach astronomical darkness.
final _tonightWindowsProvider =
    Provider.autoDispose<Map<int, _TonightWindow>>((ref) {
  final location = ref.watch(appObserverLocationProvider);
  final targets = ref.watch(allDbTargetsProvider).valueOrNull;
  if (location == null || targets == null) return const {};
  if (location.latitude == 0 && location.longitude == 0) return const {};
  final night = AstronomyCalculations.nightAt(
    now: ref.watch(clockProvider).now(),
    latitudeDeg: location.latitude,
    longitudeDeg: location.longitude,
  );
  final dusk = night.astronomicalDusk;
  final dawn = night.astronomicalDawn;
  if (dusk == null || dawn == null || !dawn.isAfter(dusk)) return const {};
  final sunset = night.sunset ?? dusk;
  final sunrise = night.sunrise ?? dawn;
  // The floor is the site's rule; this only asks it.
  final floor = ref.watch(altitudeFloorProvider);
  final step = sunrise.difference(sunset) ~/ (_kWindowSamples - 1);

  return {
    for (final target in targets)
      target.id: () {
        final altitudes = <double>[];
        final clear = <bool>[];
        for (var i = 0; i < _kWindowSamples; i++) {
          final (alt, az) = AstronomyCalculations.equatorialToHorizontal(
            raDeg: target.ra * 15.0,
            decDeg: target.dec,
            latitudeDeg: location.latitude,
            lstHours: AstronomyCalculations.localSiderealTime(
              sunset.add(step * i),
              location.longitude,
            ),
          );
          altitudes.add(alt);
          // Only darkness counts toward the window.
          final at = sunset.add(step * i);
          clear.add(
            !at.isBefore(dusk) && !at.isAfter(dawn) && floor.clears(alt, az),
          );
        }
        // The longest unbroken stretch above the floor.
        var bestStart = -1, bestLength = 0, runStart = -1;
        for (var i = 0; i <= _kWindowSamples; i++) {
          final up = i < _kWindowSamples && clear[i];
          if (up && runStart < 0) runStart = i;
          if (!up && runStart >= 0) {
            if (i - runStart > bestLength) {
              bestStart = runStart;
              bestLength = i - runStart;
            }
            runStart = -1;
          }
        }
        return _TonightWindow(
          sunset: sunset,
          dusk: dusk,
          dawn: dawn,
          sunrise: sunrise,
          altitudes: altitudes,
          start: bestStart < 0 ? null : sunset.add(step * bestStart),
          end: bestStart < 0
              ? null
              : sunset.add(step * (bestStart + bestLength - 1)),
        );
      }(),
  };
});
