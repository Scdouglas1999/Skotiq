// The night's facts, resolved once for every Tonight surface that needs them.
//
// The timeline, the target section, coming up and the header all quote the
// same four instants (sunset, astronomical dark, astronomical dawn, sunrise)
// and the same moon. They are derived once here, already on the operator's
// chosen clock, so no two surfaces can disagree by a time zone.

import 'package:flutter_riverpod/flutter_riverpod.dart';
// skotiq_core also exports a (scheduler) TwilightTimes; this file means the
// planetarium one that `siteTwilightTimesProvider` returns.
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;

import '../../../services/observing_site.dart';

/// Tonight's sun and moon, on the operator's clock.
///
/// Only built when the site has a real night: a place with no sunset tonight
/// (polar day) yields null.
///
/// "Now" is not part of it: the screen reads the current instant from
/// `nightNowProvider`, so these facts do not rebuild on every tick.
class TonightNight {
  const TonightNight({
    required this.sunset,
    required this.astroDark,
    required this.astroDawn,
    required this.sunrise,
    this.moonRise,
    this.moonSet,
    this.moonIlluminationPercent,
  });

  final DateTime sunset;
  final DateTime astroDark;
  final DateTime astroDawn;
  final DateTime sunrise;

  final DateTime? moonRise;
  final DateTime? moonSet;

  /// The lit fraction of the disc as a PERCENTAGE, 0–100.
  ///
  /// `MoonTimes.illumination` is already scaled by 100 (see
  /// `skotiq_planetarium` `calc/moon.dart`: `(1 + cos(phaseAngle)) / 2 *
  /// 100`). Treating it as a 0–1 fraction and scaling it again printed
  /// "Moon 238%" for a 2.38 % crescent.
  final double? moonIlluminationPercent;
}

/// Tonight's sun and moon, or null when there is no site or no night.
///
/// The planetarium returns true instants; each is moved onto the operator's
/// clock exactly once.
final tonightNightProvider = Provider<TonightNight?>((ref) {
  final twilight = ref.watch(siteTwilightTimesProvider);
  if (twilight == null) return null;

  final sunset = twilight.sunset;
  final sunrise = twilight.sunrise;
  final astroDark = twilight.astronomicalDusk;
  final astroDawn = twilight.astronomicalDawn;
  if (sunset == null ||
      sunrise == null ||
      astroDark == null ||
      astroDawn == null) {
    return null;
  }

  final clock = ref.watch(clockProvider);
  final moon = ref.watch(siteMoonTimesProvider);
  final moonRise = moon?.moonrise;
  final moonSet = moon?.moonset;

  DateTime local(DateTime t) => clock.fromUtc(t.toUtc());

  return TonightNight(
    sunset: local(sunset),
    astroDark: local(astroDark),
    astroDawn: local(astroDawn),
    sunrise: local(sunrise),
    moonRise: moonRise == null ? null : local(moonRise),
    moonSet: moonSet == null ? null : local(moonSet),
    moonIlluminationPercent: moon?.illumination,
  );
});
