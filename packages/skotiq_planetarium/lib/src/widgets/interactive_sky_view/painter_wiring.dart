part of '../interactive_sky_view.dart';

extension _SkyViewPainterWiring on _InteractiveSkyViewState {
  /// Build a [SkyCanvasPainter] for one render layer (base or overlay).
  ///
  /// Animation phases are read live from the controllers and routed by scope so
  /// each layer only carries the phases it actually renders:
  /// * twinkle phase — only the overlay (it owns the bright-star pass);
  /// * selection pulse phase — only the overlay (it owns the selection ring);
  /// * DSO pop-in phase — only the base (DSOs scale on the base layer);
  /// * parallax pan delta — only the base (dim stars live on the base layer).
  SkyCanvasPainter _buildSkyPainter({
    required SkyRenderScope scope,
    required SkyViewState viewState,
    required SkyRenderConfig renderConfig,
    required RenderQualityConfig qualityConfig,
    required List<Star> stars,
    required List<DeepSkyObject> dsos,
    required List<ConstellationData> constellations,
    required DateTime observationMinute,
    required ({double latitude, double longitude}) location,
    required SelectedObjectState selectedObject,
    required MountPositionState mountPosition,
    required (double, double) sunPos,
    required (double, double, double) moonPos,
    required MoonTimes moonIllumination,
    required List<PlanetData> planets,
    required List<SatelliteData> satellites,
    required List<VariableStarData> variableStars,
    required List<MinorBodyData> minorPlanets,
    required List<MilkyWayPoint>? milkyWayPoints,
  }) {
    final isOverlay = scope == SkyRenderScope.overlay;
    // "Base" here means "this painter owns the static, non-animated content" —
    // which is true both for the split base layer AND for the single
    // full-scope painter the view collapses to when nothing on the overlay
    // animates. Testing `== base` alone silently dropped the background
    // suppression (and the pop-in phases) in the collapsed case.
    final isBase = scope != SkyRenderScope.overlay;
    final painter = SkyCanvasPainter(
      renderScope: scope,
      viewState: viewState,
      config: renderConfig,
      qualityConfig: qualityConfig,
      stars: stars,
      dsos: dsos,
      constellations: constellations,
      observationTime: observationMinute,
      latitude: location.latitude,
      longitude: location.longitude,
      selectedObject: selectedObject.coordinates,
      mountPosition: mountPosition.coordinates,
      mountStatus: _mapMountStatus(mountPosition.status),
      sunPosition: sunPos,
      moonPosition: (moonPos.$1, moonPos.$2, moonIllumination.illumination),
      planets: planets,
      satellites: satellites,
      variableStars: variableStars,
      minorPlanets: minorPlanets,
      milkyWayPoints: milkyWayPoints,
      // Twinkle + selection drive the overlay only.
      animationPhase: (isOverlay && qualityConfig.animateStarTwinkle)
          ? _twinkleController?.value
          : null,
      selectionAnimationPhase:
          (isOverlay && qualityConfig.enableSelectionAnimation)
          ? _selectionController.value
          : null,
      // DSO pop-in + parallax drive the base only.
      //
      // A pop-in phase is only meaningful while the pop-in is actually
      // running: the painter reads it as "how far through the fade/scale-in
      // are we" and a phase below 1 dims the layer. Passing it only while the
      // controller animates makes the resting state unambiguous (null = draw
      // at full strength) instead of depending on where the controller happens
      // to be parked.
      popinAnimationPhase:
          (isBase &&
              qualityConfig.enableStarPopin &&
              _popinController.isAnimating)
          ? _popinController.value
          : null,
      dsoPopinAnimationPhase:
          (isBase &&
              qualityConfig.enableDsoPopin &&
              _dsoPopinController.isAnimating)
          ? _dsoPopinController.value
          : null,
      parallaxPanDelta: (isBase && qualityConfig.enableParallax)
          ? _currentPanDelta
          : null,
      observedObjectIds: widget.observedObjectIds,
      listedObjectIds: widget.listedObjectIds,
      sequencedObjectIds: widget.sequencedObjectIds,
      bortleClass: widget.bortleClass,
      horizonAltitudes: widget.horizonAltitudes,
      // The gradient is drawn by the base layer only, so only the base painter
      // needs to skip it. The host promises, via
      // [SkyBackgroundLayer.occludesSkyGradient], that its layer is covering
      // the canvas right now; if it is not, the gradient stays and the sky
      // chart is unchanged.
      paintsOpaqueBackground:
          !isBase || widget.backgroundLayer?.occludesSkyGradient != true,
    );

    return painter;
  }
}
