part of '../planetarium_providers.dart';

// Sky view state provider

class SkyViewNotifier extends StateNotifier<SkyViewState> {
  SkyViewNotifier()
    : super(const SkyViewState(centerRA: 0, centerDec: 0, fieldOfView: 60));

  /// True once anything has aimed the view — a drag, a search fly-to, the reset
  /// button, a deep link. Guards [adoptHomeCenter] so the site arriving late
  /// from the settings sync can re-home a view nobody has touched, but can
  /// never yank the camera off what the user is looking at.
  bool _userAimed = false;

  /// Point the view at [home] (the zenith, from `skyViewHomeCenterProvider`)
  /// unless the user has already aimed it.
  ///
  /// First paint adopts the same home the reset action uses. The constructor's
  /// RA 0h / Dec 0 is a fixed point on the celestial equator — overhead at one
  /// instant a year on the equator and below the horizon most of the time
  /// everywhere else.
  void adoptHomeCenter((double raHours, double decDeg) home) {
    if (_userAimed) return;
    state = state.copyWith(
      centerRA: home.$1.clamp(0, 24),
      centerDec: home.$2.clamp(-90, 90),
    );
  }

  void setCenter(double ra, double dec) {
    _userAimed = true;
    state = state.copyWith(
      centerRA: ra.clamp(0, 24),
      centerDec: dec.clamp(-90, 90),
    );
  }

  void setFieldOfView(double fov) {
    state = state.copyWith(fieldOfView: fov.clamp(1, 180));
  }

  void setRotation(double rotation) {
    state = state.copyWith(rotation: rotation % 360);
  }

  void setProjection(SkyProjection projection) {
    state = state.copyWith(projection: projection);
  }

  /// Switch between the equatorial (RA/Dec) and horizontal (alt/az) view
  /// frames, carrying the aimed patch of sky across. No-op if already in
  /// [mode].
  ///
  /// Changing frame is a change of GRID, not of target. The two frames keep
  /// independent centers, so flipping [SkyViewState.viewMode] alone would drop
  /// the chart onto whatever pose the inactive frame was left holding.
  ///
  /// [observer] and [instant] are the site and time the conversion is made at,
  /// and are required so no call site can flip the frame without them. A center
  /// below the horizon converts faithfully to a negative altitude rather than
  /// being clamped up — the user really was aimed at the ground.
  void setViewMode(
    SkyViewMode mode, {
    required PlanetariumObserver observer,
    required DateTime instant,
  }) {
    if (state.viewMode == mode) return;
    // The horizontal frame is defined by the observer's horizon, so the frames
    // cannot be converted between until a site is on record.
    final site = observer.site;
    if (site == null) return;
    // The raw transform, not [AstronomyCalculations.objectAltAz]: the renderer
    // projects catalog J2000 positions with this same unprecessed transform, so
    // this is the camera's frame. Precessing here would slide the view ~22
    // arcmin off the stars it draws.
    final lst = AstronomyCalculations.localSiderealTime(
      instant,
      site.longitude,
    );

    if (mode == SkyViewMode.horizontal) {
      final (alt, az) = AstronomyCalculations.equatorialToHorizontal(
        raDeg: state.centerRA * 15,
        decDeg: state.centerDec,
        latitudeDeg: site.latitude,
        lstHours: lst,
      );
      state = state.copyWith(
        viewMode: mode,
        centerAz: az,
        centerAltitude: alt.clamp(-90, 90),
      );
      return;
    }

    final (raDeg, dec) = AstronomyCalculations.horizontalToEquatorial(
      altDeg: state.centerAltitude,
      azDeg: state.centerAz,
      latitudeDeg: site.latitude,
      lstHours: lst,
    );
    state = state.copyWith(
      viewMode: mode,
      centerRA: (raDeg / 15).clamp(0, 24),
      centerDec: dec.clamp(-90, 90),
    );
  }

  /// Set the horizontal-frame view center (alt/az, degrees). Altitude is clamped
  /// to the visible hemisphere band and azimuth wraps to [0, 360).
  void setHorizontalCenter(double azimuth, double altitude) {
    _userAimed = true;
    var az = azimuth % 360;
    if (az < 0) az += 360;
    state = state.copyWith(
      centerAz: az,
      centerAltitude: altitude.clamp(-90, 90),
    );
  }

