// ignore_for_file: unused_element, unused_field

part of '../sky_renderer.dart';

extension _SkyCanvasPainterHorizonLayers on SkyCanvasPainter {
  /// Altitude (degrees) of the view center.
  ///
  /// Every caller is a horizontal-frame layer (ground plane, horizon glow,
  /// light-pollution dome — see `_paint`), and in [SkyViewMode.horizontal] the
  /// center IS an alt/az point. `centerRA` / `centerDec` hold the *preserved
  /// inactive* equatorial pose there (see [SkyViewState]), so deriving the
  /// altitude from them would place these layers at the altitude of an
  /// unrelated sky point — in practice a ground band slapped across the upper
  /// sky in the one mode whose whole purpose is "the sky from where I stand".
  double get _viewCenterAltitudeDeg => viewState.centerAltitude;

  /// Screen Y of altitude [targetAltDeg] for a view centered at [centerAltDeg].
  ///
  /// Uses the painter's own pixels-per-degree ([scale] = `min(w, h) / fov`)
  /// rather than `height / fov`: the two agree only on a landscape canvas, so
  /// `height / fov` misplaces the horizon on every portrait layout. The offset
  /// is clamped to +/-1.5 half-heights so an extreme pose cannot produce
  /// runaway rect coordinates.
  double _altitudeScreenY(
    Size size,
    double scale,
    double centerAltDeg, [
    double targetAltDeg = 0.0,
  ]) {
    final halfHeight = size.height / 2;
    final offsetPx = ((centerAltDeg - targetAltDeg) * scale).clamp(
      -1.5 * halfHeight,
      1.5 * halfHeight,
    );
    return halfHeight + offsetPx;
  }

  /// True when the ground the observer is standing on is between them and the
  /// object at [raDeg] / [decDeg].
  ///
  /// Only meaningful where the ground is actually depicted: the horizontal frame
  /// with the ground plane on. The equatorial star atlas draws no terrain, so
  /// nothing is occluded there and this returns false (which also leaves the
  /// committed equatorial render goldens untouched).
  ///
  /// The ground fill is painted *after* the sky objects in the horizontal
  /// frame, so a below-horizon star's dot is already hidden — but the label
  /// passes run after the ground, so without this check their text prints over
  /// the terrain. That is how a view looking 12 deg BELOW the horizon shows
  /// 'Fomalhaut', 'Alnair', 'GRUS' and 'TUCANA' as named,
  /// apparently-observable objects, and at midday 'CRUX' and 'CENTAURUS' —
  /// never visible from 40N at all.
  ///
  /// Call sites are label passes (a few dozen objects a frame), not the hot
  /// per-star sprite loop, so the trig here is not on the critical path.
  bool _isBehindGround(double raDeg, double decDeg) {
    if (viewState.viewMode != SkyViewMode.horizontal) return false;
    if (!config.showGroundPlane) return false;

    final (alt, az) = AstronomyCalculations.equatorialToHorizontal(
      raDeg: raDeg,
      decDeg: decDeg,
      latitudeDeg: latitude,
      lstHours: _lstHours,
    );

    // A custom terrain profile raises the effective horizon per azimuth.
    final profile = horizonAltitudes;
    if (profile != null && profile.isNotEmpty) {
      final idx = az.round() % 360;
      final floor = idx < profile.length ? profile[idx] : 0.0;
      return alt < floor;
    }
    return alt < 0;
  }

  /// Draw the ground fill and, for custom horizon profiles, the horizon line.
  ///
  /// HORIZONTAL frame only. The ground fill is a horizontal screen band placed
  /// by the view centre's altitude, which only describes the horizon in the
  /// frame where screen-up is altitude; the equatorial frame draws no ground
  /// at all and calls [_drawHorizon] directly for the profile line (see
  /// `_paint`).
  void _drawGroundAndHorizon(
    Canvas canvas,
    Size size,
    Offset center,
    double scale,
  ) {
    if (config.showGroundPlane) {
      _drawGroundPlane(canvas, size, center, scale);
    }
    if (config.showHorizon) {
      _drawHorizon(canvas, size, center, scale);
    }
  }

