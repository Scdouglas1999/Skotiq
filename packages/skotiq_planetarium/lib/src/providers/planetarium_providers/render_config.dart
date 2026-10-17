part of '../planetarium_providers.dart';

// HUD toggle providers

/// Whether to show the compass HUD
final showCompassHudProvider = StateProvider<bool>((ref) => true);

/// Whether to show the mini-map
final showMinimapProvider = StateProvider<bool>((ref) => true);

/// Whether to show the ground plane
final showGroundPlaneProvider = StateProvider<bool>((ref) => true);

/// Whether to render the entire planetarium in night-vision (red) mode.
///
/// When enabled the screen content is wrapped in a luminance→red color filter
/// so the sky texture, overlays and HUD all go red, preserving dark adaptation
/// at the eyepiece. Off by default.
final nightVisionModeProvider = StateProvider<bool>((ref) => false);

/// Whether to show the FOV reference rings overlay (Telrad + optical finder)
/// centered on the view center for visual aiming / star-hopping. Off by
/// default.
final showFovRingsProvider = StateProvider<bool>((ref) => false);

/// Whether the angular-measurement tool is armed.
///
/// When enabled, a click-drag across the sky measures the angular separation
/// and position angle between the two endpoints instead of panning the view.
/// Off by default. The [InteractiveSkyView] reads this flag to switch its drag
/// handling and draw the measurement overlay.
final measurementModeProvider = StateProvider<bool>((ref) => false);

// Sky render config provider

class SkyRenderConfigNotifier extends StateNotifier<SkyRenderConfig> {
  /// Nullable so existing tests that construct the notifier bare keep working;
  /// [toggleGrid] falls back to the equatorial frame without it.
  final Ref? _ref;

  SkyRenderConfigNotifier([this._ref]) : super(const SkyRenderConfig());

  void toggleStars() {
    state = state.copyWith(showStars: !state.showStars);
  }

  void toggleConstellationLines() {
    state = state.copyWith(
      showConstellationLines: !state.showConstellationLines,
    );
  }

  void toggleConstellationLabels() {
    state = state.copyWith(
      showConstellationLabels: !state.showConstellationLabels,
    );
  }

  void toggleConstellationBoundaries() {
    state = state.copyWith(
      showConstellationBoundaries: !state.showConstellationBoundaries,
    );
  }

  void toggleDSOs() {
    state = state.copyWith(showDSOs: !state.showDSOs);
  }

  /// Toggle the coordinate-grid master.
  ///
  /// Turning the master ON also selects a FRAME when neither is chosen, because
  /// the renderer requires the master AND a frame flag
  /// (`paint_lifecycle.dart`, `showCoordinateGrid && (showEquatorialGrid ||
  /// showAltAzGrid)`), and all three default to false. Without this, the very
  /// first thing a user does in that group on a stock install — flip
  /// "Coordinate grid" — moved the switch and drew nothing: measured live, the
  /// sky changed by 99 pixels out of 712,800, all of them one marker glyph. A
  /// control that reports success and does nothing is the defect; making the
  /// hierarchy legible in the panel did not fix it, it moved it onto the master.
  ///
  /// The frame chosen matches the view the user is looking at (alt/az grid in the
  /// horizontal frame, RA/Dec grid otherwise) so the lines land where they are
  /// expected. Turning the master OFF leaves the frame flags alone, so the
  /// previous selection is remembered when it is switched back on.
  void toggleGrid() {
    final enabling = !state.showCoordinateGrid;
    if (!enabling) {
      state = state.copyWith(showCoordinateGrid: false);
      return;
    }

    final hasFrame = state.showEquatorialGrid || state.showAltAzGrid;
    if (hasFrame) {
      state = state.copyWith(showCoordinateGrid: true);
      return;
    }

    final horizontal =
        _ref?.read(skyViewStateProvider).viewMode == SkyViewMode.horizontal;
    state = state.copyWith(
      showCoordinateGrid: true,
      showAltAzGrid: horizontal,
      showEquatorialGrid: !horizontal,
    );
  }

