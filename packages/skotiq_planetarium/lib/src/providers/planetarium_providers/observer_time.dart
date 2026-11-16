part of '../planetarium_providers.dart';

/// The site the planetarium computes against.
///
/// [latitude] / [longitude] are null until a site is on record. No coordinates
/// are assumed for an observer who has not chosen one: everything derived from
/// the site — twilight, moon rise/set, sidereal time, alt/az, the sky itself —
/// reports unknown rather than a place the observer is not at. Read [site] to
/// get the pair or nothing; the two fields are only ever both set or both null.
class PlanetariumObserver {
  final double? latitude;
  final double? longitude;
  final double elevation;
  final String? locationName;

  const PlanetariumObserver({
    this.latitude,
    this.longitude,
    this.elevation = 0,
    this.locationName,
  });

  /// The coordinates to compute with, or null when no site is on record.
  ({double latitude, double longitude})? get site {
    final lat = latitude;
    final lon = longitude;
    if (lat == null || lon == null) return null;
    return (latitude: lat, longitude: lon);
  }

  /// Whether a site is on record.
  bool get hasSite => site != null;

  PlanetariumObserver copyWith({
    double? latitude,
    double? longitude,
    double? elevation,
    String? locationName,
  }) {
    return PlanetariumObserver(
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      elevation: elevation ?? this.elevation,
      locationName: locationName ?? this.locationName,
    );
  }
}

class PlanetariumObserverNotifier extends StateNotifier<PlanetariumObserver> {
  PlanetariumObserverNotifier() : super(const PlanetariumObserver());

  /// Adopt a site pushed in from the app's settings.
  ///
  /// Latitude 0 with longitude 0 is the settings layer's "no site on record"
  /// value, so it clears the site instead of pinning the planetarium to the
  /// point in the Gulf of Guinea.
  void setLocation({
    double? latitude,
    double? longitude,
    double? elevation,
    String? locationName,
  }) {
    if (latitude == 0.0 && longitude == 0.0) {
      clearLocation(elevation: elevation, locationName: locationName);
      return;
    }
    state = state.copyWith(
      latitude: latitude,
      longitude: longitude,
      elevation: elevation,
      locationName: locationName,
    );
  }

  /// Drop the site: every site-derived readout goes back to unknown.
  void clearLocation({double? elevation, String? locationName}) {
    state = PlanetariumObserver(
      elevation: elevation ?? state.elevation,
      locationName: locationName ?? state.locationName,
    );
  }
}

final observerLocationProvider =
    StateNotifierProvider<PlanetariumObserverNotifier, PlanetariumObserver>((
      ref,
    ) {
      return PlanetariumObserverNotifier();
    });

/// The site's altitude floor by azimuth: the property horizon when the
/// operator set one, otherwise the minimum altitude. Rise/set times, the
/// altitude card's shading and Best Targets Tonight read it, so the
/// planetarium and the rest of the app hold a target to one floor.
///
/// Planetarium-local because `skotiq_core` owns the rule and already depends
/// on this package; the app layer pumps it across
/// (`skotiq_app/lib/startup/location_sync_service.dart`). Until then nothing
/// is held to a floor.
final planetariumAltitudeFloorProvider = StateProvider<AltitudeFloorSamples>(
  (ref) => AltitudeFloorSamples.flat(0),
);

/// Current observation time (can be simulated or real-time)
class ObservationTimeState {
  final DateTime time;
  final bool isRealTime;
  final double speedMultiplier;

  const ObservationTimeState({
    required this.time,
    this.isRealTime = true,
    this.speedMultiplier = 1.0,
  });

  /// Simulated time is being held still: neither following the wall clock nor
  /// advancing at a speed.
  ///
  /// Not the same as `!isRealTime` — the tick advances the state by
  /// [speedMultiplier] seconds whenever the wall clock is not being followed,
  /// so a "paused" state that only cleared [isRealTime] kept running at
  /// exactly 1x.
  bool get isPaused => !isRealTime && speedMultiplier == 0;

  ObservationTimeState copyWith({
    DateTime? time,
    bool? isRealTime,
    double? speedMultiplier,
  }) {
    return ObservationTimeState(
      time: time ?? this.time,
      isRealTime: isRealTime ?? this.isRealTime,
      speedMultiplier: speedMultiplier ?? this.speedMultiplier,
    );
  }
}

/// Now, for the sky: the wall clock unless the host app points it at its own
/// clock, so the sky and the app's other readouts tell the same time.
final skyNowProvider = Provider<DateTime Function()>((ref) => DateTime.now);

class ObservationTimeNotifier extends StateNotifier<ObservationTimeState> {
  AlignedTicker? _timer;
  final DateTime Function() _now;

  ObservationTimeNotifier({DateTime Function() now = DateTime.now})
    : _now = now,
      super(ObservationTimeState(time: now())) {
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    // Aligned, not free-running: an unaligned 1 Hz clock costs a whole extra
    // full-window frame per second. See [AlignedTicker].
    _timer = AlignedTicker(const Duration(seconds: 1), () {
      if (state.isRealTime) {
        state = state.copyWith(time: _now());
      } else if (state.speedMultiplier != 0) {
        final delta = Duration(seconds: state.speedMultiplier.round());
        state = state.copyWith(time: state.time.add(delta));
      }
    });
  }

  void setTime(DateTime time) {
    state = state.copyWith(time: time, isRealTime: false);
  }

  /// Hold simulated time at the current instant.
  void pause() {
    state = state.copyWith(isRealTime: false, speedMultiplier: 0);
  }

  void setRealTime(bool realTime) {
    state = state.copyWith(
      isRealTime: realTime,
      time: realTime ? _now() : state.time,
    );
  }

  void setSpeedMultiplier(double multiplier) {
    state = state.copyWith(speedMultiplier: multiplier, isRealTime: false);
  }

  void fastForward(Duration duration) {
    state = state.copyWith(time: state.time.add(duration), isRealTime: false);
  }

  void rewind(Duration duration) {
    state = state.copyWith(
      time: state.time.subtract(duration),
      isRealTime: false,
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final observationTimeProvider =
    StateNotifierProvider<ObservationTimeNotifier, ObservationTimeState>((ref) {
      return ObservationTimeNotifier(now: ref.watch(skyNowProvider));
    });
