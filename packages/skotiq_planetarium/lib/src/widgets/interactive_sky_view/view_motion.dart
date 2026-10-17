part of '../interactive_sky_view.dart';

/// Speed below which momentum is finished and the ticker stops, as a
/// FRACTION OF THE VIEW'S SHORT SIDE per second.
///
/// Expressed relatively because a fling's meaning is "how much of the sky did
/// you throw", not "how many pixels did your finger cover": the same physical
/// gesture covers 4x the pixels on a 5120-wide window as on a 1280-wide one.
/// As a fixed px/s threshold this made flings refuse to glide on a large
/// display and over-glide on a small one. Converted to px/s against the live
/// canvas by [_momentumSpeedPx].
const double _momentumStopFraction = 0.011;

/// Exponential velocity decay per second. At 4.0 the speed falls to ~1.8% of
/// its initial value after one second — a natural, quick-settling glide.
///
/// Unitless, so unlike the speed thresholds this is already resolution
/// independent and deliberately stays a plain constant.
const double _momentumDecayPerSecond = 4.0;

/// Minimum fling speed required to start a glide, as a fraction of the view's
/// short side per second (see [_momentumStopFraction]).
const double _momentumMinLaunchFraction = 0.17;

extension _SkyViewMotion on _InteractiveSkyViewState {
  /// Convert a view-relative speed [fraction] (short-sides per second) into the
  /// px/s the gesture velocities are measured in.
  double _momentumSpeedPx(double fraction) {
    final size = _lastViewSize;
    final shortSide = size == null
        ? 720.0 // pre-layout fallback; the reference these were tuned at
        : math.min(size.width, size.height);
    return fraction * shortSide;
  }

  /// Translate a screen-pixel drag into a view-center move.
  ///
  /// The painter's scale is `min(w, h) / fov` pixels per degree
  /// (see `SkyCanvasPainter._paint`), so degrees-per-pixel is its reciprocal.
  /// Any other constant makes the sky move at the wrong speed on every canvas
  /// whose short side differs from it, and it stops tracking the pointer.
  ///
  /// The horizontal component is additionally divided by the cosine of the
  /// center's latitude (declination, or altitude in the horizontal frame),
  /// because a degree of longitude subtends `cos(lat)` degrees on the sky.
  /// Without it a horizontal drag crawls near the poles and does nothing at all
  /// at the alt/az zenith, which is where the horizontal frame opens.
  void _panByPixels(Offset deltaPixels, Size size) {
    final viewState = ref.read(skyViewStateProvider);
    final shortSide = math.min(size.width, size.height);
    if (shortSide <= 0) return;
    final degreesPerPixel = viewState.fieldOfView / shortSide;

    final centerLatDeg = viewState.viewMode == SkyViewMode.horizontal
        ? viewState.centerAltitude
        : viewState.centerDec;
    // Clamped so the pole is a fast pivot rather than a division by zero.
    final cosLat = math
        .cos(centerLatDeg * math.pi / 180)
        .abs()
        .clamp(0.05, 1.0);

    ref
        .read(skyViewStateProvider.notifier)
        .pan(
          -deltaPixels.dx * degreesPerPixel / cosLat / 15, // degrees -> hours
          deltaPixels.dy * degreesPerPixel,
        );
  }