  void toggleEquatorialGrid() {
    state = state.copyWith(showEquatorialGrid: !state.showEquatorialGrid);
  }

  void toggleAltAzGrid() {
    state = state.copyWith(showAltAzGrid: !state.showAltAzGrid);
  }

  void toggleEcliptic() {
    state = state.copyWith(showEcliptic: !state.showEcliptic);
  }

  void toggleGalacticPlane() {
    state = state.copyWith(showGalacticPlane: !state.showGalacticPlane);
  }

  void toggleHorizon() {
    state = state.copyWith(showHorizon: !state.showHorizon);
  }

  void setStarMagnitudeLimit(double limit) {
    state = state.copyWith(starMagnitudeLimit: limit);
  }

  void setDsoMagnitudeLimit(double limit) {
    state = state.copyWith(dsoMagnitudeLimit: limit);
  }

  void toggleMountPosition() {
    state = state.copyWith(showMountPosition: !state.showMountPosition);
  }

  void toggleMilkyWay() {
    state = state.copyWith(showMilkyWay: !state.showMilkyWay);
  }

  void toggleSun() {
    state = state.copyWith(showSun: !state.showSun);
  }

  void toggleMoon() {
    state = state.copyWith(showMoon: !state.showMoon);
  }

  void togglePlanets() {
    state = state.copyWith(showPlanets: !state.showPlanets);
  }

  void toggleGroundPlane() {
    state = state.copyWith(showGroundPlane: !state.showGroundPlane);
  }

  void toggleSatellites() {
    state = state.copyWith(showSatellites: !state.showSatellites);
  }

  void toggleVariableStars() {
    state = state.copyWith(showVariableStars: !state.showVariableStars);
  }

  void toggleMinorPlanets() {
    state = state.copyWith(showMinorPlanets: !state.showMinorPlanets);
  }

  void toggleConstellationArt() {
    state = state.copyWith(showConstellationArt: !state.showConstellationArt);
  }

  void togglePlanningOverlays() {
    state = state.copyWith(showPlanningOverlays: !state.showPlanningOverlays);
  }

  void toggleDsoLabels() {
    state = state.copyWith(showDSOLabels: !state.showDSOLabels);
  }

  void toggleCardinalDirections() {
    state = state.copyWith(
      showCardinalDirections: !state.showCardinalDirections,
    );
  }

  void toggleMeridian() {
    state = state.copyWith(showMeridian: !state.showMeridian);
  }
}

final skyRenderConfigProvider =
    StateNotifierProvider<SkyRenderConfigNotifier, SkyRenderConfig>((ref) {
      return SkyRenderConfigNotifier(ref);
    });

/// Computed render config that combines the base config with the ground plane toggle
/// This is the provider that should be used for actual rendering to ensure
/// the ground plane visibility respects the HUD toggle.
final effectiveSkyRenderConfigProvider = Provider<SkyRenderConfig>((ref) {
  final config = ref.watch(skyRenderConfigProvider);
  final showGroundPlane = ref.watch(showGroundPlaneProvider);
  return config.copyWith(showGroundPlane: showGroundPlane);
});

// Render quality provider

/// Notifier for managing render quality settings
class RenderQualityNotifier extends StateNotifier<RenderQualityConfig> {
  RenderQualityNotifier() : super(const RenderQualityConfig.balanced());

  /// Set the quality tier
  void setQuality(RenderQuality quality) {
    state = RenderQualityConfig.fromQuality(quality);
  }

  /// Set a custom configuration
  void setConfig(RenderQualityConfig config) {
    state = config;
  }

  /// Toggle a specific setting
  void toggleBlurEffects() {
    state = state.copyWith(useBlurEffects: !state.useBlurEffects);
  }

