part of '../planetarium_providers.dart';

// Catalog providers

/// The star list the renderer and search draw from.
///
/// Delegates to [starsProvider] so there is exactly one [HygStarCatalog]
/// instance, one CSV parse and one retained list — see [starCatalogProvider].
final loadedStarsProvider = FutureProvider<List<Star>>((ref) async {
  return ref.watch(starsProvider.future);
});

final loadedDsosProvider = FutureProvider<List<DeepSkyObject>>((ref) async {
  // Load DSOs up to magnitude 16.0 to include faint imaging targets when zoomed in.
  // The dynamic magnitude limit provider filters them per-frame based on FOV.
  return OpenNgcDsoCatalog(magnitudeLimit: 16.0).loadObjects();
});

/// Spatial index for stars to avoid scanning full catalogs per frame.
final starSpatialIndexProvider = FutureProvider<StarSpatialIndex>((ref) async {
  final stars = await ref.watch(loadedStarsProvider.future);
  final index = StarSpatialIndex();
  // The loader isolate already returns stars sorted by magnitude (brightest
  // first), so prime the magnitude view instead of re-sorting on the UI thread.
  index.addAllPreSortedByMagnitude(stars);
  // Warm the grid off the critical path so the first zoom past the wide-field
  // threshold (~12 deg) doesn't hitch building the grid mid-gesture.
  Future.delayed(const Duration(milliseconds: 400), () {
    try {
      index.warmGrid();
    } catch (e) {
      // Warm-up is purely a latency optimization — the grid lazily builds on
      // first use anyway — but a throwing warm path means real queries will
      // hit the same error, so surface it.
      developer.log(
        'Spatial index grid warm-up failed: $e',
        name: 'skotiq.planetarium',
      );
    }
  });
  return index;
});

/// Spatial index for DSOs to avoid scanning full catalogs per frame.
final dsoSpatialIndexProvider = FutureProvider<DsoSpatialIndex>((ref) async {
  final dsos = await ref.watch(loadedDsosProvider.future);
  final index = DsoSpatialIndex();
  // Loader isolate returns DSOs magnitude-sorted; prime to skip a UI-thread sort.
  index.addAllPreSortedByMagnitude(dsos);
  // Warm the grid off the critical path (see starSpatialIndexProvider).
  Future.delayed(const Duration(milliseconds: 400), () {
    try {
      index.warmGrid();
    } catch (e) {
      // Warm-up is purely a latency optimization — the grid lazily builds on
      // first use anyway — but a throwing warm path means real queries will
      // hit the same error, so surface it.
      developer.log(
        'Spatial index grid warm-up failed: $e',
        name: 'skotiq.planetarium',
      );
    }
  });
  return index;
});

/// Stars filtered by dynamic magnitude limit based on current FOV
/// As the user zooms in (narrower FOV), fainter stars become visible.
/// This provider should be used by the sky renderer for FOV-aware star display.
final fovFilteredStarsProvider = Provider<AsyncValue<List<Star>>>((ref) {
  final indexAsync = ref.watch(starSpatialIndexProvider);
  final (starMagLimit, _) = ref.watch(dynamicMagnitudeLimitsProvider);
  // The center must come from [viewCenterEquatorialProvider], not from
  // skyViewState directly — in alt/az mode centerRA/centerDec point somewhere
  // else entirely. Rotation is deliberately not a dependency: rolling the view
  // does not change which objects are in it.
  final (centerRa, centerDec) = ref.watch(viewCenterEquatorialProvider);
  final fov = ref.watch(skyViewStateProvider.select((s) => s.fieldOfView));
  final maxStars = ref.watch(fovAdaptiveQualityProvider).maxStarsToRender;
  final aspect = ref.watch(skyViewAspectRatioProvider);

  return indexAsync.whenData((index) {
    // Return only the brightest [maxStars] in view — the exact set the renderer
    // draws (it caps to maxStarsToRender). At wide fields this avoids gathering
    // and full-sorting tens of thousands of stars every pan frame.
    return index.queryBrightestInViewport(
      centerRa,
      centerDec,
      fov,
      maxMagnitude: starMagLimit,
      maxResults: maxStars,
      aspectRatio: aspect,
    );
  });
});

