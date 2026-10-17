// ignore_for_file: unused_element, unused_field

part of '../sky_renderer.dart';

class _PaintCache {
  // Cached MaskFilters (expensive to create)
  static final Map<double, MaskFilter> _blurFilters = {};
  static const int _maxBlurFilterEntries = 64;

  // Reusable paint objects for common operations
  // These are created once and reused by updating their properties
  static final Paint _fillPaint = Paint();
  static final Paint _strokePaint = Paint()..style = PaintingStyle.stroke;
  static final Paint _dimStarPaint = Paint()
    ..strokeWidth = 1.5
    ..strokeCap = StrokeCap.round;
  static final Paint _gridPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.5;
  static final Paint _constellationPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  // Additional cached paints for various rendering operations
  static final Paint _horizonPaint = Paint()
    ..strokeWidth = 1.5
    ..style = PaintingStyle.stroke;
  static final Paint _eclipticPaint = Paint()
    ..strokeWidth = 1.5
    ..style = PaintingStyle.stroke;
  static final Paint _galacticPlanePaint = Paint()
    ..strokeWidth = 1.5
    ..style = PaintingStyle.stroke;
  static final Paint _meridianPaint = Paint()
    ..strokeWidth = 1.5
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  static final Paint _altAzPaint = Paint()
    ..strokeWidth = 0.5
    ..style = PaintingStyle.stroke;
  static final Paint _zenithCrossPaint = Paint()..strokeWidth = 1.0;
  static final Paint _groundPaint = Paint()..style = PaintingStyle.fill;
  static final Paint _backgroundPaint = Paint();

  // Cached background gradient (only recreate when size changes)
  static Size? _lastBackgroundSize;
  static ui.Shader? _cachedDarkBackgroundShader;
  static ui.Shader? _cachedTwilightVerticalShader;
  static ui.Shader? _cachedTwilightRadialShader;
  static double? _lastSunAltitude;

  /// Get a fill paint with specified color (reuses single instance)
  static Paint getFillPaint(Color color) {
    _fillPaint.color = color;
    _fillPaint.shader = null;
    _fillPaint.maskFilter = null;
    return _fillPaint;
  }

  /// Get a stroke paint with specified color and width (reuses single instance)
  static Paint getStrokePaint(Color color, double strokeWidth) {
    _strokePaint.color = color;
    _strokePaint.strokeWidth = strokeWidth;
    _strokePaint.shader = null;
    _strokePaint.maskFilter = null;
    return _strokePaint;
  }

  /// Get the dim star paint (for batched point rendering)
  static Paint getDimStarPaint(Color color) {
    _dimStarPaint.color = color;
    return _dimStarPaint;
  }

  /// Get grid paint with specified color
  static Paint getGridPaint(Color color) {
    _gridPaint.color = color;
    return _gridPaint;
  }

  /// Get constellation line paint
  static Paint getConstellationPaint(Color color) {
    _constellationPaint.color = color;
    return _constellationPaint;
  }

  /// Get or create a cached MaskFilter for blur effects
  static MaskFilter getBlurFilter(double sigma) {
    final roundedSigma = (sigma * 2).round() / 2;
    var filter = _blurFilters[roundedSigma];
    if (filter == null) {
      if (_blurFilters.length >= _maxBlurFilterEntries) {
        _blurFilters.remove(_blurFilters.keys.first);
      }
      filter = MaskFilter.blur(BlurStyle.normal, roundedSigma);
      _blurFilters[roundedSigma] = filter;
    }
    return filter;
  }

  // Cached blur paints with various sigma values
  static final Map<double, Paint> _blurPaints = {};
  static const int _maxBlurPaintEntries = 64;

