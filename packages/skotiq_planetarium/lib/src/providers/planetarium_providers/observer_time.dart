part of '../planetarium_providers.dart';

// Location provider

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

/// The user-configured effective horizon in degrees, as observed by the
/// planetarium widgets.
///
/// 0° = mathematical horizon; a non-zero value (e.g. 20°) accounts for trees,
/// buildings or hills. Rise/transit/set times and the altitude card's shading
/// both read it, so the planetarium and the Run Dashboard quote one number.
///
/// Planetarium-local because `skotiq_core` owns the persisted setting and
/// already depends on this package for catalog access; the app layer syncs the
/// two (`skotiq_app/lib/services/location_sync_service.dart`). The name is
/// deliberately distinct from core's `effectiveHorizonDegProvider` to avoid
/// `ambiguous_import` where both umbrellas are in scope.
final planetariumEffectiveHorizonDegProvider = StateProvider<double>(
  (ref) => 0.0,
);

// Observation time provider

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

class ObservationTimeNotifier extends StateNotifier<ObservationTimeState> {
  AlignedTicker? _timer;

  ObservationTimeNotifier()
    : super(ObservationTimeState(time: DateTime.now())) {
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    // Aligned, not free-running: this is one of three 1 Hz clocks in the app,
    // and an unaligned one costs a whole extra full-window frame per second at
    // idle. See [AlignedTicker].
    _timer = AlignedTicker(const Duration(seconds: 1), () {
      if (state.isRealTime) {
        state = state.copyWith(time: DateTime.now());
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
      time: realTime ? DateTime.now() : state.time,
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
      return ObservationTimeNotifier();
    });

/// Real wall-clock instant, re-published once a second.
///
/// Deliberately NOT [observationTimeProvider]. That clock is a preview control:
/// the planetarium's transport can hold it, run it at a day per second or jump
/// it to tomorrow evening, and while it is held it stops publishing at all.
/// Anything OUTSIDE the planetarium that states a fact about *now* — the shell
/// status bar's sidereal-time chip is the one that was caught — has to read a
/// clock the transport cannot move, or it reports a fictional time next to the
/// real one with nothing marking the difference.
class WallClockNotifier extends StateNotifier<DateTime> {
  AlignedTicker? _timer;

  WallClockNotifier() : super(DateTime.now()) {
    // Aligned so this clock shares a frame with the observation clock above and
    // the shell status bar's, instead of costing a third one. See
    // [AlignedTicker].
    _timer = AlignedTicker(const Duration(seconds: 1), () {
      state = DateTime.now();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final wallClockProvider = StateNotifierProvider<WallClockNotifier, DateTime>((
  ref,
) {
  return WallClockNotifier();
});