  void _onZoomAnimation() {
    if (_zoomAnimation != null) {
      final newFOV = _zoomAnimation!.value;
      ref.read(skyViewStateProvider.notifier).setFieldOfView(newFOV);
      // Re-pin the anchor at the FOV this frame actually landed on, so the sky
      // under the cursor is stationary throughout the 300 ms glide rather than
      // only at its end.
      _holdZoomAnchor();

      // Trigger star pop-in animation when zooming reveals fainter stars
      final qualityConfig = ref.read(fovAdaptiveQualityProvider);
      if (qualityConfig.enableStarPopin) {
        // Estimate new magnitude limit based on FOV
        // Wider FOV = lower mag limit, narrower FOV = higher mag limit
        final newMagLimit = 6.0 + (60.0 - newFOV).clamp(0.0, 54.0) / 6.0;
        if (newMagLimit > _previousMagLimit + 0.5) {
          // Zooming in revealed fainter stars - trigger pop-in
          _popinController.forward(from: 0.0);
        }
        _previousMagLimit = newMagLimit;
      }

      // Trigger DSO pop-in animation when zooming reveals fainter DSOs
      if (qualityConfig.enableDsoPopin) {
        // DSOs have a different magnitude range, typically visible to mag ~14
        // Estimate new DSO mag limit based on FOV
        final newDsoMagLimit = 10.0 + (60.0 - newFOV).clamp(0.0, 54.0) / 12.0;
        if (newDsoMagLimit > _previousDsoMagLimit + 0.3) {
          // Zooming in revealed fainter DSOs - trigger pop-in
          _dsoPopinController.forward(from: 0.0);
        }
        _previousDsoMagLimit = newDsoMagLimit;
      }
    }
  }

  /// Per-frame momentum integration.
  ///
  /// [elapsed] is the total time the ticker has run. We derive the real frame
  /// dt from it, translate the view by `velocity * dt` (same px→RA/Dec
  /// conversion the live drag uses), then exponentially decay the velocity by
  /// `dt`. Integrating against the true dt makes the glide frame-rate
  /// independent and smooth; decaying continuously (rather than ramping over a
  /// fixed timeline) removes the abrupt end-of-animation stop.
  void _onMomentumTick(Duration elapsed) {
    if (!mounted) {
      _momentumTicker.stop();
      return;
    }

    final dtMicros =
        elapsed.inMicroseconds - _lastMomentumElapsed.inMicroseconds;
    _lastMomentumElapsed = elapsed;
    if (dtMicros <= 0) return;
    final dt = dtMicros / 1e6;

    final size = _lastViewSize;
    if (size == null) {
      _stopMomentum();
      return;
    }

    // Pixel translation this frame from the current velocity (px/s).
    _panByPixels(_panVelocity * dt, size);

    // Exponential decay: v *= e^(-decay * dt).
    final decay = math.exp(-_momentumDecayPerSecond * dt);
    _panVelocity = _panVelocity * decay;

    if (_panVelocity.distance < _momentumSpeedPx(_momentumStopFraction)) {
      _stopMomentum();
    }
  }

  /// Stop and reset the momentum glide.
  void _stopMomentum() {
    if (_momentumTicker.isActive) {
      _momentumTicker.stop();
    }
    _panVelocity = Offset.zero;
    _lastMomentumElapsed = Duration.zero;
  }

  /// Calculate pan velocity from recent samples
  Offset _calculatePanVelocity() {
    if (_panSamples.length < 2) return Offset.zero;

    // Use last few samples for velocity calculation
    final recent = _panSamples.length > 5
        ? _panSamples.sublist(_panSamples.length - 5)
        : _panSamples;

    if (recent.length < 2) return Offset.zero;

    // Calculate average velocity from recent samples
    var totalVelocity = Offset.zero;
    for (var i = 1; i < recent.length; i++) {
      final dt = recent[i].time
          .difference(recent[i - 1].time)
          .inMilliseconds
          .toDouble();
      if (dt > 0) {
        final delta = recent[i].position - recent[i - 1].position;
        totalVelocity += delta / dt * 1000; // pixels per second
      }
    }

    return totalVelocity / (recent.length - 1).toDouble();
  }

  /// Field of view the view is *heading for*: the in-flight zoom target while
  /// the 300 ms glide is running, otherwise the live value.
  ///
  /// Relative zoom steps must compound onto this, never onto the live FOV. The
  /// glide only covers a fraction of the distance in the ~50 ms between two
  /// wheel notches, so basing the next notch on the live (barely-moved) value
  /// silently discarded every notch that arrived mid-glide — measured live, 20
  /// fast notches moved the FOV by exactly one notch and it took 172 notches to
  /// get from 60 deg to 29 deg.
  double get _pendingFOV => _zoomController.isAnimating
      ? _targetFOV
      : ref.read(skyViewStateProvider).fieldOfView;