  void toggleGlowEffects() {
    state = state.copyWith(useGlowEffects: !state.useGlowEffects);
  }

  void toggleStarTwinkle() {
    state = state.copyWith(animateStarTwinkle: !state.animateStarTwinkle);
  }

  void toggleSmoothZoom() {
    state = state.copyWith(smoothZoomAnimation: !state.smoothZoomAnimation);
  }

  void setMilkyWayDetail(double detail) {
    state = state.copyWith(milkyWayDetail: detail.clamp(0.0, 1.0));
  }

  void setStarMagnitudeLimit(double limit) {
    state = state.copyWith(starMagnitudeLimit: limit);
  }

  void setDsoMagnitudeLimit(double limit) {
    state = state.copyWith(dsoMagnitudeLimit: limit);
  }
}

/// Provider for render quality configuration (user's manual selection)
final renderQualityProvider =
    StateNotifierProvider<RenderQualityNotifier, RenderQualityConfig>((ref) {
      return RenderQualityNotifier();
    });

/// LOD quality tier based on current field of view
enum LodTier {
  /// Wide FOV (>60 degrees): reduce quality for performance
  wide,

  /// Medium-wide FOV (30-60 degrees): moderate quality
  mediumWide,

  /// Medium FOV (10-30 degrees): balanced rendering
  medium,

  /// Narrow FOV (<10 degrees): full quality, show maximum detail
  narrow,
}

/// Determines the current LOD tier based on FOV
final lodTierProvider = Provider<LodTier>((ref) {
  final fov = ref.watch(skyViewStateProvider.select((s) => s.fieldOfView));
  if (fov > 60) return LodTier.wide;
  if (fov > 30) return LodTier.mediumWide;
  if (fov > 10) return LodTier.medium;
  return LodTier.narrow;
});

/// FOV-adaptive render quality that overrides the user's manual quality setting
/// based on the current zoom level. This ensures good performance at wide FOV
/// and maximum detail when zoomed in, regardless of the user's manual tier.
///
/// - Wide FOV (>60 deg): Downgrades glow quality, limits star count, disables
///   enhanced DSO symbols, reduces PSF quality
/// - Medium FOV (10-60 deg): Uses the user's chosen quality tier as-is
/// - Narrow FOV (<10 deg): Upgrades to full quality effects and higher limits
final fovAdaptiveQualityProvider = Provider<RenderQualityConfig>((ref) {
  final userQuality = ref.watch(renderQualityProvider);
  final lodTier = ref.watch(lodTierProvider);
  final (starMagLimit, dsoMagLimit) = ref.watch(dynamicMagnitudeLimitsProvider);

  // The FOV-aware limits are authoritative for what actually gets drawn.
  //
  // The painter gates every star and DSO on `qualityConfig`'s magnitude limits
  // (see `_drawStars` / `_drawDSOs`), so leaving the tier's *static* value here
  // capped the sky at that magnitude no matter how far the user zoomed: on the
  // balanced tier nothing fainter than mag 8 ever appeared, which rendered a
  // 1.5 deg field — an ordinary imaging FOV — all but empty, and made the deep
  // star tileset (floor mag 11.5) invisible in every view.
  //
  // Frame time is protected by object COUNT, not by magnitude: the per-tier
  // maxStarsToRender/maxDsosToRender caps below still bound the work, and the
  // spatial index returns the brightest N in view, so a deeper limit fills the
  // field in rather than uncapping it.
  return _lodAdaptedQuality(
    userQuality,
    lodTier,
  ).copyWith(starMagnitudeLimit: starMagLimit, dsoMagnitudeLimit: dsoMagLimit);
});