  /// Get or create a Paint with blur filter at the specified sigma
  /// This caches the Paint object with MaskFilter to avoid recreation
  static Paint getBlurPaint(double sigma, Color color, {double alpha = 1.0}) {
    // Round sigma to reduce cache size (blur differences < 0.5 are imperceptible)
    final roundedSigma = (sigma * 2).round() / 2;

    var paint = _blurPaints[roundedSigma];
    if (paint == null) {
      if (_blurPaints.length >= _maxBlurPaintEntries) {
        _blurPaints.remove(_blurPaints.keys.first);
      }
      paint = Paint()
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, roundedSigma);
      _blurPaints[roundedSigma] = paint;
    }
    // Update color (Paint objects can have color changed without recreation)
    paint.color = color.withValues(alpha: alpha);
    return paint;
  }

  /// Get horizon paint with specified color
  static Paint getHorizonPaint(Color color) {
    _horizonPaint.color = color;
    return _horizonPaint;
  }

  /// Get ecliptic paint with specified color
  static Paint getEclipticPaint(Color color) {
    _eclipticPaint.color = color;
    return _eclipticPaint;
  }

  /// Get galactic plane paint with specified color
  static Paint getGalacticPlanePaint(Color color) {
    _galacticPlanePaint.color = color;
    return _galacticPlanePaint;
  }

  /// Get meridian paint with specified color
  static Paint getMeridianPaint(Color color) {
    _meridianPaint.color = color;
    return _meridianPaint;
  }

  /// Get alt-az grid paint with specified color
  static Paint getAltAzPaint(Color color) {
    _altAzPaint.color = color;
    return _altAzPaint;
  }

  /// Get zenith cross paint with specified color
  static Paint getZenithCrossPaint(Color color) {
    _zenithCrossPaint.color = color;
    return _zenithCrossPaint;
  }

  /// Get ground plane paint with specified color
  static Paint getGroundPaint(Color color) {
    _groundPaint.color = color;
    _groundPaint.shader = null;
    return _groundPaint;
  }

  /// Get background paint with shader
  static Paint getBackgroundPaint(ui.Shader shader) {
    _backgroundPaint.shader = shader;
    return _backgroundPaint;
  }

  /// Get or create dark background shader (cached per size)
  static ui.Shader getDarkBackgroundShader(Size size) {
    if (_lastBackgroundSize != size || _cachedDarkBackgroundShader == null) {
      _cachedDarkBackgroundShader = const RadialGradient(
        center: Alignment.center,
        radius: 1.5,
        colors: [Color(0xFF0A0A1A), Color(0xFF050510), Color(0xFF020208)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
      _lastBackgroundSize = size;
    }
    return _cachedDarkBackgroundShader!;
  }

  /// Clear caches (call when memory pressure is high)
  static void clearCaches() {
    _blurFilters.clear();
    _blurPaints.clear();
    _TextCache.clear();
    _ShaderCache.clear();
    _lastBackgroundSize = null;
    _cachedDarkBackgroundShader = null;
    _cachedTwilightVerticalShader = null;
    _cachedTwilightRadialShader = null;
    _lastSunAltitude = null;
    // Clear global rendering caches
    _constellationLineCache.clear();
    _milkyWayCache.clear();
    _backgroundGradientCache.clear();
    _starPsfShaderCache.clear();
    SkyCanvasPainter.disposeSpriteAtlas();
  }
}

/// Cache for TextPainter objects to avoid expensive text layout every frame
/// TextPainter creation and layout() are CPU-intensive operations
class _TextCache {
  static final Map<String, TextPainter> _cache = {};
  static const int _maxCacheSize = 500;

  /// Get or create a TextPainter for the given text and style
  /// The TextPainter is cached and reused across frames
  static TextPainter get(String text, TextStyle style) {
    final key =
        '${text}_${style.fontSize}_${style.color?.toARGB32() ?? 0}_${style.fontWeight?.value ?? 0}';

    var painter = _cache[key];
    if (painter == null) {
      // Evict old entries if cache is full
      if (_cache.length >= _maxCacheSize) {
        // Remove oldest 100 entries
        final keysToRemove = _cache.keys.take(100).toList();
        for (final k in keysToRemove) {
          _cache[k]?.dispose();
          _cache.remove(k);
        }
      }

      painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: ui.TextDirection.ltr,
      );
      painter.layout();
      _cache[key] = painter;
    }
    return painter;
  }

  static void clear() {
    for (final painter in _cache.values) {
      painter.dispose();
    }
    _cache.clear();
  }
}

/// Cache for gradient shaders to avoid recreating them every frame
/// Shader creation involves GPU resource allocation
class _ShaderCache {
  static final Map<String, ui.Shader> _radialShaders = {};
  static final Map<String, ui.Shader> _linearShaders = {};
  static const int _maxCacheSize = 512;

