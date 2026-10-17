// ignore_for_file: unused_element, unused_field

import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../celestial_object.dart';
import '../coordinate_system.dart';
import '../catalogs/constellation_data.dart';
import '../catalogs/constellation_art.dart';
import '../catalogs/satellite_catalog.dart';
import '../catalogs/variable_star_catalog.dart';
import '../catalogs/minor_planet_catalog.dart';
import '../astronomy/astronomy_calculations.dart';
import '../astronomy/planetary_positions.dart';
import '../astronomy/milky_way_data.dart';
import 'render_quality.dart';
import 'sprite_atlas.dart';
import 'star_psf_cache.dart';

part 'sky_renderer/projection_and_glow.dart';
part 'sky_renderer/background_layers.dart';
part 'sky_renderer/coordinate_layers.dart';
part 'sky_renderer/horizon_layers.dart';
part 'sky_renderer/constellation_layers.dart';
part 'sky_renderer/scene_geometry.dart';
part 'sky_renderer/markers.dart';
part 'sky_renderer/solar_bodies.dart';
part 'sky_renderer/small_bodies.dart';
part 'sky_renderer/planning_overlays.dart';
part 'sky_renderer/stellar_objects.dart';
part 'sky_renderer/render_models.dart';
part 'sky_renderer/render_cache.dart';
part 'sky_renderer/paint_lifecycle.dart';

class SkyCanvasPainter extends CustomPainter {
  final SkyViewState viewState;
  final SkyRenderConfig config;
  final RenderQualityConfig qualityConfig;
  final List<Star> stars;
  final List<DeepSkyObject> dsos;
  final List<ConstellationData> constellations;
  final DateTime observationTime;
  final double latitude;
  final double longitude;
  final CelestialCoordinate? selectedObject;
  final CelestialCoordinate? highlightedObject;
  final CelestialCoordinate? mountPosition;
  final MountRenderStatus mountStatus;
  final (double ra, double dec)? sunPosition;

  /// Moon RA/Dec in degrees plus its illuminated fraction AS A PERCENT (0-100),
  /// the unit [AstronomyCalculations.moonIllumination] returns and the unit the
  /// Dashboard and Plan Tonight moon cards display.
  final (double ra, double dec, double illuminationPercent)? moonPosition;
  final List<PlanetData> planets;
  final List<SatelliteData> satellites;
  final List<VariableStarData> variableStars;
  final List<MinorBodyData> minorPlanets;
  final List<MilkyWayPoint>? milkyWayPoints;

  /// Animation phase for star twinkle (0.0 - 1.0, cycles)
  final double? animationPhase;

  /// Animation phase for selection pulse (0.0 - 1.0, cycles)
  final double? selectionAnimationPhase;

  /// Animation phase for star pop-in (0.0 - 1.0)
  final double? popinAnimationPhase;

  /// Animation phase for DSO pop-in (0.0 - 1.0)
  final double? dsoPopinAnimationPhase;

  /// Current pan delta for parallax effect (pixels)
  final Offset? parallaxPanDelta;

  /// Set of catalog IDs or object names that have been observed.
  /// When non-empty, a small "observed" indicator is drawn on matching DSOs.
  final Set<String> observedObjectIds;

  /// Set of catalog IDs or object names that are in user observing lists.
  /// When non-empty, a small bookmark marker is drawn on matching DSOs.
  final Set<String> listedObjectIds;

  /// Set of catalog IDs or object names that are targets of the currently
  /// loaded sequence. When non-empty, a small marker is drawn on matching DSOs
  /// so the sky shows what tonight's plan is actually pointed at.
  final Set<String> sequencedObjectIds;

  /// Bortle dark-sky scale (1-9). Controls light pollution dome intensity.
  /// 1 = pristine dark sky, 9 = inner-city.
  final int bortleClass;

  /// Custom horizon altitude at each azimuth (degrees). 360 entries for
  /// each degree of azimuth, or null to use a flat 0 deg horizon.
  /// When provided, the ground plane and obstruction dimming use this profile.
  final List<double>? horizonAltitudes;

  /// Whether to fill the canvas with the opaque twilight gradient before
  /// drawing the sky.
  ///
  /// The base layer normally does, which makes the view opaque — so anything
  /// composited *beneath* it (the sky-survey imagery layer) would be invisible.
  /// A host that draws its own sky background underneath passes false here and
  /// owns the never-blank guarantee: suppress the gradient only while the layer
  /// underneath is actually covering the canvas.
  ///
  /// A real field rather than side-channel state, so [shouldRepaint] sees a
  /// flip without the host re-keying its `CustomPaint`.
  final bool paintsOpaqueBackground;

  /// Which slice of the scene this painter renders. See [SkyRenderScope].
  /// Defaults to [SkyRenderScope.full] so a standalone painter draws the whole
  /// sky (tests, thumbnails). The interactive host uses [SkyRenderScope.base]
  /// for the static layer and [SkyRenderScope.overlay] for the animated layer.
  final SkyRenderScope renderScope;

  static const double _deg2rad = math.pi / 180;
  static const double _rad2deg = 180 / math.pi;