/// The tier's per-LOD effect/count adjustments, without the magnitude limits
/// (those are applied by [fovAdaptiveQualityProvider] from the FOV-aware
/// [dynamicMagnitudeLimitsProvider]).
RenderQualityConfig _lodAdaptedQuality(
  RenderQualityConfig userQuality,
  LodTier lodTier,
) {
  switch (lodTier) {
    case LodTier.wide:
      // Wide FOV (>60 deg): reduce quality for performance regardless of user setting.
      // DSO limit is generous because faint DSOs are batched as drawRawPoints
      // (near-zero cost). The dynamic magnitude provider already limits which
      // DSOs are passed based on FOV, so this cap is just a safeguard.
      return userQuality.copyWith(
        useBlurEffects: false,
        useGlowEffects:
            userQuality.quality != RenderQuality.performance &&
            userQuality.quality != RenderQuality.minimal,
        enableEnhancedDsoSymbols: false,
        enablePlanetDetails: false,
        enableParallax: false,
        animateStarTwinkle: false,
        starPsfQuality: (userQuality.starPsfQuality).clamp(0.0, 0.3),
        maxStarsToRender: userQuality.maxStarsToRender.clamp(0, 3000),
        maxDsosToRender: userQuality.maxDsosToRender.clamp(0, 3000),
        milkyWayDetail: (userQuality.milkyWayDetail).clamp(0.0, 0.3),
        groundPlaneDetail: (userQuality.groundPlaneDetail).clamp(0.0, 0.5),
      );

    case LodTier.mediumWide:
      // Medium-wide FOV (30-60 deg): slightly reduced quality, more objects than wide.
      // Faint DSOs are batched as points so the count limit can be generous.
      return userQuality.copyWith(
        useBlurEffects: false,
        enableParallax: false,
        animateStarTwinkle: false,
        starPsfQuality: (userQuality.starPsfQuality).clamp(0.0, 0.5),
        maxStarsToRender: userQuality.maxStarsToRender.clamp(0, 8000),
        maxDsosToRender: userQuality.maxDsosToRender.clamp(0, 5000),
      );

    case LodTier.medium:
      // Medium FOV (10-30 deg): use user's quality tier as-is
      return userQuality;

    case LodTier.narrow:
      // Narrow FOV (<10 deg): upgrade to full quality for maximum detail
      return userQuality.copyWith(
        useGlowEffects: true,
        useBlurEffects: userQuality.quality == RenderQuality.quality,
        enableEnhancedDsoSymbols: true,
        enablePlanetDetails: true,
        enableSelectionAnimation: true,
        starPsfQuality: (userQuality.starPsfQuality).clamp(0.5, 1.0),
        maxStarsToRender: userQuality.maxStarsToRender.clamp(5000, 20000),
        maxDsosToRender: userQuality.maxDsosToRender.clamp(2000, 8000),
      );
  }
}

/// How many magnitudes of limiting depth the current sky brightness costs, from
/// the Sun's altitude:
///
///   > 0 deg (daylight): 6.0
///   -6 to 0 (civil twilight): 3.0 to 6.0
///   -12 to -6 (nautical twilight): 1.5 to 3.0
///   -18 to -12 (astronomical twilight): 0 to 0.5
///   < -18 (full darkness): 0
///
/// The penalties are modest on purpose: the planetarium is a planning tool, so
/// a daylight penalty of 6 still leaves every Messier object and the bright
/// NGCs on screen. It does not model naked-eye visibility.
///
/// Separate from [dynamicMagnitudeLimitsProvider] because it depends only on
/// the minute and the observing site; folded in there, the iterative
/// sun-altitude solve re-runs on every zoom frame for a value that cannot have
/// changed.
///
/// With no site on record the Sun's altitude is unknown, so no penalty is
/// applied: this is a rendering depth knob, and the alternative is dimming the
/// chart on a guess about where the observer is standing.
final _skyBrightnessPenaltyProvider = Provider<double>((ref) {
  final site = ref.watch(observerLocationProvider).site;
  if (site == null) return 0.0;
  final time = ref.watch(_currentMinuteProvider);

  final sunAlt = AstronomyCalculations.sunAltitude(
    dt: time,
    latitudeDeg: site.latitude,
    longitudeDeg: site.longitude,
  );

  if (sunAlt >= 0) return 6.0;
  // sunAlt is negative below here, so each ramp is linear in sunAlt.
  if (sunAlt >= -6) return 6.0 + sunAlt; // -6 -> 3.0, 0 -> 6.0
  if (sunAlt >= -12) return 1.5 + (sunAlt + 12.0) / 6.0 * 1.5;
  if (sunAlt >= -18) return (sunAlt + 18.0) / 6.0 * 0.5;
  return 0.0;
});