  void zoomIn({Offset? mousePosition, Size? viewSize}) {
    if (mousePosition != null && viewSize != null) {
      _zoomAtPosition(mousePosition, viewSize, 1.5);
    } else {
      state = state.copyWith(
        fieldOfView: (state.fieldOfView / 1.5).clamp(1, 180),
      );
    }
  }

  void zoomOut({Offset? mousePosition, Size? viewSize}) {
    if (mousePosition != null && viewSize != null) {
      _zoomAtPosition(mousePosition, viewSize, 1 / 1.5);
    } else {
      state = state.copyWith(
        fieldOfView: (state.fieldOfView * 1.5).clamp(1, 180),
      );
    }
  }

  /// Zoom at a specific screen position, keeping that position fixed
  void _zoomAtPosition(Offset mousePosition, Size viewSize, double zoomFactor) {
    // The cursor-anchored math inverts the equatorial STEREOGRAPHIC projection
    // self-contained (no time/location needed). Two cases fall back to a plain
    // center zoom — correct, just not cursor-anchored:
    //  * the horizontal frame, whose inverse needs sidereal time this notifier
    //    does not hold;
    //  * the orthographic and azimuthal-equidistant projections, whose inverses
    //    differ from the stereographic one. Anchoring them with the wrong
    //    inverse slid the sky out from under the cursor as it zoomed.
    if (state.viewMode == SkyViewMode.horizontal ||
        state.projection != SkyProjection.stereographic) {
      state = state.copyWith(
        fieldOfView: (state.fieldOfView / zoomFactor).clamp(1, 180),
      );
      return;
    }

    // Get the celestial coordinate at the mouse position before zoom
    final coordBefore = _screenToCelestial(mousePosition, viewSize);
    if (coordBefore == null) {
      // Fallback to center zoom if conversion fails
      state = state.copyWith(
        fieldOfView: (state.fieldOfView / zoomFactor).clamp(1, 180),
      );
      return;
    }

    // Apply zoom
    final oldFOV = state.fieldOfView;
    final newFOV = (oldFOV / zoomFactor).clamp(1.0, 180.0);
    state = state.copyWith(fieldOfView: newFOV);

    // Get the celestial coordinate at the same screen position after zoom
    final coordAfter = _screenToCelestial(mousePosition, viewSize);
    if (coordAfter == null) return;

    // Calculate the offset needed to keep the mouse position pointing at the same celestial coordinate
    final dRA = coordBefore.ra - coordAfter.ra;
    final dDec = coordBefore.dec - coordAfter.dec;

    // Adjust center to compensate. Cursor-anchored zoom moves the centre, so it
    // counts as aiming the view.
    _userAimed = true;
    var newRA = state.centerRA + dRA;
    if (newRA < 0) newRA += 24;
    if (newRA >= 24) newRA -= 24;

    state = state.copyWith(
      centerRA: newRA,
      centerDec: (state.centerDec + dDec).clamp(-90, 90),
    );
  }

  /// Convert screen position to celestial coordinates
  CelestialCoordinate? _screenToCelestial(Offset position, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final scale =
        math.min(size.width, size.height) / 2 / (state.fieldOfView / 2);

    // Offset from center in screen pixels
    final dx = -(position.dx - center.dx) / scale;
    final dy = -(position.dy - center.dy) / scale;

    // Reverse rotation
    final rotRad = -state.rotation * math.pi / 180;
    final x = dx * math.cos(rotRad) - dy * math.sin(rotRad);
    final y = dx * math.sin(rotRad) + dy * math.cos(rotRad);

    // Convert to RA/Dec (inverse of stereographic projection)
    final centerRaDeg = state.centerRA * 15;
    final centerDecDeg = state.centerDec;

    final xRad = x * math.pi / 180;
    final yRad = y * math.pi / 180;
    final centerRaRad = centerRaDeg * math.pi / 180;
    final centerDecRad = centerDecDeg * math.pi / 180;

    final rho = math.sqrt(xRad * xRad + yRad * yRad);
    if (rho < 0.0001) {
      return CelestialCoordinate(ra: state.centerRA, dec: state.centerDec);
    }

    final c = 2 * math.atan(rho / 2);
    final sinc = math.sin(c);
    final cosc = math.cos(c);

    final dec = math.asin(
      cosc * math.sin(centerDecRad) +
          yRad * sinc * math.cos(centerDecRad) / rho,
    );
    final ra =
        centerRaRad +
        math.atan2(
          xRad * sinc,
          rho * math.cos(centerDecRad) * cosc -
              yRad * math.sin(centerDecRad) * sinc,
        );

    var raHours = (ra * 180 / math.pi / 15).toDouble();
    if (raHours < 0) raHours += 24;
    if (raHours >= 24) raHours -= 24;

    final decDeg = (dec * 180 / math.pi).toDouble();

    return CelestialCoordinate(ra: raHours, dec: decDeg.clamp(-90, 90));
  }