  /// Get or create a radial gradient shader
  static ui.Shader getRadialShader(
    Offset center,
    double radius,
    List<Color> colors,
    List<double>? stops,
  ) {
    // Create a key based on the parameters (rounded for cache efficiency)
    final cx = (center.dx / 10).round() * 10;
    final cy = (center.dy / 10).round() * 10;
    final r = (radius / 5).round() * 5;
    final colorKey = colors.map((c) => c.toARGB32()).join('_');
    final key = 'r_${cx}_${cy}_${r}_$colorKey';

    var shader = _radialShaders[key];
    if (shader == null) {
      if (_radialShaders.length >= _maxCacheSize) {
        _radialShaders.clear(); // Simple eviction
      }
      shader = RadialGradient(
        colors: colors,
        stops: stops,
      ).createShader(Rect.fromCircle(center: center, radius: radius));
      _radialShaders[key] = shader;
    }
    return shader;
  }

  static void clear() {
    _radialShaders.clear();
    _linearShaders.clear();
  }
}

final StarPsfShaderCache _starPsfShaderCache = StarPsfShaderCache();

/// Cached constellation line rendering.
/// Since constellation lines don't change unless the view moves significantly,
/// we record them into a ui.Picture and replay it each frame.
/// Cache invalidates when view center moves >0.5 degrees or zoom changes >5%.
/// The full set of view parameters a cached [ui.Picture] was projected with.
///
/// The key must carry every input the projection reads, or a replayed picture
/// describes a view the user is no longer in:
///
/// * the pose (center + FOV);
/// * the roll — rotating the view leaves geometry at the old roll while the
///   stars turn under it;
/// * the projection formula — stereographic <-> orthographic replays stale
///   geometry;
/// * the view frame and, in [SkyViewMode.horizontal], sidereal time:
///   `centerRA`/`centerDec` never change while panning there, so a key without
///   them hits on every frame and the cached geometry stays glued to the screen
///   while the star field slides beneath it.
class _CachedPose {
  double _ra = double.nan;
  double _dec = double.nan;
  double _az = double.nan;
  double _alt = double.nan;
  double _fov = double.nan;
  double _rotation = double.nan;
  int _lstBucket = -1;
  SkyProjection? _projection;
  SkyViewMode? _viewMode;
  Size _size = Size.zero;

  /// Sidereal time bucketed to the minute. A sidereal minute rotates the sky by
  /// 0.25 deg, comfortably inside the 0.5 deg move tolerance below.
  static int _bucketLst(double? lstHours) =>
      lstHours == null ? -1 : (lstHours * 60).round();

  bool matches(SkyViewState v, Size size, double? lstHours) {
    if (size != _size) return false;
    if (_projection != v.projection || _viewMode != v.viewMode) return false;
    if ((v.rotation - _rotation).abs() > 0.1) return false;

    final fovRatio = _fov > 0 ? (v.fieldOfView / _fov) : 0.0;
    if (fovRatio <= 0.95 || fovRatio >= 1.05) return false;

    if (v.viewMode == SkyViewMode.horizontal) {
      if (_lstBucket != _bucketLst(lstHours)) return false;
      var dAz = (v.centerAz - _az).abs();
      if (dAz > 180) dAz = 360 - dAz;
      // Azimuth converges at the zenith, so weight it by cos(altitude).
      final cosAlt = math.cos(v.centerAltitude * math.pi / 180).abs();
      return dAz * cosAlt < 0.5 && (v.centerAltitude - _alt).abs() < 0.5;
    }

    var dRa = (v.centerRA - _ra).abs();
    if (dRa > 12) dRa = 24 - dRa; // RA wraps at 24h
    return dRa * 15.0 < 0.5 && (v.centerDec - _dec).abs() < 0.5;
  }

  void store(SkyViewState v, Size size, double? lstHours) {
    _ra = v.centerRA;
    _dec = v.centerDec;
    _az = v.centerAz;
    _alt = v.centerAltitude;
    _fov = v.fieldOfView;
    _rotation = v.rotation;
    _projection = v.projection;
    _viewMode = v.viewMode;
    _lstBucket = _bucketLst(lstHours);
    _size = size;
  }
}

class _ConstellationLineCache {
  ui.Picture? _picture;
  final _pose = _CachedPose();
  int _cachedConstellationCount = 0;

  bool isValid(
    SkyViewState viewState,
    Size size,
    double? lstHours,
    int constellationCount,
  ) {
    if (_picture == null) return false;
    if (constellationCount != _cachedConstellationCount) return false;
    return _pose.matches(viewState, size, lstHours);
  }