/// DSOs filtered by dynamic magnitude limit based on current FOV
/// As the user zooms in (narrower FOV), fainter DSOs become visible.
/// This provider should be used by the sky renderer for FOV-aware DSO display.
final fovFilteredDsosProvider = Provider<AsyncValue<List<DeepSkyObject>>>((
  ref,
) {
  final indexAsync = ref.watch(dsoSpatialIndexProvider);
  final (_, dsoMagLimit) = ref.watch(dynamicMagnitudeLimitsProvider);
  final (centerRa, centerDec) = ref.watch(viewCenterEquatorialProvider);
  final fov = ref.watch(skyViewStateProvider.select((s) => s.fieldOfView));
  final maxDsos = ref.watch(fovAdaptiveQualityProvider).maxDsosToRender;
  final aspect = ref.watch(skyViewAspectRatioProvider);

  return indexAsync.whenData((index) {
    return index.queryBrightestInViewport(
      centerRa,
      centerDec,
      fov,
      maxMagnitude: dsoMagLimit,
      maxResults: maxDsos,
      aspectRatio: aspect,
    );
  });
});

final constellationDataProvider = Provider<List<ConstellationData>>((ref) {
  return Constellations.all;
});

// Computed astronomy data providers

/// Provider that only updates when the date changes (not every second)
/// This prevents unnecessary recalculations of date-dependent values like twilight.
final _currentDateProvider = Provider<DateTime>((ref) {
  final time = ref.watch(observationTimeProvider);
  // Return only the date portion, so it only changes at midnight. Preserves
  // UTC-ness for the same reason as [_currentMinuteProvider].
  final t = time.time;
  return t.isUtc
      ? DateTime.utc(t.year, t.month, t.day)
      : DateTime(t.year, t.month, t.day);
});

/// The date of the observing NIGHT in progress — what
/// [AstronomyCalculations.calculateObjectVisibility] wants as its `date`.
///
/// Distinct from [_currentDateProvider]: between local midnight and noon the
/// night in progress began the previous calendar day, so anchoring rise /
/// transit / set on the calendar date describes the FOLLOWING night and puts
/// every time one sidereal day (~4 min) out. Cheap to watch — the value only
/// changes at local noon.
final _currentNightDateProvider = Provider<DateTime>((ref) {
  return AstronomyCalculations.nightDateOf(
    ref.watch(observationTimeProvider).time,
  );
});

/// Provider that only updates when the minute changes (not every second)
/// This prevents unnecessary recalculations of astronomical positions
/// which don't need per-second precision for sky rendering.
final _currentMinuteProvider = Provider<DateTime>((ref) {
  final time = ref.watch(observationTimeProvider);
  // Return only up to minute precision, ignoring seconds.
  //
  // Truncating through the local `DateTime(...)` constructor DROPS the UTC flag,
  // so a UTC observation time came back out as a local wall-clock time and every
  // downstream sidereal-time, sun-altitude and alt/az calculation was off by the
  // host's UTC offset. Local times (the app's own clock is `DateTime.now()`) are
  // unaffected either way; this just stops silently relabelling a UTC instant.
  final t = time.time;
  return t.isUtc
      ? DateTime.utc(t.year, t.month, t.day, t.hour, t.minute)
      : DateTime(t.year, t.month, t.day, t.hour, t.minute);
});

/// Public provider for observation time at minute precision.
/// Use this for sky rendering to avoid rebuilds every second.
/// The sky doesn't visibly change in one second, but rebuilding every second hurts performance.
final observationMinuteProvider = Provider<DateTime>((ref) {
  return ref.watch(_currentMinuteProvider);
});

/// What one rise/set/transit solve depends on.
///
/// A record, so Riverpod's family keying gets structural equality for free.
/// [nightDate] is the output of [AstronomyCalculations.nightDateOf], which
/// changes only at local noon — that is what makes the memo worth having.
typedef ObjectVisibilityKey = ({
  double raDeg,
  double decDeg,
  DateTime nightDate,
  double latitudeDeg,
  double longitudeDeg,
  double minAltitude,
});

