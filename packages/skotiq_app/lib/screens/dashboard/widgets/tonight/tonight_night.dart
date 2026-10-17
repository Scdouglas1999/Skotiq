// The night's facts, resolved once for every Tonight surface that needs them.
//
// The hero line, the night band and the moon panel all quote the same four
// instants (sunset, astronomical dark, astronomical dawn, sunrise) and the same
// moon. Deriving them three times invites three different answers — the audit
// found the header chip and the timeline disagreeing by a timezone — so they
// are derived ONCE here, already converted to the operator's chosen clock.

import 'package:flutter_riverpod/flutter_riverpod.dart';
// skotiq_core also exports a (scheduler) TwilightTimes; this file means the
// planetarium one that `siteTwilightTimesProvider` returns.
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;

import '../../../../services/observing_site.dart';

/// Tonight's sun and moon, on the operator's clock.
///
/// Only built when the site has a real night: a place with no sunset tonight
/// (polar day) yields null, and the screen then simply has no band — checklist
/// step 1 is the ONE place a missing site is represented (06 §Tonight).
class TonightNight {
  const TonightNight({
    required this.sunset,
    required this.astroDark,
    required this.astroDawn,
    required this.sunrise,
    required this.now,
    this.moonRise,
    this.moonSet,
    this.moonIlluminationPercent,
  });

  final DateTime sunset;
  final DateTime astroDark;
  final DateTime astroDawn;
  final DateTime sunrise;

  /// Now, on the same clock as the four instants above, at the tick that
  /// produced it.
  final DateTime now;

  final DateTime? moonRise;
  final DateTime? moonSet;

  /// The lit fraction of the disc as a PERCENTAGE, 0–100.
  ///
  /// `MoonTimes.illumination` is already scaled by 100 (see
  /// `skotiq_planetarium` `calc/moon.dart`: `(1 + cos(phaseAngle)) / 2 *
  /// 100`). Treating it as a 0–1 fraction and scaling it again printed
  /// "Moon 238%" for a 2.38 % crescent, so the unit is named here and
  /// [moonIlluminationPercent] is the only thing callers format.
  final double? moonIlluminationPercent;

  /// The rounded percentage for display, or null when there is no moon data.
  int? get moonIlluminationRounded => moonIlluminationPercent?.round();

  /// How long astronomical darkness lasts.
  Duration get darkDuration => astroDawn.difference(astroDark);

  /// Time until darkness begins, or null once it has.
  Duration? get untilDark =>
      now.isBefore(astroDark) ? astroDark.difference(now) : null;

  /// True while the sky is astronomically dark.
  bool get isDark => !now.isBefore(astroDark) && now.isBefore(astroDawn);
}

/// Tonight's sun and moon, or null when there is no site or no night.
///
/// Ticks at 30 s. A one-second clock would repaint the band's gradient sixty
/// times a minute for a marker that moves a fifth of a pixel.
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
  final tick = ref.watch(tickerProvider(TickerCadence.thirtySeconds));
  final now = tick.valueOrNull ?? clock.now();
  final moon = ref.watch(siteMoonTimesProvider);
  final moonRise = moon?.moonrise;
  final moonSet = moon?.moonset;

  DateTime local(DateTime t) => clock.fromUtc(t.toUtc());

  return TonightNight(
    sunset: local(sunset),
    astroDark: local(astroDark),
    astroDawn: local(astroDawn),
    sunrise: local(sunrise),
    now: local(now),
    moonRise: moonRise == null ? null : local(moonRise),
    moonSet: moonSet == null ? null : local(moonSet),
    moonIlluminationPercent: moon?.illumination,
  );
});

/// `HH:MM`, on the clock the rest of the screen uses.
String tonightClock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:'
    '${t.minute.toString().padLeft(2, '0')}';

/// `2 h 54 m`, or `54 m` under the hour. Null stays null so the caller can
/// render the em dash a [Readout] already knows how to draw.
String? tonightDuration(Duration? d) {
  if (d == null || d.isNegative) return null;
  final hours = d.inHours;
  final minutes = d.inMinutes % 60;
  if (hours == 0) return '$minutes m';
  return '$hours h $minutes m';
}
