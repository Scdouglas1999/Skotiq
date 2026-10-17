// ignore_for_file: unused_element, unused_field

part of '../sky_renderer.dart';

extension _SkyCanvasPainterPaintLifecycle on SkyCanvasPainter {
  void _paint(Canvas canvas, Size size) {
    final paintStopwatch = Stopwatch()..start();

    final center = Offset(size.width / 2, size.height / 2);
    final scale =
        math.min(size.width, size.height) / 2 / (viewState.fieldOfView / 2);

    // Build the per-paint cull context (cheap reject before projection) and
    // prime the shared projection cache for this pose so projected offsets are
    // reused within and across paints at the same pose. In horizontal mode the
    // projection (and therefore the cull cone and cached positions) also depend
    // on sidereal time, so the LST is threaded through both.
    final lstHours = viewState.viewMode == SkyViewMode.horizontal
        ? AstronomyCalculations.localSiderealTime(observationTime, longitude)
        : null;
    _cull = _CullContext.build(
      viewState,
      size,
      lstHours: lstHours,
      latitudeDeg: latitude,
    );
    SkyCanvasPainter._projectionCache.ensurePose(viewState, size, lstHours);

    // Label occupancy is per-paint (Flutter recreates the painter every frame),
    // but the scene is split across two painters. The base layer lays out the
    // DSO / solar-system / grid labels; the overlay layer then lays out the
    // bright-star names on top. Seeding the overlay with the base layer's
    // placements is what stops those two sets from colliding; an overlay that
    // starts empty draws star names straight through DSO and planet labels.
    if (renderScope == SkyRenderScope.overlay) {
      _labelManager.seed(SkyCanvasPainter._baseLabelRects);
    }

    // Per-section timing for diagnostic breakdown (collected once, then printed)
    final doTiming =
        !SkyCanvasPainter._hasLoggedTimingBreakdown &&
        SkyCanvasPainter._paintTimings.length >= 59;
    final sw = doTiming ? (Stopwatch()..start()) : null;
    int bgUs = 0, mwUs = 0, gridUs = 0, overlayUs = 0, constUs = 0;
    int starUs = 0, dsoUs = 0, solarUs = 0, labelUs = 0, markerUs = 0;

    // Draw background gradient (base layer only — static, expensive)
    if (_drawBase) {
      _drawBackground(canvas, size);
    }
    if (doTiming) {
      bgUs = sw!.elapsedMicroseconds;
      sw.reset();
      sw.start();
    }

    // Draw Milky Way (before everything else as background glow)
    if (_drawBase &&
        config.showMilkyWay &&
        milkyWayPoints != null &&
        milkyWayPoints!.isNotEmpty) {
      _drawMilkyWay(canvas, size, center, scale);
    }
    if (doTiming) {
      mwUs = sw!.elapsedMicroseconds;
      sw.reset();
      sw.start();
    }

    // In the EQUATORIAL frame the horizon is a REFERENCE, never terrain, and
    // no ground is filled at all.
    //
    // The flat-horizon ground model is a horizontal screen band whose Y comes
    // from the view centre's altitude (see [_altitudeScreenY]). That is only a
    // description of the horizon in the frame where "up the screen" means
    // "higher in the sky" — the horizontal one. Rotate the equatorial view, or
    // pan it off the meridian, and the band stops corresponding to anything.
    // Worse, it has three completely different whole-screen regimes (no fill /
    // gradient band / the entire canvas flooded with opaque ground once the
    // centre drops below the horizon), so simply panning or rotating flipped
    // the background between a night-sky gradient and flat brown-black. That
    // is what "the sky colour changes depending on where I rotate" was.
    //
    // Dropping it is also the right call on its own terms: this frame is the
    // planning atlas, and composing a session around a target that has not
    // risen yet is a first-class use of it, so the chart must stay legible and
    // consistently coloured whichever way it is pointed.
    //
    // A custom horizon PROFILE is still drawn, as a line: that path projects
    // real alt/az samples through the same projection as everything else, so
    // it is geometrically correct in this frame and is a genuine reference.
    //
    // The HORIZONTAL frame is the opposite case — there the ground is real
    // terrain that occludes — and draws it much later; see the call after the
    // solar-system pass.
    if (_drawBase &&
        viewState.viewMode == SkyViewMode.equatorial &&
        config.showHorizon) {
      _drawHorizon(canvas, size, center, scale);
    }

    // Draw coordinate grids
    if (_drawBase && config.showCoordinateGrid) {
      if (config.showEquatorialGrid) {
        _drawEquatorialGrid(canvas, size, center, scale);
      }
      if (config.showAltAzGrid) {
        _drawAltAzGrid(canvas, size, center, scale);
      }
      // Draw zenith marker when grid is shown
      _drawZenithMarker(canvas, size, center, scale);
    }
    if (doTiming) {
      gridUs = sw!.elapsedMicroseconds;
      sw.reset();
      sw.start();
    }

    if (_drawBase) {
      // Draw ecliptic
      if (config.showEcliptic) {
        _drawEcliptic(canvas, size, center, scale);
      }

      // Draw galactic plane
      if (config.showGalacticPlane) {
        _drawGalacticPlane(canvas, size, center, scale);
      }

      // Draw meridian line
      if (config.showMeridian) {
        _drawMeridianLine(canvas, size, center, scale);
      }

      // Airglow and the light-pollution dome are HORIZONTAL-frame layers, for
      // the same reason the ground fill is: both are horizontal screen bands
      // anchored to the view centre's altitude, which only tracks the real
      // horizon where screen-up is altitude. Drawn in the equatorial frame
      // they slid a warm band across the middle of the chart as the view
      // panned — a second, subtler source of "the sky colour keeps changing",
      // and a claim about where the murk is that was simply not true. With the
      // equatorial ground fill gone they would also be orphaned: a glow fading
      // toward a horizon that is not drawn.
      if (viewState.viewMode == SkyViewMode.horizontal) {
        // Horizon glow is airglow, so it always belongs UNDER the stars.
        if (config.showHorizon && qualityConfig.enableHorizonGlow) {
          _drawHorizonGlow(canvas, size, center, scale);
        }

        // Draw light pollution dome effect (quality mode only)
        if (qualityConfig.enableLightPollution) {
          _drawLightPollutionDome(canvas, size, center, scale);
        }
      }
    }
    if (doTiming) {
      overlayUs = sw!.elapsedMicroseconds;
      sw.reset();
      sw.start();
    }

    if (_drawBase) {
      // Draw constellation boundaries (behind lines)
      if (config.showConstellationBoundaries) {
        _drawConstellationBoundaries(canvas, size, center, scale);
      }

      // Draw constellation lines
      if (config.showConstellationLines) {
        _drawConstellationLines(canvas, size, center, scale);
      }

      // Draw constellation art overlays (only in balanced/quality tiers)
      if (config.showConstellationArt &&
          (qualityConfig.quality == RenderQuality.balanced ||
              qualityConfig.quality == RenderQuality.quality)) {
        _drawConstellationArt(canvas, size, center, scale);
      }
    }
    if (doTiming) {
      constUs = sw!.elapsedMicroseconds;
      sw.reset();
      sw.start();
    }

    // Draw stars. _drawStars honours the render scope internally: it draws the
    // dim + medium batches only on the base layer and the bright-star (twinkle)
    // pass only on the overlay layer, so bright stars are drawn exactly once.
    if (config.showStars) {
      _drawStars(canvas, size, center, scale);
    }
    if (doTiming) {
      starUs = sw!.elapsedMicroseconds;
      sw.reset();
      sw.start();
    }

    if (_drawBase) {
      // Draw DSOs
      if (config.showDSOs) {
        _drawDSOs(canvas, size, center, scale);
      }
    }

    // Density hotspot indicators removed — they add visual clutter
    // (circles with "+63" labels etc.) without meaningful benefit.
    // Users can simply zoom in to discover more objects.
    if (doTiming) {
      dsoUs = sw!.elapsedMicroseconds;
      sw.reset();
      sw.start();
    }

    if (_drawBase) {
      // Draw Sun
      if (config.showSun && sunPosition != null) {
        _drawSun(canvas, size, center, scale);
      }

      // Draw Moon
      if (config.showMoon && moonPosition != null) {
        _drawMoon(canvas, size, center, scale);
      }

      // Draw planets
      if (config.showPlanets && planets.isNotEmpty) {
        _drawPlanets(canvas, size, center, scale);
      }

      // Draw satellites
      if (config.showSatellites && satellites.isNotEmpty) {
        _drawSatellites(canvas, size, center, scale);
      }

      // Draw variable stars
      if (config.showVariableStars && variableStars.isNotEmpty) {
        _drawVariableStars(canvas, size, center, scale);
      }

      // Draw minor planets (asteroids and comets)
      if (config.showMinorPlanets && minorPlanets.isNotEmpty) {
        _drawMinorPlanets(canvas, size, center, scale);
      }
    }
    // In the HORIZONTAL frame the ground goes down here, AFTER the sky objects,
    // so it genuinely occludes them: that frame is "the sky from where I
    // stand", and terrain drawn beneath the objects lets every below-horizon
    // star, DSO and the Sun punch through as a translucent wash. The gradient
    // is fully transparent above the horizon line, so objects that are
    // genuinely up are unaffected.
    if (_drawBase && viewState.viewMode == SkyViewMode.horizontal) {
      _drawGroundAndHorizon(canvas, size, center, scale);
    }

    if (doTiming) {
      solarUs = sw!.elapsedMicroseconds;
      sw.reset();
      sw.start();
    }

    if (_drawBase) {
      // Draw constellation labels
      if (config.showConstellationLabels) {
        _drawConstellationLabels(canvas, size, center, scale);
      }

      // Draw cardinal directions
      if (config.showCardinalDirections) {
        _drawCardinalDirections(canvas, size);
      }
    }
    if (_drawBase) {
      // Hand this layer's occupancy to the overlay layer, which paints next and
      // must not draw star names over what was just placed here.
      SkyCanvasPainter._baseLabelRects = _labelManager.occupancy;
    }

    if (doTiming) {
      labelUs = sw!.elapsedMicroseconds;
      sw.reset();
      sw.start();
    }

    // Draw mount position marker (static crosshair — base layer)
    if (_drawBase &&
        config.showMountPosition &&
        mountPosition != null &&
        mountStatus != MountRenderStatus.disconnected) {
      _drawMountPositionMarker(
        canvas,
        size,
        center,
        scale,
        mountPosition!,
        mountStatus,
      );
    }

    // Draw selected object marker (pulsing ring — overlay layer so the pulse
    // animates without repainting the base).
    if (_drawOverlay && selectedObject != null) {
      _drawSelectionMarker(canvas, center, scale, selectedObject!);
    }

    // Draw target planning overlays (altitude track + meridian-flip marker for
    // the selected target, plus the twilight indicator). Overlay layer so they
    // ride along with the selection without forcing a base repaint.
    if (_drawOverlay && config.showPlanningOverlays) {
      _drawTwilightIndicator(canvas, size);
      if (selectedObject != null) {
        _drawTargetPlanningTrack(canvas, size, center, scale);
      }
    }
    if (doTiming) {
      markerUs = sw!.elapsedMicroseconds;
      sw.stop();
    }

    // Print per-section timing breakdown once after 60 frames for diagnostics
    if (doTiming) {
      SkyCanvasPainter._hasLoggedTimingBreakdown = true;
      final totalUs =
          bgUs +
          mwUs +
          gridUs +
          overlayUs +
          constUs +
          starUs +
          dsoUs +
          solarUs +
          labelUs +
          markerUs;
      developer.log(
        'SkyCanvasPainter TIMING BREAKDOWN (frame 60, ${(totalUs / 1000.0).toStringAsFixed(1)}ms total):\n'
        '  Background:     ${(bgUs / 1000.0).toStringAsFixed(2)}ms\n'
        '  Milky Way:      ${(mwUs / 1000.0).toStringAsFixed(2)}ms\n'
        '  Grids:          ${(gridUs / 1000.0).toStringAsFixed(2)}ms\n'
        '  Overlays:       ${(overlayUs / 1000.0).toStringAsFixed(2)}ms\n'
        '  Constellations: ${(constUs / 1000.0).toStringAsFixed(2)}ms\n'
        '  Stars (${stars.length}): ${(starUs / 1000.0).toStringAsFixed(2)}ms\n'
        '  DSOs (${dsos.length}):  ${(dsoUs / 1000.0).toStringAsFixed(2)}ms\n'
        '  Solar system:   ${(solarUs / 1000.0).toStringAsFixed(2)}ms\n'
        '  Labels:         ${(labelUs / 1000.0).toStringAsFixed(2)}ms\n'
        '  Markers:        ${(markerUs / 1000.0).toStringAsFixed(2)}ms\n'
        '  Quality: ${qualityConfig.quality.name}',
        name: 'SkyCanvasPainter',
        level: 500,
      );
    }

    // Record paint() frame time and warn if consistently over budget
    paintStopwatch.stop();
    final paintMs = paintStopwatch.elapsedMicroseconds / 1000.0;
    SkyCanvasPainter._paintTimings.add(paintMs);
    if (SkyCanvasPainter._paintTimings.length >
        SkyCanvasPainter._maxPaintTimingSamples) {
      SkyCanvasPainter._paintTimings.removeAt(0);
    }

    if (paintMs > SkyCanvasPainter._frameBudgetMs) {
      SkyCanvasPainter._overBudgetCount++;
    } else if (SkyCanvasPainter._overBudgetCount > 0) {
      SkyCanvasPainter._overBudgetCount--;
    }

    // Log warning if 10+ of last 60 frames exceeded the 16ms budget
    // Throttle to at most once per 5 seconds to avoid log spam
    if (SkyCanvasPainter._overBudgetCount >= 10 &&
        SkyCanvasPainter._paintTimings.length >= 20) {
      final now = DateTime.now();
      if (now.difference(SkyCanvasPainter._lastWarningTime).inSeconds >= 5) {
        SkyCanvasPainter._lastWarningTime = now;
        final avgMs =
            SkyCanvasPainter._paintTimings.reduce((a, b) => a + b) /
            SkyCanvasPainter._paintTimings.length;
        developer.log(
          'SkyCanvasPainter: paint() averaging ${avgMs.toStringAsFixed(1)}ms '
          '(budget: ${SkyCanvasPainter._frameBudgetMs}ms). '
          '${SkyCanvasPainter._overBudgetCount} of last '
          '${SkyCanvasPainter._paintTimings.length} frames over budget. '
          'Quality: ${qualityConfig.quality.name}, '
          'Stars: ${stars.length}, DSOs: ${dsos.length}. '
          'Consider lowering render quality.',
          name: 'SkyCanvasPainter',
          level: 900,
        );
      }
    }
  }