  /// Memoized local sidereal time for the horizontal-mode projection.
  ///
  /// Computing sidereal time is comparatively expensive and, in
  /// [SkyViewMode.horizontal], every projected object needs it to rotate its
  /// RA/Dec into the local horizontal frame. Cached against the
  /// (observationTime, longitude) it was computed for and shared across the
  /// short-lived per-frame painter instances. Unused in equatorial mode.
  static double? _lstCacheValue;
  static DateTime? _lstCacheTime;
  static double? _lstCacheLon;

  /// Label layout manager to avoid overlapping labels.
  ///
  /// Deliberately per-painter (so occupancy never accumulates across frames);
  /// cross-*layer* sharing is handled by [_baseLabelRects].
  final LabelLayoutManager _labelManager = LabelLayoutManager();

  /// The label rectangles the base layer placed on its last paint.
  ///
  /// The overlay layer seeds its own layout from this so bright-star names do
  /// not overlap the DSO, planet and grid labels the base layer already drew.
  /// Static because Flutter recreates the painter for every frame and the two
  /// layers are separate painter instances.
  static List<Rect> _baseLabelRects = const [];

  /// Per-pose projection cache shared between base and overlay layers.
  ///
  /// Reused across paints with the same [viewState] + canvas size so repeated
  /// projections (momentum frames, the overlay's bright-star pass) avoid
  /// recomputing the projection trig. Static so it persists across the
  /// short-lived CustomPainter instances that Flutter recreates each frame.
  static final _ProjectionCache _projectionCache = _ProjectionCache();

  /// Cull/projection context built once per [paint] from [viewState] + size.
  /// Holds the cached unit vector of the view center and the cull threshold so
  /// objects can be rejected with a cheap dot-product before the full
  /// projection trig runs. Set at the top of [paint]; non-null during a paint.
  _CullContext? _cull;

  /// Reusable scratch buffer for batched point rendering (dim/medium star and
  /// DSO point passes). Promoted to a painter field and grown on demand so the
  /// hot loops don't allocate a fresh Float32List every paint. Static so it is
  /// shared across the per-frame painter instances Flutter recreates.
  static Float32List _pointScratch = Float32List(2048);

  /// Ensure the shared point scratch buffer holds at least [floats] entries.
  static Float32List _ensurePointScratch(int floats) {
    if (_pointScratch.length < floats) {
      var n = _pointScratch.length;
      while (n < floats) {
        n *= 2;
      }
      _pointScratch = Float32List(n);
    }
    return _pointScratch;
  }

  SkyCanvasPainter({
    required this.viewState,
    required this.config,
    this.qualityConfig = const RenderQualityConfig.balanced(),
    required this.stars,
    required this.dsos,
    required this.constellations,
    required this.observationTime,
    required this.latitude,
    required this.longitude,
    this.selectedObject,
    this.highlightedObject,
    this.mountPosition,
    this.mountStatus = MountRenderStatus.disconnected,
    this.sunPosition,
    this.moonPosition,
    this.planets = const [],
    this.satellites = const [],
    this.variableStars = const [],
    this.minorPlanets = const [],
    this.milkyWayPoints,
    this.animationPhase,
    this.selectionAnimationPhase,
    this.popinAnimationPhase,
    this.dsoPopinAnimationPhase,
    this.parallaxPanDelta,
    this.observedObjectIds = const {},
    this.listedObjectIds = const {},
    this.sequencedObjectIds = const {},
    this.bortleClass = 5,
    this.horizonAltitudes,
    this.renderScope = SkyRenderScope.full,
    this.paintsOpaqueBackground = true,
  });

  bool get _drawBase =>
      renderScope == SkyRenderScope.base || renderScope == SkyRenderScope.full;
  bool get _drawOverlay =>
      renderScope == SkyRenderScope.overlay ||
      renderScope == SkyRenderScope.full;

  // Frame time monitoring: rolling average to detect sustained budget overruns.
  // Static so it persists across painter instances (CustomPainter is recreated each frame).
  static final List<double> _paintTimings = [];
  static const int _maxPaintTimingSamples = 60;
  static int _overBudgetCount = 0;
  static const double _frameBudgetMs = 16.0; // 60fps target
  static DateTime _lastWarningTime = DateTime(2000);

  // Frame timing diagnostic: log a per-section breakdown once after the first
  // 60 frames so the developer can see exactly where time is spent.
  static bool _hasLoggedTimingBreakdown = false;

  /// Cached constellation art figures loaded once for all painters.
  static final List<ConstellationArtData> _constellationArtFigures =
      ConstellationArt.all;

  /// Reusable paint for glow shader rendering to avoid per-call allocation.
  static final Paint _glowShaderPaint = Paint();

  /// Cached GPU sprite atlas for the batched `drawRawAtlas` star/DSO passes.
  ///
  /// Baked once (lazily, on first paint) and reused across the short-lived
  /// painter instances Flutter recreates each frame. Rebuilt only when the
  /// device-pixel-ratio bucket or the per-tier sprite knobs (softness / spike
  /// variant) change. Static so the GPU textures persist across frames.
  static SkySpriteAtlas? _spriteAtlas;