/// Memoised rise/set/transit for one object on one night from one site.
///
/// [AstronomyCalculations.calculateObjectVisibility] samples altitude every 5
/// minutes across a 24 h window (289 sidereal-time + alt/az chains), then
/// bisects every horizon crossing and ternary-searches the transit. The object
/// details panel called it twice per rebuild while sitting under a 1 Hz clock,
/// so the same answer was recomputed roughly 86,400 times a night on the UI
/// isolate. Nothing in the key moves faster than local noon.
final objectVisibilityProvider = Provider.autoDispose
    .family<ObjectVisibility, ObjectVisibilityKey>((ref, key) {
      return AstronomyCalculations.calculateObjectVisibility(
        raDeg: key.raDeg,
        decDeg: key.decDeg,
        date: key.nightDate,
        latitudeDeg: key.latitudeDeg,
        longitudeDeg: key.longitudeDeg,
        minAltitude: key.minAltitude,
      );
    });

/// The two night windows the current instant can belong to: the one that
/// started on the PREVIOUS calendar evening and the one starting tonight.
///
/// Recomputed only when the calendar date (or the site) changes; the choice
/// between them is made per-minute by [twilightTimesProvider].
///
/// With no site on record every field is null: twilight is a fact about a
/// place, so there is nothing to state until the observer names one.
final _nightWindowCandidatesProvider =
    Provider<({TwilightTimes previous, TwilightTimes today})>((ref) {
      final site = ref.watch(observerLocationProvider).site;
      final currentDate = ref.watch(_currentDateProvider);

      if (site == null) {
        return (previous: const TwilightTimes(), today: const TwilightTimes());
      }

      TwilightTimes forDate(DateTime date) =>
          AstronomyCalculations.calculateTwilightTimes(
            date: date,
            latitudeDeg: site.latitude,
            longitudeDeg: site.longitude,
          );

      return (
        previous: forDate(currentDate.subtract(const Duration(days: 1))),
        today: forDate(currentDate),
      );
    });

/// Twilight times for the observing night that is in progress, or — once it
/// has ended — the one starting tonight.
///
/// `calculateTwilightTimes(date:)` returns a dusk-tonight → dawn-tomorrow
/// window. Between local midnight and astronomical dawn the night actually in
/// progress is the PREVIOUS date's window; anchoring on the calendar date
/// describes the next night instead, while the current one is still running.
final twilightTimesProvider = Provider<TwilightTimes>((ref) {
  final candidates = ref.watch(_nightWindowCandidatesProvider);
  final now = ref.watch(_currentMinuteProvider);

  final previousDawn = candidates.previous.astronomicalDawn;
  if (previousDawn != null && previousDawn.isAfter(now)) {
    return candidates.previous;
  }
  return candidates.today;
});

/// Moon information for current time and location
/// Uses date precision for rise/set, minute precision for illumination.
///
/// Phase and illumination are the same everywhere on Earth, so they are stated
/// whether or not a site is on record; rise and set are null without one.
final moonInfoProvider = Provider<MoonTimes>((ref) {
  final site = ref.watch(observerLocationProvider).site;
  final currentDate = ref.watch(_currentDateProvider);
  final currentMinute = ref.watch(_currentMinuteProvider);

  // Calculate phase and illumination - minute precision is sufficient
  final illumination = AstronomyCalculations.moonIllumination(currentMinute);
  final phaseName = AstronomyCalculations.moonPhaseName(currentMinute);

  if (site == null) {
    return MoonTimes(illumination: illumination, phaseName: phaseName);
  }

  // Calculate rise/set times for the date
  final moonTimes = AstronomyCalculations.calculateMoonTimes(
    date: currentDate,
    latitudeDeg: site.latitude,
    longitudeDeg: site.longitude,
  );

  // Return combined data
  return MoonTimes(
    moonrise: moonTimes.moonrise,
    moonset: moonTimes.moonset,
    illumination: illumination,
    phaseName: phaseName,
  );
});