  bool _shouldRepaint(SkyCanvasPainter oldDelegate) {
    // The pose/data predicate covers everything that affects the static *base*
    // layer: view pose, config, quality, catalog identity, mount, the
    // observation minute, slow-moving solar-system/satellite/minor-planet data,
    // Milky Way, observed/listed markers, Bortle class and horizon profile.
    // It deliberately EXCLUDES the continuous twinkle phase, the selection
    // pulse phase, the parallax pan delta and the star pop-in phase, so a
    // static view paints the base once and then idles while those animate.
    final poseOrData = _poseOrDataChanged(oldDelegate);

    switch (renderScope) {
      case SkyRenderScope.base:
        return poseOrData;
      case SkyRenderScope.overlay:
        // The overlay owns the bright-star (twinkle) pass and the selection
        // pulse. It must repaint when the pose changes (bright-star and marker
        // screen positions move on pan/zoom), when the selection changes, when
        // the bright-star catalog identity changes, and on animation ticks.
        if (viewState != oldDelegate.viewState ||
            config != oldDelegate.config ||
            qualityConfig != oldDelegate.qualityConfig ||
            selectedObject != oldDelegate.selectedObject ||
            highlightedObject != oldDelegate.highlightedObject ||
            !identical(stars, oldDelegate.stars)) {
          return true;
        }
        // The planning overlays carry a wall-clock "now" marker on the twilight
        // gauge and altitude track, so when they are on the overlay must also
        // repaint as the observation minute advances.
        if (config.showPlanningOverlays &&
            observationTime.minute != oldDelegate.observationTime.minute) {
          return true;
        }
        return _overlayAnimationChanged(oldDelegate);
      case SkyRenderScope.full:
        // Standalone painter: repaint for either the base data OR the overlay
        // animations (the original single-layer behaviour).
        return poseOrData || _overlayAnimationChanged(oldDelegate);
    }
  }