  /// Pan the view center. In the equatorial frame [dLon] is an RA delta in
  /// hours and [dLat] a Dec delta in degrees. In the horizontal frame [dLon] is
  /// an azimuth delta expressed in the same hour-scaled units the drag handler
  /// produces (so it is multiplied back to degrees here) and [dLat] an altitude
  /// delta in degrees. Routing both frames through one method keeps the gesture
  /// handlers frame-agnostic.
  void pan(double dLon, double dLat) {
    _userAimed = true;
    if (state.viewMode == SkyViewMode.horizontal) {
      var newAz = state.centerAz + dLon * 15;
      newAz = newAz % 360;
      if (newAz < 0) newAz += 360;
      state = state.copyWith(
        centerAz: newAz,
        centerAltitude: (state.centerAltitude + dLat).clamp(-90, 90),
      );
      return;
    }

    var newRA = state.centerRA + dLon;
    if (newRA < 0) newRA += 24;
    if (newRA >= 24) newRA -= 24;

    state = state.copyWith(
      centerRA: newRA,
      centerDec: (state.centerDec + dLat).clamp(-90, 90),
    );
  }

  void lookAt(CelestialCoordinate coord) {
    _userAimed = true;
    state = state.copyWith(centerRA: coord.ra, centerDec: coord.dec);
  }
}

final skyViewStateProvider =
    StateNotifierProvider<SkyViewNotifier, SkyViewState>((ref) {
      final notifier = SkyViewNotifier();
      // First paint opens on the zenith, the same home the reset action uses.
      //
      // Homed from the wall clock rather than from [skyViewHomeCenterProvider]
      // deliberately: that provider watches the 1 Hz observation clock, and
      // reaching it from here would make merely READING the view pose start
      // that clock's periodic timer. "Now" is the right instant anyway — at
      // first build nothing has time-travelled yet, and the reset control (which
      // does watch the observation clock) covers the time-travelled case.
      final home = skyViewHomeCenterAt(
        ref.read(observerLocationProvider),
        DateTime.now(),
      );
      if (home != null) notifier.adoptHomeCenter(home);
      // The observing site is pushed in from the app's settings sync, which can
      // land after this notifier is built — until it does there is no zenith to
      // home on. Watching the site (not the home provider, which re-derives
      // every minute) keeps an untouched view still rather than slowly tracking
      // the zenith.
      ref.listen<PlanetariumObserver>(observerLocationProvider, (_, observer) {
        final center = skyViewHomeCenterAt(observer, DateTime.now());
        if (center != null) notifier.adoptHomeCenter(center);
      });
      return notifier;
    });

/// A request to smoothly animate the view center to a target coordinate.
///
/// The [token] is monotonically increasing so that requesting a fly-to to the
/// same coordinate twice still notifies listeners (a plain coordinate-equality
/// check would swallow the second request).
class FlyToRequest {
  final CelestialCoordinate target;
  final int token;

  const FlyToRequest({required this.target, required this.token});
}

/// Drives smooth "fly-to" view-center animations from search/GoTo actions.
///
/// The center animation itself lives in [InteractiveSkyView] (it owns the
/// vsync/ticker); this notifier is just the request channel. Callers use
/// [flyTo] to ask the view to glide to a coordinate, and the active sky view
/// reacts by tweening its center there.
class FlyToNotifier extends StateNotifier<FlyToRequest?> {
  FlyToNotifier() : super(null);

  int _token = 0;

  /// Request a smooth animated re-center on [target].
  void flyTo(CelestialCoordinate target) {
    state = FlyToRequest(target: target, token: ++_token);
  }
}

final flyToRequestProvider =
    StateNotifierProvider<FlyToNotifier, FlyToRequest?>((ref) {
      return FlyToNotifier();
    });

