// The target card: the active target, where it is now, and how it and the
// moon move across tonight. Sky positions need the site; without one the card
// keeps the name and coordinates and leaves the rest out.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;
import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    show AstronomyCalculations, airmassForTrueAltitude;

import '../tonight_night.dart';
import '../../../sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import '../../night_control_contracts.dart';
import '../session/session_events_provider.dart';
import 'night_plan_inputs.dart';
import 'night_run_phase_provider.dart';

/// Altitude samples across the night: one every ~14 minutes over eleven
/// hours, the density the old night band drew its arc from.
const int _curveSamples = 49;

/// Solar seconds per sidereal second.
const double _siderealToSolar = 0.9972695663;

class _SkyCurves {
  const _SkyCurves({required this.target, required this.moon});
  final List<SeriesPoint> target;
  final List<SeriesPoint> moon;
}

/// The target's and the moon's altitude from sunset to sunrise.
///
/// Sampled on true instants and labeled on the operator's clock. Kept apart
/// from [nightTargetProvider] so the 30 s tick does not resample the night.
final _nightSkyCurvesProvider = Provider<_SkyCurves?>((ref) {
  final night = ref.watch(tonightNightProvider);
  final target = ref.watch(runDashboardActiveTargetProvider);
  final site = ref.watch(appObserverLocationProvider);
  if (night == null || target == null || site == null) return null;

  final clock = ref.watch(clockProvider);
  final scheduler = ref.read(schedulerServiceProvider);
  final start = clock.toInstant(night.sunset);
  final span = clock.toInstant(night.sunrise).difference(start);
  if (span <= Duration.zero) return null;

  final targetCurve = <SeriesPoint>[];
  final moonCurve = <SeriesPoint>[];
  for (var i = 0; i < _curveSamples; i++) {
    final at = start.add(span * (i / (_curveSamples - 1)));
    final (altitude, _) = scheduler.calculateAltAz(
      raHours: target.raHours,
      decDegrees: target.decDegrees,
      time: at,
      latitudeDegrees: site.latitude,
      longitudeDegrees: site.longitude,
    );
    final moonAltitude = AstronomyCalculations.moonAltitude(
      dt: at,
      latitudeDeg: site.latitude,
      longitudeDeg: site.longitude,
    );
    final t = clock.toNightClock(at);
    targetCurve.add(SeriesPoint(t, altitude));
    moonCurve.add(SeriesPoint(t, moonAltitude));
  }
  return _SkyCurves(target: targetCurve, moon: moonCurve);
});

/// The meridian transit of [raHours] (equinox of date) nearest [instant].
DateTime _transitNear(DateTime instant, double raHours, double longitude) {
  final lst = computeLocalSiderealTimeHours(instant.toUtc(), longitude);
  final hourAngle = computeHourAngleHours(raHours, lst);
  return instant.subtract(
    Duration(seconds: (hourAngle * 3600 * _siderealToSolar).round()),
  );
}

/// Hours past the meridian at which the configured flip fires, or null for
/// the tracking-limit methods, whose moment only the mount knows.
double? _flipHourAngle(MeridianFlipSettings settings) =>
    switch (settings.triggerMethod) {
      MeridianTriggerMethod.minutesPastMeridian =>
        settings.minutesPastMeridian / 60.0,
      MeridianTriggerMethod.hourAngleThreshold => settings.hourAngleThreshold,
      MeridianTriggerMethod.minutesBeforeLimit ||
      MeridianTriggerMethod.onTrackingLimitHit =>
        null,
    };