/// Local Sidereal Time **now**, at the observing site.
///
/// Per-second precision, from the wall clock — not from
/// [observationTimeProvider]. The shell status bar and the dashboard header
/// render this beside a real clock, and sidereal time is what an imager reads
/// to decide what is transiting, so a scrubbed one has to stay inside the
/// screen simulating it — see [observationSiderealTimeProvider].
///
/// Null with no site on record: sidereal time is a function of longitude.
final localSiderealTimeProvider = Provider<double?>((ref) {
  final site = ref.watch(observerLocationProvider).site;
  if (site == null) return null;
  final now = ref.watch(wallClockProvider);

  return AstronomyCalculations.localSiderealTime(now, site.longitude);
});

/// Local Sidereal Time at the planetarium's *observation* time, which the time
/// transport can hold, accelerate or jump.
///
/// For readouts that belong to the simulated sky itself — the planetarium's own
/// overlays — where following the scrub is the whole point.
/// Null with no site on record.
final observationSiderealTimeProvider = Provider<double?>((ref) {
  final site = ref.watch(observerLocationProvider).site;
  if (site == null) return null;
  final time = ref.watch(observationTimeProvider);

  return AstronomyCalculations.localSiderealTime(time.time, site.longitude);
});

/// Apparent Sun altitude in degrees at the observing site and the planetarium's
/// current observation time. Negative means the Sun is below the horizon.
///
/// Public because observability is not a function of target altitude alone:
/// anything that grades a target ("Excellent", green pill, above-horizon
/// colouring) has to know whether the sky is dark enough to use it.
/// Null with no site on record — how far the Sun is below the horizon depends
/// on where the observer is standing.
final sunAltitudeProvider = Provider<double?>((ref) {
  final site = ref.watch(observerLocationProvider).site;
  if (site == null) return null;
  final time = ref.watch(_currentMinuteProvider);

  return AstronomyCalculations.sunAltitude(
    dt: time,
    latitudeDeg: site.latitude,
    longitudeDeg: site.longitude,
  );
});

/// Sun position for the current time, in **J2000** — the chart's frame.
///
/// [AstronomyCalculations.sunPosition] is a theory of date, so its output is
/// precessed back to J2000 here. Everything drawn on the sky chart has to share
/// one equinox with the J2000 star and DSO catalogues; mixing frames displaced
/// the solar-system bodies from the star background by ~22 arcmin in 2026.
/// The of-date function is untouched, so twilight, rise/set and the altitude
/// providers that call it directly keep their (correct) apparent places.
///
/// Uses minute precision - sun moves ~0.25 degrees per minute which is fine for rendering.
final sunPositionProvider = Provider<(double ra, double dec)>((ref) {
  final time = ref.watch(_currentMinuteProvider);
  final (ra, dec) = AstronomyCalculations.sunPosition(time);
  return AstronomyCalculations.precessFromDateToJ2000(
    raDeg: ra,
    decDeg: dec,
    dt: time,
  );
});

/// Moon position for the current time, in **J2000** — see [sunPositionProvider]
/// for why. Distance (km) is frame independent and passes through.
///
/// This also puts the moon-separation scoring in `planning_providers.dart` on
/// the same frame as the J2000 target it measures against.
///
/// Uses minute precision - moon moves ~0.5 arcmin per minute which is fine for rendering.
final moonPositionProvider = Provider<(double ra, double dec, double distance)>(
  (ref) {
    final time = ref.watch(_currentMinuteProvider);
    final (ra, dec, distance) = AstronomyCalculations.moonPosition(time);
    final (raJ2000, decJ2000) = AstronomyCalculations.precessFromDateToJ2000(
      raDeg: ra,
      decDeg: dec,
      dt: time,
    );
    return (raJ2000, decJ2000, distance);
  },
);

/// Planet positions for current time
/// Uses minute precision - planets move very slowly, minute precision is more than enough.
final planetPositionsProvider = Provider<List<PlanetData>>((ref) {
  final time = ref.watch(_currentMinuteProvider);
  return PlanetaryPositions.getAllPlanetPositions(time);
});

/// Milky Way points for rendering (static, only needs to be generated once)
final milkyWayPointsProvider = Provider<List<MilkyWayPoint>>((ref) {
  return MilkyWayData.generateMilkyWayPoints();
});
