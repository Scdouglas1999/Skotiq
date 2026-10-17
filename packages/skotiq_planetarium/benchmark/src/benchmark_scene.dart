// Shared scene wiring for the planetarium paint benchmark + golden comparator.
//
// Both the timing benchmark and the perceptual-diff gate must construct the
// *same* painter so their numbers describe the same workload. This module owns
// the worst-case render config, the FOV overlay, and the painter factory so
// there is a single source of truth.

import 'package:flutter/material.dart';

import 'package:skotiq_planetarium/src/rendering/fov_overlays.dart';
import 'package:skotiq_planetarium/src/rendering/render_quality.dart';
import 'package:skotiq_planetarium/src/rendering/sky_renderer.dart';

import 'camera_timeline.dart';
import 'stress_fixture.dart';

/// Canvas size every benchmark frame renders into. Fixed so timing and goldens
/// are comparable across machines. A mid-size desktop viewport.
const Size kBenchmarkCanvasSize = Size(1280, 800);

/// The worst-case render configuration: every expensive layer enabled.
/// Dense stars to a deep limit, many DSOs + labels, all grids, ecliptic,
/// galactic plane, meridian, Milky Way band, constellation lines + art, horizon
/// and ground plane.
///
/// [showPlanningOverlays] is on so the post-feature scene exercises the
/// session-planning render path that the accurate body-aware astronomy feeds:
/// the twilight (dusk/dawn) band gauge is drawn every frame from the observer
/// site + time (no selected target needed, so it is deterministic in this
/// headless scene). This is the realistic dense planning view a user actually
/// composes a night against, so the optimization loop must defend it.
const SkyRenderConfig kStressRenderConfig = SkyRenderConfig(
  showStars: true,
  showConstellationLines: true,
  showConstellationLabels: true,
  showConstellationBoundaries: false,
  showDSOs: true,
  showDSOLabels: true,
  showCoordinateGrid: true,
  showAltAzGrid: true,
  showEquatorialGrid: true,
  showEcliptic: true,
  showGalacticPlane: true,
  showHorizon: true,
  showCardinalDirections: true,
  showMilkyWay: true,
  showMountPosition: true,
  showSun: true,
  showMoon: true,
  showPlanets: true,
  showGroundPlane: true,
  showMeridian: true,
  showConstellationArt: true,
  showPlanningOverlays: true,
  starMagnitudeLimit: 13.0,
  dsoMagnitudeLimit: 13.0,
);

/// Render quality tier used for the benchmark. `balanced` is the production
/// default and enables the atlas/glow paths without the heaviest `quality`
/// extras, matching what users actually see.
const RenderQualityConfig kBenchmarkQuality = RenderQualityConfig.balanced();

/// The FOV overlay preset for the planning view, per the stress-scene
/// requirement. A realistic multi-indicator rig that exercises every glyph
/// branch of [FOVOverlayPainter]: a *rotated* camera sensor rectangle (corner
/// brackets + crosshair + rotation path), the concentric Telrad rings, and an
/// eyepiece circle. A user framing a target overlays exactly this kind of stack.
const List<FOVIndicator> kBenchmarkFovIndicators = [
  FOVIndicator(
    type: FOVType.sensorRectangle,
    widthDegrees: 1.5,
    heightDegrees: 1.0,
    rotation: 18.0,
    label: 'Camera',
  ),
  FOVIndicator(
    type: FOVType.telradCircles,
    widthDegrees: 4.0,
    heightDegrees: 4.0,
    label: 'Telrad',
  ),
  FOVIndicator(
    type: FOVType.eyepieceCircle,
    widthDegrees: 0.75,
    heightDegrees: 0.75,
    label: 'Eyepiece',
  ),
];

/// Build the sky painter for [frame] from [fixture] at the worst-case config.
///
/// [scope] lets the caller render the full single-layer scene (default, used by
/// the benchmark and goldens) or just one of the split layers.
SkyCanvasPainter buildSkyPainter({
  required StressFixture fixture,
  required CameraFrame frame,
  SkyRenderScope scope = SkyRenderScope.full,
}) {
  final observationTime = fixture.baseTimeUtc.add(
    Duration(seconds: frame.timeOffsetSeconds),
  );
  return SkyCanvasPainter(
    viewState: frame.toViewState(),
    config: kStressRenderConfig,
    qualityConfig: kBenchmarkQuality,
    stars: fixture.stars,
    dsos: fixture.dsos,
    constellations: fixture.constellations,
    milkyWayPoints: fixture.milkyWayPoints,
    planets: fixture.planets,
    observationTime: observationTime,
    latitude: fixture.latitude,
    longitude: fixture.longitude,
    sunPosition: fixture.sunPosition,
    moonPosition: fixture.moonPosition,
    renderScope: scope,
  );
}

/// Build the FOV overlay painter for [frame] (camera rectangle + Telrad).
FOVOverlayPainter buildFovPainter(CameraFrame frame) => FOVOverlayPainter(
  centerRA: frame.centerRaHours,
  centerDec: frame.centerDecDeg,
  viewFOV: frame.fieldOfViewDeg,
  indicators: kBenchmarkFovIndicators,
);