  /// Compound one relative zoom step onto the pending target.
  ///
  /// [factor] > 1 zooms out (widens the field), < 1 zooms in. The step size is
  /// picked from the pending FOV too, so a burst of notches crossing the
  /// coarse/fine boundary steps the same way it would one notch at a time.
  /// [focalPoint] is the local screen position the zoom must keep pointing at
  /// the same sky — the mouse cursor for a wheel notch. Null zooms the view
  /// centre, which is what a keyboard or programmatic zoom means.
  void _zoomByStep({required bool zoomOut, Offset? focalPoint}) {
    _setZoomAnchor(focalPoint);
    final baseFOV = _pendingFOV;
    final zoomFactor = baseFOV > 30 ? 1.2 : 1.15;
    _animateZoom(zoomOut ? baseFOV * zoomFactor : baseFOV / zoomFactor);
  }

  /// Remember which sky point sits under [point] right now, so the zoom can
  /// keep it there. A null [point] — or a point that does not resolve to sky
  /// (outside the projection disc) — drops the anchor and zooms the centre.
  void _setZoomAnchor(Offset? point) {
    final size = _lastViewSize;
    if (point == null || size == null) {
      _clearZoomAnchor();
      return;
    }
    final anchor = _screenToCelestial(
      point,
      size,
      ref.read(skyViewStateProvider),
    );
    if (anchor == null) {
      _clearZoomAnchor();
      return;
    }
    _zoomAnchorSky = anchor;
    _zoomAnchorPoint = point;
  }

  void _clearZoomAnchor() {
    _zoomAnchorSky = null;
    _zoomAnchorPoint = null;
  }

  /// The projector for a given pose, built exactly as the hit-tester and the
  /// painter build theirs.
  SkyFovProjector? _projectorFor(SkyViewState state, Size size) {
    final site = ref.read(observerLocationProvider).site;
    if (site == null) return null;
    return SkyFovProjector.forSize(
      state,
      size,
      latitude: site.latitude,
      lstHours: state.viewMode == SkyViewMode.horizontal
          ? AstronomyCalculations.localSiderealTime(
              ref.read(observationTimeProvider).time,
              site.longitude,
            )
          : null,
    );
  }

  /// Move the view centre so the anchored sky point is back under the anchored
  /// screen point at the CURRENT field of view.
  ///
  /// Solved by iteration rather than by inverting the projection: shifting the
  /// image by `err` pixels means re-centring on whatever sky currently lies
  /// `err` from the centre, which is exact for a translation and converges in
  /// two or three passes for the spherical projections the view actually uses.
  void _holdZoomAnchor() {
    final anchor = _zoomAnchorSky;
    final point = _zoomAnchorPoint;
    final size = _lastViewSize;
    if (anchor == null || point == null || size == null) return;

    final notifier = ref.read(skyViewStateProvider.notifier);
    for (var pass = 0; pass < 4; pass++) {
      final state = ref.read(skyViewStateProvider);
      final projector = _projectorFor(state, size);
      if (projector == null) {
        _clearZoomAnchor();
        return;
      }
      final landed = projector.project(anchor);
      if (landed == null) {
        // The anchor rotated behind the projection plane — nothing to hold on
        // to, and forcing it back would fling the view.
        _clearZoomAnchor();
        return;
      }
      final err = point - landed;
      if (err.distance < 0.25) return;
      final recentred = projector.unproject(projector.screenCenter - err);
      if (recentred == null) return;
      if (state.viewMode == SkyViewMode.horizontal) {
        final site = ref.read(observerLocationProvider).site;
        if (site == null) return;
        final (alt, az) = AstronomyCalculations.equatorialToHorizontal(
          raDeg: recentred.ra * 15,
          decDeg: recentred.dec,
          latitudeDeg: site.latitude,
          lstHours: AstronomyCalculations.localSiderealTime(
            ref.read(observationTimeProvider).time,
            site.longitude,
          ),
        );
        notifier.setHorizontalCenter(az, alt);
      } else {
        notifier.setCenter(recentred.ra, recentred.dec);
      }
    }
  }