  void store(
    ui.Picture picture,
    SkyViewState viewState,
    Size size,
    double? lstHours,
    int constellationCount,
  ) {
    _picture?.dispose();
    _picture = picture;
    _pose.store(viewState, size, lstHours);
    _cachedConstellationCount = constellationCount;
  }

  ui.Picture? get picture => _picture;

  void clear() {
    _picture?.dispose();
    _picture = null;
  }
}

/// Cached Milky Way rendering using the same view-invalidation strategy.
class _MilkyWayCache {
  ui.Picture? _picture;
  final _pose = _CachedPose();

  bool isValid(SkyViewState viewState, Size size, double? lstHours) {
    if (_picture == null) return false;
    return _pose.matches(viewState, size, lstHours);
  }

  void store(
    ui.Picture picture,
    SkyViewState viewState,
    Size size,
    double? lstHours,
  ) {
    _picture?.dispose();
    _picture = picture;
    _pose.store(viewState, size, lstHours);
  }

  ui.Picture? get picture => _picture;

  void clear() {
    _picture?.dispose();
    _picture = null;
  }
}

// Global caches (persist across painter instances since they're recreated each frame)
final _constellationLineCache = _ConstellationLineCache();
final _milkyWayCache = _MilkyWayCache();

/// Memoized night-long astronomy for the planning overlays.
///
/// Both overlays live on the *animated* overlay layer, so they repaint on every
/// pan frame and on every selection-pulse tick. Recomputing them there meant an
/// iterative rise/set solve plus 49 sidereal-time + horizontal transforms per
/// frame for the altitude track, and a second iterative solve for the twilight
/// gauge. Neither result can change faster than once a minute, and the altitude
/// track only changes per (target, date, site).
class _PlanningAstronomyCache {
  ({double raDeg, double decDeg, int day, double lat, double lon})? _trackKey;
  (List<double> altitudes, double maxAlt)? _track;

  ({int day, double lat, double lon})? _twilightKey;
  TwilightTimes? _twilight;

  /// The sampled altitude track for [raDeg]/[decDeg] over the local noon→noon
  /// window, computed by [compute] only on a key miss.
  (List<double>, double) altitudeTrack({
    required double raDeg,
    required double decDeg,
    required DateTime localNoon,
    required double latitudeDeg,
    required double longitudeDeg,
    required (List<double>, double) Function() compute,
  }) {
    final key = (
      raDeg: raDeg,
      decDeg: decDeg,
      day: _dayKey(localNoon),
      lat: latitudeDeg,
      lon: longitudeDeg,
    );
    final cached = _track;
    if (cached != null && _trackKey == key) return cached;
    final fresh = compute();
    _trackKey = key;
    _track = fresh;
    return fresh;
  }

  /// Tonight's twilight times, computed by [compute] only on a key miss.
  TwilightTimes twilight({
    required DateTime date,
    required double latitudeDeg,
    required double longitudeDeg,
    required TwilightTimes Function() compute,
  }) {
    final key = (day: _dayKey(date), lat: latitudeDeg, lon: longitudeDeg);
    final cached = _twilight;
    if (cached != null && _twilightKey == key) return cached;
    final fresh = compute();
    _twilightKey = key;
    _twilight = fresh;
    return fresh;
  }

  static int _dayKey(DateTime d) => d.year * 10000 + d.month * 100 + d.day;
}

final _planningAstronomyCache = _PlanningAstronomyCache();

/// Cached background gradient shader keyed by sun altitude bucket.
/// The twilight gradient only changes meaningfully when the sun moves ~2 degrees.
class _BackgroundGradientCache {
  ui.Shader? _verticalShader;
  ui.Shader? _radialShader;
  int _sunAltBucket = -999;
  Size _size = Size.zero;

  /// Check if cache is valid for the given sun altitude and size.
  /// Sun altitude is bucketed to nearest 2 degrees.
  bool isValid(double sunAlt, Size size) {
    final bucket = (sunAlt / 2).round();
    return _verticalShader != null &&
        _radialShader != null &&
        bucket == _sunAltBucket &&
        size == _size;
  }

  void store(ui.Shader vertical, ui.Shader radial, double sunAlt, Size size) {
    _verticalShader = vertical;
    _radialShader = radial;
    _sunAltBucket = (sunAlt / 2).round();
    _size = size;
  }

