// The night band — the signature moment at the top of Tonight (02, 06 §Tonight).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import 'tonight_night.dart';

/// How many altitude samples the arc is drawn from across the whole night.
///
/// 49 gives a sample every ~13 minutes over an 11-hour night — smooth at the
/// band's 52 px height, and cheap enough to recompute on the 30 s tick.
const int _altitudeSamples = 49;

/// The target's altitude across tonight, normalised 0–1 against the zenith,
/// plus the span of the night it is actually imageable in.
///
/// Null when there is no target, no site, or no night: the band then draws the
/// sky alone, which is the honest picture.
class TonightArc {
  const TonightArc({required this.curve, this.window});

  /// [_altitudeSamples] evenly spaced values, sunset → sunrise, 1.0 = zenith.
  final List<double> curve;

  /// Astronomical darkness intersected with "above the effective horizon".
  final NightBandWindow? window;
}

final tonightArcProvider = Provider<TonightArc?>((ref) {
  final night = ref.watch(tonightNightProvider);
  if (night == null) return null;

  final target = ref.watch(runDashboardActiveTargetProvider);
  if (target == null) return null;

  final location = ref.watch(appObserverLocationProvider);
  if (location == null) return null;

  final scheduler = ref.read(schedulerServiceProvider);
  final horizonDeg = ref.watch(effectiveHorizonDegProvider);

  final span = night.sunrise.difference(night.sunset);
  if (span <= Duration.zero) return null;

  final curve = <double>[];
  DateTime? windowStart;
  DateTime? windowEnd;

  for (var i = 0; i < _altitudeSamples; i++) {
    final at = night.sunset.add(span * (i / (_altitudeSamples - 1)));
    final (altitude, _) = scheduler.calculateAltAz(
      raHours: target.raHours,
      decDegrees: target.decDegrees,
      time: at,
      latitudeDegrees: location.latitude,
      longitudeDegrees: location.longitude,
    );
    curve.add((altitude / 90).clamp(0.0, 1.0));

    // The imageable window is what the operator can actually shoot: dark sky
    // AND the target clear of the horizon they configured. Reporting the dark
    // window alone would promise hours the target spends underground.
    final dark = !at.isBefore(night.astroDark) && !at.isAfter(night.astroDawn);
    if (dark && altitude >= horizonDeg) {
      windowStart ??= at;
      windowEnd = at;
    }
  }

  return TonightArc(
    curve: curve,
    window:
        (windowStart != null && windowEnd != null && windowEnd != windowStart)
            ? NightBandWindow(start: windowStart, end: windowEnd)
            : null,
  );
});

/// Tonight's night band, wired to the site.
///
/// Renders nothing at all when no site is set: 06 §Tonight is explicit that the
/// band is simply absent and checklist step 1 carries the problem, so there is
/// no placeholder and no banner here.
class TonightNightBand extends ConsumerWidget {
  const TonightNightBand({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final night = ref.watch(tonightNightProvider);
    if (night == null) return const SizedBox.shrink();
    final arc = ref.watch(tonightArcProvider);

    return NightBand(
      sunset: night.sunset,
      astroDark: night.astroDark,
      astroDawn: night.astroDawn,
      sunrise: night.sunrise,
      now: night.now,
      moonSet: night.moonSet,
      targetAltitudeCurve: arc?.curve,
      imageableWindow: arc?.window,
      events: <NightBandEvent>[
        NightBandEvent(
          time: night.sunset,
          label: '${tonightClock(night.sunset)} sunset',
        ),
        NightBandEvent(
          time: night.astroDark,
          label: '${tonightClock(night.astroDark)} astro dark',
        ),
        NightBandEvent(
          time: night.astroDawn,
          label: '${tonightClock(night.astroDawn)} astro dawn',
        ),
        NightBandEvent(
          time: night.sunrise,
          label: '${tonightClock(night.sunrise)} sunrise',
        ),
      ],
    );
  }
}