  void _drawHorizon(Canvas canvas, Size size, Offset center, double scale) {
    // For flat horizons the ground-plane gradient transition IS the horizon
    // indicator -- drawing an explicit stroke line creates a hard visible edge
    // that looks unnatural.  Only draw a faint line for custom horizon profiles
    // (terrain outlines) where the irregular shape needs a subtle guide.

    if (horizonAltitudes == null || horizonAltitudes!.isEmpty) {
      // Flat horizon: no stroke line.  The ground-plane blend handles it.
      return;
    }

    // Custom horizon profile: draw as a very subtle polyline following the
    // terrain so the user can see where trees/buildings clip the sky.
    final paint = _PaintCache.getHorizonPaint(
      config.horizonColor.withValues(
        alpha: (config.horizonColor.a * 0.4).clamp(0.0, 1.0),
      ),
    );

    // Memoized per paint (see [_lstHours]).
    final lst = _lstHours;

    final path = Path();
    var firstPoint = true;
    const step = 5.0; // 5-degree azimuth steps for smooth line

    for (var az = 0.0; az <= 360.0; az += step) {
      final azIdx = az.round() % 360;
      final horizonAlt = (azIdx < horizonAltitudes!.length)
          ? horizonAltitudes![azIdx]
          : 0.0;

      final (ra, dec) = AstronomyCalculations.horizontalToEquatorial(
        altDeg: horizonAlt,
        azDeg: az,
        latitudeDeg: latitude,
        lstHours: lst,
      );

      final offset = _celestialToScreen(
        CelestialCoordinate(ra: ra / 15, dec: dec),
        center,
        scale,
      );

      if (offset != null && _isInView(offset, size)) {
        if (firstPoint) {
          path.moveTo(offset.dx, offset.dy);
          firstPoint = false;
        } else {
          path.lineTo(offset.dx, offset.dy);
        }
      } else {
        firstPoint = true;
      }
    }

    canvas.drawPath(path, paint);
  }

  /// Draw ground plane below the horizon with gradient.
  /// When a custom horizon profile is set, fills below the profile curve.
  /// Uses simple linear approximation based on view altitude for flat horizons.
  ///
  /// The ground plane starts fully transparent well above the horizon and
  /// gradually fades to opaque ground color below, so the transition from
  /// sky to ground is seamless -- no visible horizon line or hard edge.
  void _drawGroundPlane(Canvas canvas, Size size, Offset center, double scale) {
    if (!config.showGroundPlane) return;

    // Memoized per paint (see [_lstHours]).
    final lst = _lstHours;

    if (horizonAltitudes != null && horizonAltitudes!.isNotEmpty) {
      // Custom horizon: fill below the profile as a polygon
      _drawCustomHorizonGroundPlane(canvas, size, center, scale, lst);
      return;
    }

    // Flat horizon: original fast path
    final centerAlt = _viewCenterAltitudeDeg;

    final horizonY = _altitudeScreenY(size, scale, centerAlt);

    if (horizonY >= size.height) return;

    if (horizonY <= 0) {
      // Looking entirely below the horizon: solid ground.
      final paint = _PaintCache.getGroundPaint(config.groundColorDark);
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);
      return;
    }

    // Compute the sky's horizon color so the ground blend starts from the
    // same hue that the sky gradient ends at -- no color discontinuity.
    final sunAlt = AstronomyCalculations.sunAltitude(
      dt: observationTime,
      latitudeDeg: latitude,
      longitudeDeg: longitude,
    );
    final (_, skyHorizonColor) = _getTwilightColors(sunAlt);

    // Blend zone: how far ABOVE the horizon the ground starts fading in.
    //
    // The blend must stay proportional to the window: a low upper clamp (180px
    // on a 1440-tall window) compresses the whole sky-to-ground transition into
    // ~12% of the height and reads as a horizontal seam rather than a horizon.
    // The floor still protects small windows.
    final blendZone = (size.height * 0.20).clamp(60.0, 460.0);
    final groundTop = horizonY - blendZone;
    final groundRect = Rect.fromLTRB(0, groundTop, size.width, size.height);

    // The fraction of the gradient rect height where the actual horizon sits.
    final totalHeight = size.height - groundTop;
    final horizonFraction = (horizonY - groundTop) / totalHeight;

