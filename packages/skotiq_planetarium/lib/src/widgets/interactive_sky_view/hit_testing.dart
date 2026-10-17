part of '../interactive_sky_view.dart';

/// Pixels within which two catalogue rows are drawn as ONE star.
///
/// Below the pointer's own addressable resolution: at this separation no user
/// can aim at one row rather than the other, and the renderer has already
/// drawn a single glyph with a single label.
const double _coincidentStarPixels = 2.0;

extension _SkyViewHitTesting on _InteractiveSkyViewState {
  /// Handle double-tap: reset the view to the default 60 degree field of view.
  void _handleDoubleTapZoom(Offset position, Size size) {
    final viewState = ref.read(skyViewStateProvider);

    // Convert tap position to celestial coordinates
    final coord = _screenToCelestial(position, size, viewState);
    if (coord == null) return;

    // Re-center the view on the tapped coordinate
    ref.read(skyViewStateProvider.notifier).setCenter(coord.ra, coord.dec);

    // This gesture re-centres deliberately; a wheel anchor left over from an
    // earlier notch would drag the centre straight back.
    _clearZoomAnchor();
    _animateZoom(60.0);
  }

  void _handleTap(Offset position, Size size) {
    final viewState = ref.read(skyViewStateProvider);

    // Convert screen position to celestial coordinates
    final coord = _screenToCelestial(position, size, viewState);
    if (coord == null) return;

    // Notify coordinate tap
    widget.onCoordinateTapped?.call(coord);

    // Try to find a nearby object using FOV-filtered objects (same as rendering)
    final stars = ref.read(combinedStarsProvider).valueOrNull ?? [];
    final dsos = ref.read(fovFilteredDsosProvider).valueOrNull ?? [];

    CelestialObject? nearestObject;
    double nearestDistance = double.infinity;

    // Minimum hit radius in screen pixels - ensures all objects are tappable
    const double minHitRadiusPixels = 8.0;

    // Calculate scale factor for converting degrees to screen pixels
    final scale =
        math.min(size.width, size.height) / 2 / (viewState.fieldOfView / 2);

    // Convert min hit radius from pixels to degrees for angular comparison
    final minHitRadiusDegrees = minHitRadiusPixels / scale;

    Star? nearestStar;
    for (final star in stars) {
      final distance = coord.separationDegrees(star.coordinates);

      // Calculate hit radius based on magnitude
      // Brighter stars (lower magnitude) get larger hit targets
      final starMag = star.magnitude ?? 6.0;

      // Base radius scales with brightness: mag -1 = 3x, mag 0 = 2.5x, mag 2 = 2x, mag 6 = 1x
      final brightnessMultiplier = math.max(1.0, 2.5 - (starMag / 4.0));
      final hitRadiusDegrees = math.max(
        minHitRadiusDegrees,
        minHitRadiusDegrees * brightnessMultiplier,
      );

      if (distance < hitRadiusDegrees && distance < nearestDistance) {
        nearestDistance = distance;
        nearestStar = star;
      }
    }
    if (nearestStar != null) {
      nearestObject = _resolveCoincidentStar(nearestStar, stars, scale);
    }

    for (final dso in dsos) {
      final distance = coord.separationDegrees(dso.coordinates);

      // DSOs get hitbox based on their actual angular size
      final dsoSizeDeg = (dso.sizeArcMin ?? 5.0) / 60.0;

      // Brighter DSOs (lower magnitude) get larger hit targets
      final dsoMag = dso.magnitude ?? 10.0;
      final brightnessMultiplier = math.max(1.0, 2.0 - (dsoMag / 10.0));

      // Use at least minHitRadius, or half the object's angular size (whichever is larger)
      // Then apply brightness multiplier
      final baseRadius = math.max(minHitRadiusDegrees, dsoSizeDeg * 0.5);
      final hitRadiusDegrees = baseRadius * brightnessMultiplier;

      if (distance < hitRadiusDegrees && distance < nearestDistance) {
        nearestDistance = distance;
        nearestObject = dso;
      }
    }

    // Hit-test satellites: check if the tap landed near a rendered satellite
    final satellites = ref.read(currentSatellitesProvider);
    // Satellites are rendered as small dots (radius ~2.5-4px), use generous hit area
    const double satelliteHitRadiusPixels = 12.0;
    final satelliteHitRadiusDegrees = satelliteHitRadiusPixels / scale;

    for (final sat in satellites) {
      final satCoord = CelestialCoordinate(ra: sat.ra, dec: sat.dec);
      final distance = coord.separationDegrees(satCoord);

      if (distance < satelliteHitRadiusDegrees && distance < nearestDistance) {
        nearestDistance = distance;
        // Carried as a SolarSystemBody: it renders and hit-tests like the point
        // sources Star covers, but the popup and the observation log need to be
        // able to say what it actually is.
        nearestObject = SolarSystemBody(
          id: 'SAT_${sat.catalogNumber}',
          name: sat.name,
          coordinates: satCoord,
          kind: SolarSystemBodyKind.satellite,
          magnitude: null, // Satellites don't have a fixed magnitude
        );
      }
    }

    // Hit-test planets: check if the tap landed near a rendered planet
    final planets = ref.read(planetPositionsProvider);
    const double planetHitRadiusPixels = 14.0;
    final planetHitRadiusDegrees = planetHitRadiusPixels / scale;

    for (final planet in planets) {
      final planetCoord = CelestialCoordinate(ra: planet.ra, dec: planet.dec);
      final distance = coord.separationDegrees(planetCoord);

      if (distance < planetHitRadiusDegrees && distance < nearestDistance) {
        nearestDistance = distance;
        nearestObject = SolarSystemBody(
          id: 'PLANET_${planet.name}',
          name: planet.name,
          coordinates: planetCoord,
          kind: SolarSystemBodyKind.planet,
          magnitude: planet.magnitude,
        );
      }
    }

    if (nearestObject != null) {
      ref.read(selectedObjectProvider.notifier).selectObject(nearestObject);
      widget.onObjectSelected?.call(nearestObject);
    } else {
      ref.read(selectedObjectProvider.notifier).selectCoordinates(coord);
      widget.onObjectSelected?.call(null);
    }

    // Always call the position callback for popup handling. A hit object
    // reports its OWN catalog coordinate, never the tap coordinate: the tap is
    // a screen-space guess that lands anywhere inside the glyph's hit radius,
    // and this coordinate is what the popup shows and what Slew / Framing /
    // Sequencer act on.
    widget.onObjectTapped?.call(
      nearestObject,
      nearestObject?.coordinates ?? coord,
      position,
    );
  }