final nightTargetProvider = Provider<NightTargetVm?>((ref) {
  final target = ref.watch(runDashboardActiveTargetProvider);
  if (target == null) return null;

  final horizonDeg = ref.watch(effectiveHorizonDegProvider);
  final site = ref.watch(appObserverLocationProvider);
  final night = ref.watch(tonightNightProvider);
  final clock = ref.watch(clockProvider);

  final moonSet = night?.moonSet;
  final moonSetTonight = night != null &&
          moonSet != null &&
          !moonSet.isBefore(night.sunset) &&
          !moonSet.isAfter(night.sunrise)
      ? moonSet
      : null;

  if (site == null) {
    return NightTargetVm(
      name: target.displayName,
      nodeId: target.id,
      raHours: target.raHours,
      decDegrees: target.decDegrees,
      rotationDeg: target.rotation,
      horizonLimitDeg: horizonDeg,
      moonIlluminationPct: night?.moonIlluminationPercent,
      moonSet: moonSetTonight,
    );
  }

  final now = ref.watch(nightNowProvider);
  final scheduler = ref.read(schedulerServiceProvider);
  final (altitude, _) = scheduler.calculateAltAz(
    raHours: target.raHours,
    decDegrees: target.decDegrees,
    time: now,
    latitudeDegrees: site.latitude,
    longitudeDegrees: site.longitude,
  );
  // Hour angle and transit are measured from the equinox of date; the target's
  // coordinates are J2000.
  final (raOfDateDeg, _) = AstronomyCalculations.precessFromJ2000ToDate(
    raDeg: target.raHours * 15.0,
    decDeg: target.decDegrees,
    dt: now,
  );
  final raOfDateHours = raOfDateDeg / 15.0;
  final hourAngle = computeHourAngleHours(
    raOfDateHours,
    computeLocalSiderealTimeHours(now, site.longitude),
  );

  // Tonight's transit: the one nearest the middle of the night, kept only
  // when it falls inside it.
  final sunset = night == null ? null : clock.toInstant(night.sunset);
  final sunrise = night == null ? null : clock.toInstant(night.sunrise);
  bool tonight(DateTime t) =>
      sunset == null ||
      sunrise == null ||
      (!t.isBefore(sunset) && !t.isAfter(sunrise));
  final midNight = sunset == null || sunrise == null
      ? now
      : sunset.add(sunrise.difference(sunset) ~/ 2);
  final transit = _transitNear(midNight, raOfDateHours, site.longitude);
  final transitTonight = tonight(transit) ? transit : null;
  final transitAltitude = transitTonight == null
      ? null
      : scheduler
          .calculateAltAz(
            raHours: target.raHours,
            decDegrees: target.decDegrees,
            time: transitTonight,
            latitudeDegrees: site.latitude,
            longitudeDegrees: site.longitude,
          )
          .$1;

  final toLimit = scheduler.nextSetTime(
    raHours: target.raHours,
    decDegrees: target.decDegrees,
    now: now,
    latitudeDegrees: site.latitude,
    longitudeDegrees: site.longitude,
    horizonDeg: horizonDeg,
  );
  // Null when it never drops below the limit, or already has.
  final belowLimit =
      toLimit == null || toLimit == Duration.zero ? null : now.add(toLimit);

  final curves = ref.watch(_nightSkyCurvesProvider);

  return NightTargetVm(
    name: target.displayName,
    nodeId: target.id,
    raHours: target.raHours,
    decDegrees: target.decDegrees,
    rotationDeg: target.rotation,
    horizonLimitDeg: horizonDeg,
    altitudeDeg: altitude,
    hourAngleHours: hourAngle,
    airmass: airmassForTrueAltitude(altitude),
    altitudeCurve: curves?.target,
    moonAltitudeCurve: curves?.moon,
    moonIlluminationPct: night?.moonIlluminationPercent,
    moonSet: moonSetTonight,
    transitAt:
        transitTonight == null ? null : clock.toNightClock(transitTonight),
    transitAltitudeDeg: transitAltitude,
    belowLimitAt: belowLimit != null && tonight(belowLimit)
        ? clock.toNightClock(belowLimit)
        : null,
    flipAt: _flipAt(
      ref,
      now: now,
      transit: transit,
      tonight: tonight,
    ),
  );
});

/// The next meridian flip on the operator's clock, or null when flips are
/// off, the method leaves the moment to the mount, or none comes tonight.
///
/// During a run the mount's own countdown (the meridian banner's) decides;
/// otherwise the flip is predicted from the target's transit, since the mount
/// may be pointing anywhere before the plan slews it.
DateTime? _flipAt(
  Ref ref, {
  required DateTime now,
  required DateTime transit,
  required bool Function(DateTime) tonight,
}) {
  if (!ref.watch(isMeridianFlipEnabledProvider)) return null;
  final settings = ref.watch(effectiveMeridianFlipSettingsProvider);
  final clock = ref.watch(clockProvider);

  if (ref.watch(nightRunPhaseProvider).isRunLive) {
    final site = ref.watch(appObserverLocationProvider);
    final countdown = computeMeridianCountdown(
      mount: ref.watch(mountStateProvider),
      longitude: site?.longitude,
      latitude: site?.latitude,
      settings: settings,
      execState: ref.watch(sequenceExecutionStateProvider),
      enabled: true,
      nowUtc: now,
    );
    final toFlip = countdown.timeToFlip;
    if (countdown.isArmed && toFlip != null) {
      // Past the threshold the countdown reads zero whether or not the flip
      // has run; one that succeeded during this run has done this transit's
      // flip, and the next is a night away.
      if (toFlip == Duration.zero && _flippedThisRun(ref)) return null;
      return clock.toNightClock(now.add(toFlip));
    }
  }

  final flipHourAngle = _flipHourAngle(settings);
  if (flipHourAngle == null) return null;
  final flip = transit.add(
    Duration(seconds: (flipHourAngle * 3600 * _siderealToSolar).round()),
  );
  if (flip.isBefore(now) || !tonight(flip)) return null;
  return clock.toNightClock(flip);
}

/// Whether a meridian flip succeeded since the run started.
bool _flippedThisRun(Ref ref) {
  final flips = ref.watch(nightSessionEventsProvider.select((e) => e.flips));
  if (flips.isEmpty) return false;
  final started = ref.watch(sessionStateProvider.select((s) => s.startTime));
  return started == null || !flips.last.isBefore(started);
}