    if (qualityConfig.groundPlaneDetail <= 0.0) {
      // Low-detail mode: simple transparent-to-opaque fade using ground color.
      // Still uses the wide blend zone for a smooth edge.
      final gradient = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          config.groundColorDark.withValues(alpha: 0.0),
          config.groundColorDark.withValues(alpha: 0.5),
          config.groundColorDark,
        ],
        stops: [0.0, horizonFraction, (horizonFraction + 0.15).clamp(0.0, 1.0)],
      );
      final paint = Paint()..shader = gradient.createShader(groundRect);
      canvas.drawRect(groundRect, paint);
    } else {
      // High-detail mode: blend from sky horizon color through a warm
      // intermediate to the dark ground.  The top of the gradient is fully
      // transparent sky-horizon color, becoming opaque at the horizon, then
      // transitioning through the ground palette below.
      //
      // Build a smooth multi-stop gradient:
      //   0.0               : fully transparent (sky shows through)
      //   horizonFraction/2 : very faint tint of sky-horizon color
      //   horizonFraction   : sky-horizon color at moderate opacity (the "seam")
      //   below horizon     : blends to ground colors
      final midBlend = (horizonFraction * 0.5).clamp(0.0, 1.0);
      final belowHorizon1 = (horizonFraction + (1.0 - horizonFraction) * 0.25)
          .clamp(0.0, 1.0);
      final belowHorizon2 = (horizonFraction + (1.0 - horizonFraction) * 0.55)
          .clamp(0.0, 1.0);

      // Blend sky-horizon color toward the ground-light color for the seam
      // so there is never a jarring hue shift.
      final seamColor = Color.lerp(
        skyHorizonColor,
        config.groundColorLight,
        0.35,
      )!;

      final gradient = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          skyHorizonColor.withValues(alpha: 0.0),
          skyHorizonColor.withValues(alpha: 0.06),
          seamColor.withValues(alpha: 0.42),
          config.groundColorLight,
          config.groundColorDark,
        ],
        stops: [0.0, midBlend, horizonFraction, belowHorizon1, belowHorizon2],
      );

      final paint = Paint()..shader = gradient.createShader(groundRect);
      canvas.drawRect(groundRect, paint);

      // No stroke line at the horizon -- the gradient transition IS the
      // horizon.  A visible line looks artificial.
    }
  }

  /// Draw ground plane following custom horizon profile.
  /// Builds a filled polygon from horizon profile points down to screen bottom.
  /// Uses the same sky-matching gradient approach as the flat horizon path
  /// so the ground blends seamlessly with the sky.
  void _drawCustomHorizonGroundPlane(
    Canvas canvas,
    Size size,
    Offset center,
    double scale,
    double lst,
  ) {
    final path = Path();
    const step = 5.0;

    // Collect screen positions along the custom horizon
    final horizonPoints = <Offset>[];

    for (var az = 0.0; az <= 360.0; az += step) {
      final azIdx = az.round() % 360;
      final horizonAlt = (azIdx < horizonAltitudes!.length)
          ? horizonAltitudes![azIdx]
          : 0.0;

      final (ra, dec) = AstronomyCalculations.horizontalToEquatorial(
        altDeg: horizonAlt,
        azDeg: az,
        latitudeDeg: latitude,
        lstHours: lst,
      );

      final offset = _celestialToScreen(
        CelestialCoordinate(ra: ra / 15, dec: dec),
        center,
        scale,
      );

      if (offset != null) {
        // Clamp x to screen bounds for the fill
        final clampedX = offset.dx.clamp(-100.0, size.width + 100.0);
        final clampedY = offset.dy.clamp(-100.0, size.height + 200.0);
        horizonPoints.add(Offset(clampedX, clampedY));
      }
    }

    if (horizonPoints.isEmpty) {
      // If no horizon points are visible, check if we're looking entirely below
      final centerAlt = _viewCenterAltitudeDeg;
      if (centerAlt < 0) {
        // Looking below horizon, fill entire screen
        final paint = _PaintCache.getGroundPaint(config.groundColorDark);
        canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);
      }
      return;
    }

    // Build fill polygon: horizon points, then close down to screen bottom
    path.moveTo(horizonPoints.first.dx, horizonPoints.first.dy);
    for (var i = 1; i < horizonPoints.length; i++) {
      path.lineTo(horizonPoints[i].dx, horizonPoints[i].dy);
    }
    // Close down to bottom-right, then bottom-left
    path.lineTo(size.width + 100, size.height + 100);
    path.lineTo(-100, size.height + 100);
    path.close();

    // Compute the sky's horizon color for seamless blending
    final sunAlt = AstronomyCalculations.sunAltitude(
      dt: observationTime,
      latitudeDeg: latitude,
      longitudeDeg: longitude,
    );
    final (_, skyHorizonColor) = _getTwilightColors(sunAlt);

    // Draw the fill
    if (qualityConfig.groundPlaneDetail <= 0.0) {
      // Low-detail: use a simple gradient that still fades smoothly
      var topY = size.height;
      for (final pt in horizonPoints) {
        if (pt.dy < topY) topY = pt.dy;
      }
      final blendZone = (size.height * 0.20).clamp(30.0, 180.0);
      final gradientTop = topY - blendZone;
      final groundRect = Rect.fromLTRB(0, gradientTop, size.width, size.height);
      final horizonFraction =
          (topY - gradientTop) / (size.height - gradientTop);

      final gradient = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          config.groundColorDark.withValues(alpha: 0.0),
          config.groundColorDark.withValues(alpha: 0.5),
          config.groundColorDark,
        ],
        stops: [0.0, horizonFraction, (horizonFraction + 0.15).clamp(0.0, 1.0)],
      );

      final paint = Paint()..shader = gradient.createShader(groundRect);
      canvas.drawPath(path, paint);
    } else {
      // High-detail: match the sky horizon color and fade smoothly.
      var topY = size.height;
      for (final pt in horizonPoints) {
        if (pt.dy < topY) topY = pt.dy;
      }
      final blendZone = (size.height * 0.20).clamp(30.0, 180.0);
      final gradientTop = topY - blendZone;

      final groundRect = Rect.fromLTRB(0, gradientTop, size.width, size.height);
      final totalHeight = size.height - gradientTop;
      final horizonFraction = (topY - gradientTop) / totalHeight;

      final midBlend = (horizonFraction * 0.5).clamp(0.0, 1.0);
      final belowHorizon1 = (horizonFraction + (1.0 - horizonFraction) * 0.25)
          .clamp(0.0, 1.0);
      final belowHorizon2 = (horizonFraction + (1.0 - horizonFraction) * 0.55)
          .clamp(0.0, 1.0);

      final seamColor = Color.lerp(
        skyHorizonColor,
        config.groundColorLight,
        0.35,
      )!;

      final gradient = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          skyHorizonColor.withValues(alpha: 0.0),
          skyHorizonColor.withValues(alpha: 0.10),
          seamColor.withValues(alpha: 0.55),
          config.groundColorLight,
          config.groundColorDark,
        ],
        stops: [0.0, midBlend, horizonFraction, belowHorizon1, belowHorizon2],
      );

      final paint = Paint()..shader = gradient.createShader(groundRect);
      canvas.drawPath(path, paint);

      // No glow stroke line -- the gradient handles the transition.
    }
  }

  /// Draw light pollution dome effect (quality mode only)
  /// Creates a warm orange-white wash near the horizon that fades toward zenith.
  /// Uses a smooth vertical gradient instead of discrete stroke bands so
  /// there are no visible banding artifacts near the horizon.
  /// Intensity and extent are scaled by Bortle class (1-9):
  ///   Bortle 1-2: virtually no dome
  ///   Bortle 4-5: moderate suburban glow
  ///   Bortle 8-9: heavy urban wash extending high overhead
  void _drawLightPollutionDome(
    Canvas canvas,
    Size size,
    Offset center,
    double scale,
  ) {
    // Bortle 1-2 produces negligible light pollution
    if (bortleClass <= 2) return;

    // Get the altitude of the view center
    final centerAlt = _viewCenterAltitudeDeg;

    // Scale factor based on Bortle class (0.0 at Bortle 2, 1.0 at Bortle 9)
    final bortleScale = (bortleClass - 2).clamp(0, 7) / 7.0;

    // Light pollution color - warm orange-white, shifts more orange at higher Bortle
    final pollutionColor = Color.lerp(
      const Color(0xFFFFF5E0), // subtle warm white (suburban)
      const Color(0xFFFFCC80), // stronger orange (urban)
      bortleScale,
    )!;

    // The dome extends from the horizon up to maxAlt degrees
    final maxAlt = 20.0 + bortleScale * 40.0; // 20-60 degrees

    // Calculate screen Y for the horizon (alt = 0) and the top of the dome
    final horizonY = _altitudeScreenY(size, scale, centerAlt);
    final domeTopY = _altitudeScreenY(size, scale, centerAlt, maxAlt);

    // Skip if entirely off screen
    if (horizonY < -50 && domeTopY < -50) return;
    if (horizonY > size.height + 50 && domeTopY > size.height + 50) return;

    final domeRect = Rect.fromLTRB(0, domeTopY, size.width, horizonY);
    if (domeRect.height <= 0) return;

    // Base opacity scales with Bortle: 0.03 at Bortle 3 up to 0.18 at Bortle 9
    final baseOpacity = 0.03 + bortleScale * 0.15;

    // Use a smooth multi-stop gradient from top (transparent) to horizon
    // (peak opacity). The falloff is quadratic, approximated by 4 stops.
    final gradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        pollutionColor.withValues(alpha: 0.0),
        pollutionColor.withValues(alpha: baseOpacity * 0.04),
        pollutionColor.withValues(alpha: baseOpacity * 0.20),
        pollutionColor.withValues(alpha: baseOpacity * 0.55),
        pollutionColor.withValues(alpha: baseOpacity),
      ],
      stops: const [0.0, 0.3, 0.55, 0.80, 1.0],
    );

    final paint = Paint()..shader = gradient.createShader(domeRect);
    if (qualityConfig.useBlurEffects) {
      paint.maskFilter = _PaintCache.getBlurFilter(10);
    }
    canvas.drawRect(domeRect, paint);
  }

  /// Draw a subtle atmospheric glow above the horizon.
  /// Instead of discrete stroke bands (which can create visible banding), this
  /// uses a single vertical gradient rect that fades smoothly from the horizon
  /// upward, simulating the natural sky-brightening near the horizon.
  void _drawHorizonGlow(Canvas canvas, Size size, Offset center, double scale) {
    // Get the altitude of the view center
    final centerAlt = _viewCenterAltitudeDeg;

    // Calculate sun altitude to determine glow color
    final sunAlt = AstronomyCalculations.sunAltitude(
      dt: observationTime,
      latitudeDeg: latitude,
      longitudeDeg: longitude,
    );

    // Determine glow color based on twilight state
    Color glowColor;
    if (sunAlt <= -18) {
      glowColor = const Color(0xFF1A2030);
    } else if (sunAlt <= -6) {
      final t = ((sunAlt + 18) / 12).clamp(0.0, 1.0);
      glowColor = Color.lerp(
        const Color(0xFF1A2030),
        const Color(0xFF3A2840),
        t,
      )!;
    } else if (sunAlt <= 0) {
      final t = ((sunAlt + 6) / 6).clamp(0.0, 1.0);
      glowColor = Color.lerp(
        const Color(0xFF3A2840),
        const Color(0xFF604030),
        t,
      )!;
    } else {
      glowColor = const Color(0xFF706050);
    }

    // Calculate screen Y for altitude 0 (horizon) and the glow extent
    // (approximately 20 degrees above horizon).
    const glowExtentDeg = 20.0;
    final horizonY = _altitudeScreenY(size, scale, centerAlt);
    final glowTopY = _altitudeScreenY(size, scale, centerAlt, glowExtentDeg);

    // Both off screen? Nothing to draw.
    if (horizonY < -50 && glowTopY < -50) return;
    if (horizonY > size.height + 50 && glowTopY > size.height + 50) return;

    // Draw a single gradient rect from the glow top down to the horizon.
    // The gradient goes from fully transparent at the top to the peak glow
    // opacity at the horizon, with a smooth curve via multiple stops.
    final glowRect = Rect.fromLTRB(0, glowTopY, size.width, horizonY);

    if (glowRect.height <= 0) return;

    final peakOpacity = sunAlt <= -18 ? 0.06 : (sunAlt <= 0 ? 0.10 : 0.12);
    final gradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        glowColor.withValues(alpha: 0.0),
        glowColor.withValues(alpha: peakOpacity * 0.15),
        glowColor.withValues(alpha: peakOpacity * 0.45),
        glowColor.withValues(alpha: peakOpacity),
      ],
      stops: const [0.0, 0.4, 0.75, 1.0],
    );

    final paint = Paint()..shader = gradient.createShader(glowRect);
    if (qualityConfig.useBlurEffects) {
      // Apply a soft blur so the glow is diffuse, not sharp-edged.
      paint.maskFilter = _PaintCache.getBlurFilter(12);
    }
    canvas.drawRect(glowRect, paint);
  }
}