  ui.Shader? get verticalShader => _verticalShader;
  ui.Shader? get radialShader => _radialShader;

  void clear() {
    _verticalShader = null;
    _radialShader = null;
    _sunAltBucket = -999;
  }
}

final _backgroundGradientCache = _BackgroundGradientCache();

/// Per-paint culling context.
///
/// Built once at the top of [SkyCanvasPainter.paint] from the current view
/// state and canvas size. Holds the unit vector of the view center plus a
/// cosine threshold so an object can be rejected with a single dot product
/// (cull-BEFORE-project) instead of running the full projection trig and then
/// discarding off-screen results.
class _CullContext {
  /// Unit vector (x,y,z) of the view-center direction in equatorial frame.
  final double cx;
  final double cy;
  final double cz;

  /// Cosine of the cull half-angle. An object whose direction has a dot
  /// product with the center direction LESS than this is outside the cull
  /// cone and can be skipped. Computed from the FOV plus a generous margin so
  /// objects whose glow/label spills onscreen from just outside are kept.
  final double cosCullRadius;

  /// Equatorial coordinates of the view center (degrees), already resolved out
  /// of whichever frame the view is in. Lets the great-circle overlays bound
  /// their sampling to the window that can possibly be visible instead of
  /// walking the whole sphere.
  final double centerRaDeg;
  final double centerDecDeg;

  /// Half-angle of the cull cone in degrees — the widest angular separation
  /// from the view center that can still appear on screen.
  final double cullRadiusDeg;

  const _CullContext(
    this.cx,
    this.cy,
    this.cz,
    this.cosCullRadius,
    this.centerRaDeg,
    this.centerDecDeg,
    this.cullRadiusDeg,
  );

  /// Inclusive declination window that can be visible, clamped to the poles.
  (double min, double max) get decWindow => (
    (centerDecDeg - cullRadiusDeg).clamp(-90.0, 90.0),
    (centerDecDeg + cullRadiusDeg).clamp(-90.0, 90.0),
  );

  /// Half-width in RA HOURS of the window that can be visible.
  ///
  /// Returns 12 (i.e. all right ascensions) when the window reaches a pole or
  /// spans far enough that every RA is in view — at high declination a small
  /// angular radius still covers every hour.
  double get raHalfWindowHours {
    final (minDec, maxDec) = decWindow;
    if (minDec <= -89.9 || maxDec >= 89.9 || cullRadiusDeg >= 89.0) return 12.0;
    final cosDec = math.cos(centerDecDeg * (math.pi / 180)).abs();
    if (cosDec < 0.02) return 12.0;
    final hours = cullRadiusDeg / 15.0 / cosDec;
    return hours >= 12.0 ? 12.0 : hours;
  }

  /// Build a cull context for the given view state and canvas size.
  ///
  /// Objects are always culled in the equatorial frame (their RA/Dec is passed
  /// to [isCulled]), so in [SkyViewMode.horizontal] the alt/az view center is
  /// first converted back to equatorial via [lstHours]. Angular distance is
  /// frame-invariant, so this yields the same cull cone the horizontal
  /// projection actually shows. [lstHours] is required only in horizontal mode.
  factory _CullContext.build(
    SkyViewState viewState,
    Size size, {
    double? lstHours,
    double latitudeDeg = 0,
  }) {
    double centerRaDeg;
    double centerDecDeg;
    if (viewState.viewMode == SkyViewMode.horizontal) {
      final (ra, dec) = AstronomyCalculations.horizontalToEquatorial(
        altDeg: viewState.centerAltitude,
        azDeg: viewState.centerAz,
        latitudeDeg: latitudeDeg,
        lstHours: lstHours ?? 0,
      );
      centerRaDeg = ra;
      centerDecDeg = dec;
    } else {
      centerRaDeg = viewState.centerRA * 15;
      centerDecDeg = viewState.centerDec;
    }
    final raRad = centerRaDeg * (math.pi / 180);
    final decRad = centerDecDeg * (math.pi / 180);
    final cosDec = math.cos(decRad);
    final cx = cosDec * math.cos(raRad);
    final cy = cosDec * math.sin(raRad);
    final cz = math.sin(decRad);

    // The visible radius is half the diagonal FOV. The on-screen scale uses
    // min(width,height); the diagonal can therefore reach further than
    // fieldOfView/2 by the aspect diagonal ratio. Add a fixed angular margin
    // (and a relative one) so off-screen glows/labels that bleed in are kept.
    final minSide = math.min(size.width, size.height);
    final diag = math.sqrt(size.width * size.width + size.height * size.height);
    final diagonalFovHalf =
        viewState.fieldOfView / 2 * (minSide > 0 ? diag / minSide : 1.4142);
    // Margin: 25% of the FOV plus 3 degrees, capped so very wide fields still
    // cull the far hemisphere.
    var cullRadiusDeg = diagonalFovHalf * 1.25 + 3.0;
    if (cullRadiusDeg > 175.0) cullRadiusDeg = 175.0;
    final cosCullRadius = math.cos(cullRadiusDeg * (math.pi / 180));
    return _CullContext(
      cx,
      cy,
      cz,
      cosCullRadius,
      centerRaDeg,
      centerDecDeg,
      cullRadiusDeg,
    );
  }