  /// True if anything that affects the static base layer changed. Excludes the
  /// purely-animated phases (twinkle, selection pulse, parallax, star pop-in).
  bool _poseOrDataChanged(SkyCanvasPainter oldDelegate) {
    // Primary triggers
    if (viewState != oldDelegate.viewState ||
        config != oldDelegate.config ||
        qualityConfig != oldDelegate.qualityConfig ||
        selectedObject != oldDelegate.selectedObject ||
        highlightedObject != oldDelegate.highlightedObject ||
        paintsOpaqueBackground != oldDelegate.paintsOpaqueBackground) {
      return true;
    }

    // Catalog identity: the providers hand out a fresh list when the visible
    // star/DSO set changes (zoom reveal, catalog load). Identity compare is
    // cheap and avoids missing a real catalog change.
    if (!identical(stars, oldDelegate.stars) ||
        !identical(dsos, oldDelegate.dsos) ||
        !identical(constellations, oldDelegate.constellations)) {
      return true;
    }

    // Mount status change always triggers repaint
    if (mountStatus != oldDelegate.mountStatus) {
      return true;
    }

    // Mount position - only repaint if moved significantly (>0.05 degrees = ~3 arcmin)
    if (mountPosition != oldDelegate.mountPosition) {
      if (mountPosition == null || oldDelegate.mountPosition == null) {
        return true;
      }
      final raDiff = (mountPosition!.ra - oldDelegate.mountPosition!.ra).abs();
      final decDiff = (mountPosition!.dec - oldDelegate.mountPosition!.dec)
          .abs();
      if (raDiff > 0.05 / 15 || decDiff > 0.05) {
        return true;
      }
    }

    // Observation time - only check minute changes for horizon/alt-az grid
    // (stars/DSOs don't move visibly in a minute, but horizon does)
    if (config.showHorizon || config.showAltAzGrid) {
      if (observationTime.minute != oldDelegate.observationTime.minute) {
        return true;
      }
    }

    // Sun/Moon/Planets - these move slowly, check if data actually changed
    if (sunPosition != oldDelegate.sunPosition ||
        moonPosition != oldDelegate.moonPosition ||
        planets.length != oldDelegate.planets.length) {
      return true;
    }

    // Satellites update every 2 seconds from the position notifier.
    // Only repaint when the satellite data actually changes (length or positions).
    if (satellites.length != oldDelegate.satellites.length) {
      return true;
    }
    if (config.showSatellites &&
        satellites.isNotEmpty &&
        oldDelegate.satellites.isNotEmpty) {
      // The satellite list is recreated by the notifier each update, so if the
      // list reference changed, the data is new. Use identity check.
      if (!identical(satellites, oldDelegate.satellites)) {
        return true;
      }
    }

    // Variable stars / minor planets change
    if (variableStars.length != oldDelegate.variableStars.length) {
      return true;
    }
    if (config.showVariableStars != oldDelegate.config.showVariableStars) {
      return true;
    }
    if (minorPlanets.length != oldDelegate.minorPlanets.length) {
      return true;
    }
    if (config.showMinorPlanets != oldDelegate.config.showMinorPlanets) {
      return true;
    }
    // Minor planets update every 30s; repaint if data changed
    if (config.showMinorPlanets && minorPlanets.isNotEmpty) {
      for (
        int i = 0;
        i < minorPlanets.length && i < oldDelegate.minorPlanets.length;
        i++
      ) {
        if ((minorPlanets[i].ra - oldDelegate.minorPlanets[i].ra).abs() >
                0.001 ||
            (minorPlanets[i].dec - oldDelegate.minorPlanets[i].dec).abs() >
                0.01) {
          return true;
        }
      }
    }

    // Milky way data change
    if (milkyWayPoints != oldDelegate.milkyWayPoints) {
      return true;
    }

    // DSO pop-in scales the DSOs, which live on the base layer, so a change in
    // the DSO pop-in phase must repaint the base. This is a brief transient on
    // zoom (~300ms), not a continuous animation.
    if (dsoPopinAnimationPhase != oldDelegate.dsoPopinAnimationPhase) {
      return true;
    }

    // Observed object IDs change
    if (observedObjectIds.length != oldDelegate.observedObjectIds.length ||
        !observedObjectIds.containsAll(oldDelegate.observedObjectIds)) {
      return true;
    }

    // Listed object IDs change
    if (listedObjectIds.length != oldDelegate.listedObjectIds.length ||
        !listedObjectIds.containsAll(oldDelegate.listedObjectIds)) {
      return true;
    }

    // Sequence target IDs change (a target added or removed from tonight's plan
    // must move its marker on the sky).
    if (sequencedObjectIds.length != oldDelegate.sequencedObjectIds.length ||
        !sequencedObjectIds.containsAll(oldDelegate.sequencedObjectIds)) {
      return true;
    }

    // Bortle class change affects light pollution dome
    if (bortleClass != oldDelegate.bortleClass) {
      return true;
    }

    // Horizon profile change affects ground plane and horizon line
    if (horizonAltitudes != oldDelegate.horizonAltitudes) {
      return true;
    }

    return false;
  }

  /// True if a phase the *overlay* layer animates changed: the twinkle phase
  /// (quantized so 60Hz ticks become ~20Hz repaints) or the selection pulse.
  bool _overlayAnimationChanged(SkyCanvasPainter oldDelegate) {
    // Twinkle phase changes continuously; quantize to 20 steps/cycle so the
    // subtle brightness modulation repaints at ~20Hz instead of 60Hz.
    if (animationPhase != null || oldDelegate.animationPhase != null) {
      final cur = animationPhase ?? -1.0;
      final old = oldDelegate.animationPhase ?? -1.0;
      if ((cur * 20).floor() != (old * 20).floor()) {
        return true;
      }
    }
    // Selection pulse: short-lived, repaint every change.
    if (selectionAnimationPhase != oldDelegate.selectionAnimationPhase) {
      return true;
    }
    return false;
  }
}