  /// Animate FOV to a new target value
  void _animateZoom(double newFOV) {
    // The tween BEGINS at the live FOV so the glide stays visually continuous
    // when a new step lands mid-animation; only the END accumulates.
    final currentFOV = ref.read(skyViewStateProvider).fieldOfView;
    _startFOV = currentFOV;
    _targetFOV = newFOV.clamp(1.0, 180.0);

    _zoomAnimation = Tween<double>(begin: _startFOV, end: _targetFOV).animate(
      CurvedAnimation(parent: _zoomController, curve: Curves.easeOutCubic),
    );

    _zoomController.forward(from: 0.0);
  }

  void _onFlyToAnimation() {
    final raAnim = _flyToRaAnimation;
    final decAnim = _flyToDecAnimation;
    if (raAnim == null || decAnim == null) return;

    // RA is animated in an unwrapped (possibly out-of-[0,24)) space so the
    // glide takes the shortest path across the 0h/24h seam; setCenter wraps it
    // back into range.
    var ra = raAnim.value % 24;
    if (ra < 0) ra += 24;
    ref.read(skyViewStateProvider.notifier).setCenter(ra, decAnim.value);
  }

  /// Smoothly animate the view center to [target] (used by search/GoTo).
  ///
  /// Equatorial frame glides via the RA/Dec tween below. The horizontal frame's
  /// center is alt/az, so there the target RA/Dec is converted to the local
  /// alt/az for "now" and the view jumps to it instantly (the horizontal center
  /// is not on the animated path, so an instant re-center is the honest result
  /// rather than a no-op).
  void _startFlyTo(CelestialCoordinate target) {
    // A glide to somewhere else owns the centre; a stale wheel anchor would
    // fight it frame by frame.
    _clearZoomAnchor();
    final viewState = ref.read(skyViewStateProvider);
    if (viewState.viewMode == SkyViewMode.horizontal) {
      final site = ref.read(observerLocationProvider).site;
      if (site == null) return;
      final time = ref.read(observationTimeProvider).time;
      final lst = AstronomyCalculations.localSiderealTime(time, site.longitude);
      final (alt, az) = AstronomyCalculations.equatorialToHorizontal(
        raDeg: target.ra * 15,
        decDeg: target.dec,
        latitudeDeg: site.latitude,
        lstHours: lst,
      );
      ref.read(skyViewStateProvider.notifier).setHorizontalCenter(az, alt);
      return;
    }

    final startRa = viewState.centerRA;
    final startDec = viewState.centerDec;

    // Choose the shortest RA direction across the 0h/24h wraparound.
    var deltaRa = target.ra - startRa;
    if (deltaRa > 12) deltaRa -= 24;
    if (deltaRa < -12) deltaRa += 24;
    final endRa = startRa + deltaRa;

    final curve = CurvedAnimation(
      parent: _flyToController,
      curve: Curves.easeInOutCubic,
    );
    _flyToRaAnimation = Tween<double>(
      begin: startRa,
      end: endRa,
    ).animate(curve);
    _flyToDecAnimation = Tween<double>(
      begin: startDec,
      end: target.dec,
    ).animate(curve);

    _flyToController.forward(from: 0.0);
  }

  /// Map provider mount status to renderer mount status
  MountRenderStatus _mapMountStatus(MountTrackingStatus status) {
    return switch (status) {
      MountTrackingStatus.disconnected => MountRenderStatus.disconnected,
      MountTrackingStatus.parked => MountRenderStatus.parked,
      MountTrackingStatus.slewing => MountRenderStatus.slewing,
      MountTrackingStatus.tracking => MountRenderStatus.tracking,
      MountTrackingStatus.stopped => MountRenderStatus.stopped,
    };
  }
}