  /// Reusable composite paint for the additive star atlas pass. `BlendMode.plus`
  /// makes the white sprites sum where they overlap, so a dense field reads as a
  /// glow rather than flat discs.
  static final Paint _starAtlasPaint = Paint()..blendMode = BlendMode.plus;

  /// Reusable composite paint for the DSO atlas pass. Source-over (not additive)
  /// so overlapping DSO glyphs don't blow out to white.
  static final Paint _dsoAtlasPaint = Paint();

  // Reusable scratch buffers for the atlas passes
  // Grown on demand and shared across the per-frame painter instances so the
  // hot loops never reallocate. Each star/DSO consumes 4 transform floats, 4
  // rect floats and 1 color int.
  static Float32List _atlasTransforms = Float32List(4 * 1024);
  static Float32List _atlasRects = Float32List(4 * 1024);
  static Int32List _atlasColors = Int32List(1024);

  /// Bright-star variant of the scratch buffers (the overlay layer's spiked
  /// pass), kept separate so the base (dim+medium plain) and overlay (bright,
  /// possibly spiked) atlas builds don't clobber each other within a frame.
  static Float32List _atlasTransforms2 = Float32List(4 * 256);
  static Float32List _atlasRects2 = Float32List(4 * 256);
  static Int32List _atlasColors2 = Int32List(256);

  /// Ensure the primary atlas scratch buffers hold at least [count] sprites.
  static void _ensureAtlasScratch(int count) {
    if (_atlasColors.length < count) {
      var n = _atlasColors.length;
      while (n < count) {
        n *= 2;
      }
      _atlasTransforms = Float32List(n * 4);
      _atlasRects = Float32List(n * 4);
      _atlasColors = Int32List(n);
    }
  }

  /// Ensure the secondary (bright-star) atlas scratch buffers hold at least
  /// [count] sprites.
  static void _ensureAtlasScratch2(int count) {
    if (_atlasColors2.length < count) {
      var n = _atlasColors2.length;
      while (n < count) {
        n *= 2;
      }
      _atlasTransforms2 = Float32List(n * 4);
      _atlasRects2 = Float32List(n * 4);
      _atlasColors2 = Int32List(n);
    }
  }

  /// Get the cached sprite atlas, baking (or rebaking) it if the device-pixel-
  /// ratio bucket or the tier's sprite knobs changed since the last bake.
  ///
  /// The bake is synchronous (`Picture.toImageSync`) so the returned atlas is
  /// usable in the same paint pass.
  SkySpriteAtlas _atlas(double dpr) {
    final bucketDpr = (dpr.clamp(1.0, 3.0) * 2).round() / 2.0;
    final softness = qualityConfig.spriteSoftness;
    final spikes = qualityConfig.useDiffractionSpikes;
    final existing = _spriteAtlas;
    if (existing != null && existing.matches(bucketDpr, softness, spikes)) {
      return existing;
    }
    existing?.dispose();
    final baked = SkySpriteAtlas.bake(
      dpr: bucketDpr,
      softness: softness,
      spikes: spikes,
    );
    _spriteAtlas = baked;
    return baked;
  }

  /// Dispose and clear the cached sprite atlas (called on memory-pressure cache
  /// clears). The next paint re-bakes it lazily.
  static void disposeSpriteAtlas() {
    _spriteAtlas?.dispose();
    _spriteAtlas = null;
  }

  /// Release every cache the renderer holds process-wide: the baked GPU sprite
  /// atlas, the per-pose projection cache, the label hand-off, and the cached
  /// `TextPainter`s, shaders and blur filters.
  ///
  /// Everything released here is rebuilt lazily on the next paint, so the only
  /// cost is one frame of re-warming. Called when the last sky view is disposed
  /// and on system memory pressure — before this existed, the atlas
  /// (a `ui.Image` from `Picture.toImageSync`) and a projection cache holding
  /// strong references to every projected `Star`/`DeepSkyObject` outlived the
  /// screen that created them, for the life of the process.
  static void releaseRenderCaches() {
    _PaintCache.clearCaches();
    _projectionCache.clear();
    _baseLabelRects = const [];
  }

  /// Whether the baked GPU sprite atlas is currently resident.
  @visibleForTesting
  static bool get spriteAtlasIsResident => _spriteAtlas != null;

  /// How many objects the shared projection cache is holding a reference to.
  @visibleForTesting
  static int get projectionCacheEntryCount => _projectionCache.entryCount;

  /// The device pixel ratio the sprite atlas should bake for. Read from the
  /// platform view so the baked texels are crisp at native resolution; falls
  /// back to 2.0 when no view is available (headless tests), which still yields
  /// crisp sprites since they are downscaled by the RSTransform.
  double get _devicePixelRatio {
    final views = ui.PlatformDispatcher.instance.views;
    if (views.isEmpty) return 2.0;
    return views.first.devicePixelRatio;
  }

  @override
  void paint(Canvas canvas, Size size) => _paint(canvas, size);

  @override
  bool shouldRepaint(covariant SkyCanvasPainter oldDelegate) =>
      _shouldRepaint(oldDelegate);
}