  /// Resolve a star hit that landed on a cluster of coincident catalogue rows
  /// to the one the chart actually labelled — the brightest.
  ///
  /// HYG lists the components of a multiple star as separate rows. Capella's
  /// Aa (mag 0.08, named "Capella") and Ab (mag 0.96, no name, no HIP) sit
  /// 9 arcsec apart, which at any field wider than a fraction of a degree is
  /// well under one pixel. Taking the strictly nearest row therefore made the
  /// pick a coin flip: clicking the star the chart labels "Capella" opened a
  /// panel headed "HYG118360" reporting magnitude 1.0, contradicting both the
  /// label and the glyph size drawn from mag 0.08.
  CelestialObject _resolveCoincidentStar(
    Star nearest,
    List<Star> stars,
    double scale,
  ) {
    final mergeDegrees = _coincidentStarPixels / scale;
    var best = nearest;
    var bestMag = nearest.magnitude ?? 99.0;
    for (final star in stars) {
      if (identical(star, nearest)) continue;
      final mag = star.magnitude ?? 99.0;
      if (mag >= bestMag) continue;
      if (nearest.coordinates.separationDegrees(star.coordinates) >
          mergeDegrees) {
        continue;
      }
      best = star;
      bestMag = mag;
    }
    return best;
  }

  CelestialCoordinate? _screenToCelestial(
    Offset position,
    Size size,
    SkyViewState viewState,
  ) {
    // Delegate to the shared projector so the inverse can never drift from the
    // forward projection the painter uses: the painter has three projection
    // branches, and a hardcoded inverse resolves taps to the wrong sky
    // coordinate in the other two, increasingly so away from the view centre.
    final site = ref.read(observerLocationProvider).site;
    if (site == null) return null;
    final projector = SkyFovProjector.forSize(
      viewState,
      size,
      latitude: site.latitude,
      lstHours: viewState.viewMode == SkyViewMode.horizontal
          ? AstronomyCalculations.localSiderealTime(
              ref.read(observationTimeProvider).time,
              site.longitude,
            )
          : null,
    );
    return projector.unproject(position);
  }
}