/// Magnitude limits for the current field and sky brightness, as
/// (starMagLimit, dsoMagLimit).
///
/// Zooming in raises the limits; the sky-brightness penalty from
/// [_skyBrightnessPenaltyProvider] lowers them.
final dynamicMagnitudeLimitsProvider = Provider<(double, double)>((ref) {
  // Read the base limits from the USER's tier, not from
  // [fovAdaptiveQualityProvider]. The adaptive provider applies the limits this
  // provider computes, so watching it here would be a dependency cycle. The LOD
  // branches never modify the magnitude limits anyway, so the base values are
  // identical either way.
  final quality = ref.watch(renderQualityProvider);
  // Only the field of view matters here; selecting it keeps a pan or a roll
  // from invalidating limits that cannot have changed.
  final fov = ref.watch(skyViewStateProvider.select((s) => s.fieldOfView));
  // When stars are hidden the sky has no star clutter to declutter against, so
  // DSOs should be visible at any zoom rather than fading in as you zoom.
  final showStars = ref.watch(
    skyRenderConfigProvider.select((c) => c.showStars),
  );

  // Base limits from quality tier
  final baseStarLimit = quality.starMagnitudeLimit;
  final baseDsoLimit = quality.dsoMagnitudeLimit;

  // Continuous logarithmic scaling: narrower FOV reveals fainter objects smoothly.
  // At FOV 120 deg: fovFactor = 0.0 (just base)
  // At FOV  60 deg: fovFactor ~ 1.0
  // At FOV  30 deg: fovFactor ~ 2.0
  // At FOV  10 deg: fovFactor ~ 3.6
  // At FOV   5 deg: fovFactor ~ 4.6
  // At FOV   1 deg: fovFactor ~ 6.9
  //
  // Formula: fovFactor = 2.0 * log2(120 / clampedFov) - capped so we don't exceed catalog depth.
  // Using log2 gives a smooth ramp that increases ~2 magnitudes per halving of FOV.
  final clampedFov = fov.clamp(1.0, 120.0);
  final fovFactor = (2.0 * math.log(120.0 / clampedFov) / math.ln2).clamp(
    0.0,
    7.0,
  );

  // Sky brightness penalty (see [_skyBrightnessPenaltyProvider]). Kept in its
  // own provider so it is NOT recomputed on every zoom frame: it depends only
  // on the minute and the site, while this provider recomputes continuously as
  // the field of view changes.
  final skyBrightnessPenalty = ref.watch(_skyBrightnessPenaltyProvider);

  // Apply penalty: stars are less affected than DSOs because point sources
  // remain visible longer than extended objects in bright skies.
  // Stars get half the penalty of DSOs.
  final starPenalty = skyBrightnessPenalty * 0.5;
  final dsoPenalty = skyBrightnessPenalty;

  // Stars hidden -> use the maximum reveal factor for DSOs so they show at full
  // depth at any zoom level (no need to zoom in to "pop" them in).
  final dsoFovFactor = showStars ? fovFactor : 7.0;

  return (
    (baseStarLimit + fovFactor - starPenalty).clamp(2.0, 12.0),
    (baseDsoLimit + dsoFovFactor - dsoPenalty).clamp(4.0, 16.0),
  );
});