/// Current view center in horizontal coordinates, as (azimuth, altitude) in
/// degrees, or null when no site is on record and the equatorial center cannot
/// be placed against a horizon.
///
/// Uses minute precision to avoid excessive rebuilds from per-second time updates.
final viewCenterAltAzProvider = Provider<(double, double)?>((ref) {
  final viewState = ref.watch(skyViewStateProvider);
  final time = ref.watch(
    _currentMinuteProvider,
  ); // Use minute precision instead

  // In the horizontal frame the center is already alt/az.
  if (viewState.viewMode == SkyViewMode.horizontal) {
    return (viewState.centerAz, viewState.centerAltitude);
  }

  final site = ref.watch(observerLocationProvider).site;
  if (site == null) return null;

  // Convert view center (RA/Dec) to Alt/Az
  final lst = AstronomyCalculations.localSiderealTime(time, site.longitude);

  final (alt, az) = AstronomyCalculations.equatorialToHorizontal(
    raDeg: viewState.centerRA * 15, // Convert hours to degrees
    decDeg: viewState.centerDec,
    latitudeDeg: site.latitude,
    lstHours: lst,
  );

  return (az, alt);
});

/// Aspect ratio (width / height) of the sky view's canvas.
///
/// The catalogue queries take a SHORT-AXIS field of view, so without this they
/// fetch a square region regardless of window shape. On a 3.6:1 ultrawide that
/// left the outer ~58% of the screen width with no star data at all, and stars
/// popped in and out at the region boundary while panning. Published by
/// [InteractiveSkyView] from its own LayoutBuilder; 1.0 until first layout.
final skyViewAspectRatioProvider = StateProvider<double>((ref) => 1.0);

/// Where the Home / reset-view control should point: the observer's zenith, as
/// (raHours, decDegrees).
///
/// The zenith is above the horizon by definition, which a fixed point such as
/// RA 0h / Dec 0 is not.
///
/// Minute precision, matching the rest of the sky clock. Null with no site on
/// record: the zenith is the point over the observer, and there is no observer.
final skyViewHomeCenterProvider = Provider<(double raHours, double decDeg)?>((
  ref,
) {
  return skyViewHomeCenterAt(
    ref.watch(observerLocationProvider),
    ref.watch(_currentMinuteProvider),
  );
});

/// The zenith over [observer] at [time], as (raHours, decDegrees), or null when
/// [observer] has no site on record.
///
/// Separate from [skyViewHomeCenterProvider] so the sky-view notifier can home
/// itself from a site it has just been handed. Reading the provider from inside
/// a listener on `observerLocationProvider` returns the value cached for the
/// PREVIOUS site — dependents have not been refreshed yet at that point — which
/// homes the view to the zenith of the old longitude.
(double raHours, double decDeg)? skyViewHomeCenterAt(
  PlanetariumObserver observer,
  DateTime time,
) {
  final site = observer.site;
  if (site == null) return null;
  final lst = AstronomyCalculations.localSiderealTime(time, site.longitude);
  var ra = lst % 24;
  if (ra < 0) ra += 24;
  // The pole itself is a projection singularity, so stop just short of it.
  return (ra, site.latitude.clamp(-89.5, 89.5));
}

/// The view center expressed in equatorial coordinates, whichever frame the
/// view is actually in. Returns (raHours, decDegrees).
///
/// Catalog lookups are indexed by RA/Dec, so every "what is in view" query must
/// go through this rather than reading [SkyViewState.centerRA] / `centerDec`
/// directly: in [SkyViewMode.horizontal] those two fields are the *preserved
/// inactive* equatorial pose, not where the user is looking, and querying them
/// there fetches an unrelated patch of sky.
///
/// Minute precision (via [_currentMinuteProvider]) keeps the sky from
/// re-querying on every clock tick; a minute of rotation is ~0.25 deg, far
/// inside the query's margin.
final viewCenterEquatorialProvider = Provider<(double, double)>((ref) {
  final viewState = ref.watch(skyViewStateProvider);
  if (viewState.viewMode == SkyViewMode.equatorial) {
    return (viewState.centerRA, viewState.centerDec);
  }

  final site = ref.watch(observerLocationProvider).site;
  // The horizontal pose cannot be inverted without a site. The preserved
  // equatorial pose is then the only coordinate the view actually holds, and
  // the frame cannot have been switched to horizontal without a site anyway.
  if (site == null) return (viewState.centerRA, viewState.centerDec);

  final time = ref.watch(_currentMinuteProvider);
  final lst = AstronomyCalculations.localSiderealTime(time, site.longitude);

  final (raDeg, decDeg) = AstronomyCalculations.horizontalToEquatorial(
    altDeg: viewState.centerAltitude,
    azDeg: viewState.centerAz,
    latitudeDeg: site.latitude,
    lstHours: lst,
  );
  return (raDeg / 15.0, decDeg);
});