  /// True if the given equatorial coordinate is outside the cull cone and can
  /// be skipped before projection. [raDeg] in degrees, [decDeg] in degrees.
  bool isCulled(double raDeg, double decDeg) {
    final raRad = raDeg * (math.pi / 180);
    final decRad = decDeg * (math.pi / 180);
    final cosD = math.cos(decRad);
    final ox = cosD * math.cos(raRad);
    final oy = cosD * math.sin(raRad);
    final oz = math.sin(decRad);
    final dot = ox * cx + oy * cy + oz * cz;
    return dot < cosCullRadius;
  }
}

/// Per-pose projected-position cache.
///
/// Maps a catalog object to its projected screen [Offset] for a single pose
/// (centerRA, centerDec, FOV, rotation, projection, canvas size). When the
/// pose is unchanged between paints the cached offsets are reused, so the
/// overlay's bright-star pass and momentum frames avoid recomputing the
/// projection trig.
///
/// The cache is keyed by the object reference itself. Star/DeepSkyObject use
/// identity equality, so the underlying map resolves any hash-bucket
/// collisions via `identical` — there is no risk of one object reading
/// another's cached offset.
class _ProjectionCache {
  final Map<Object, Offset?> _entries = <Object, Offset?>{};

  double _centerRA = double.nan;
  double _centerDec = double.nan;
  double _fov = double.nan;
  double _rotation = double.nan;
  SkyProjection _projection = SkyProjection.stereographic;
  SkyViewMode _viewMode = SkyViewMode.equatorial;
  double _centerAz = double.nan;
  double _centerAltitude = double.nan;
  double _lst = double.nan;
  Size _size = Size.zero;
  bool _valid = false;

  /// Ensure the cache matches the given pose; clear it if the pose changed.
  ///
  /// In [SkyViewMode.horizontal] the projected screen position of a fixed
  /// RA/Dec object changes as sidereal time advances, so [lstHours] is part of
  /// the pose key (null in equatorial mode, where it never participates).
  void ensurePose(SkyViewState viewState, Size size, double? lstHours) {
    final lst = lstHours ?? double.nan;
    if (_valid &&
        _centerRA == viewState.centerRA &&
        _centerDec == viewState.centerDec &&
        _fov == viewState.fieldOfView &&
        _rotation == viewState.rotation &&
        _projection == viewState.projection &&
        _viewMode == viewState.viewMode &&
        _centerAz == viewState.centerAz &&
        _centerAltitude == viewState.centerAltitude &&
        (_lst == lst || (_lst.isNaN && lst.isNaN)) &&
        _size == size) {
      return;
    }
    _entries.clear();
    _centerRA = viewState.centerRA;
    _centerDec = viewState.centerDec;
    _fov = viewState.fieldOfView;
    _rotation = viewState.rotation;
    _projection = viewState.projection;
    _viewMode = viewState.viewMode;
    _centerAz = viewState.centerAz;
    _centerAltitude = viewState.centerAltitude;
    _lst = lst;
    _size = size;
    _valid = true;
  }

  /// How many objects this cache is holding a strong reference to.
  int get entryCount => _entries.length;

  bool contains(Object key) => _entries.containsKey(key);
  Offset? get(Object key) => _entries[key];
  void put(Object key, Offset? value) {
    _entries[key] = value;
  }

  void clear() {
    _entries.clear();
    _valid = false;
  }
}

/// Enhanced sky rendering painter
