// ignore_for_file: unused_element, unused_field

part of '../sky_renderer.dart';

extension _SkyCanvasPainterBackgroundLayers on SkyCanvasPainter {
  void _drawBackground(Canvas canvas, Size size) {
    // A host is drawing its own sky background beneath this view (survey
    // imagery). Painting the opaque gradient here would hide it, so leave the
    // pixels untouched — the layer underneath is the background this frame.
    if (!paintsOpaqueBackground) return;

    final rect = Rect.fromLTWH(0, 0, size.width, size.height);

    // Check if twilight gradient is enabled
    if (!qualityConfig.enableTwilightGradient) {
      // Simple dark gradient for performance mode - use cached shader
      final shader = _PaintCache.getDarkBackgroundShader(size);
      final paint = _PaintCache.getBackgroundPaint(shader);
      canvas.drawRect(rect, paint);
      return;
    }

    // Calculate sun altitude for twilight determination
    final sunAlt = AstronomyCalculations.sunAltitude(
      dt: observationTime,
      latitudeDeg: latitude,
      longitudeDeg: longitude,
    );

    // Use cached gradient if sun altitude hasn't changed significantly (2-degree bucket)
    if (_backgroundGradientCache.isValid(sunAlt, size)) {
      final paint = _PaintCache.getBackgroundPaint(
        _backgroundGradientCache.verticalShader!,
      );
      canvas.drawRect(rect, paint);
      final radialPaint = _PaintCache.getBackgroundPaint(
        _backgroundGradientCache.radialShader!,
      );
      canvas.drawRect(rect, radialPaint);
      return;
    }

    // Get twilight colors based on sun altitude
    final (zenithColor, horizonColor) = _getTwilightColors(sunAlt);

    // Create vertical gradient
    final gradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [zenithColor, horizonColor],
      stops: const [0.0, 1.0],
    );
    final verticalShader = gradient.createShader(rect);

    // Add a subtle radial darkening toward center for depth
    final radialGradient = RadialGradient(
      center: Alignment.center,
      radius: 1.5,
      colors: [Colors.transparent, zenithColor.withValues(alpha: 0.3)],
    );
    final radialShader = radialGradient.createShader(rect);

    // Cache both shaders
    _backgroundGradientCache.store(verticalShader, radialShader, sunAlt, size);

    final paint = _PaintCache.getBackgroundPaint(verticalShader);
    canvas.drawRect(rect, paint);
    final radialPaint = _PaintCache.getBackgroundPaint(radialShader);
    canvas.drawRect(rect, radialPaint);
  }

  /// Get twilight colors based on sun altitude
  /// Returns (zenithColor, horizonColor) for gradient
  (Color, Color) _getTwilightColors(double sunAltitude) {
    // Astronomical twilight: sun below -18°
    // Nautical twilight: sun between -18° and -12°
    // Civil twilight: sun between -12° and -6°
    // Golden hour: sun between -6° and 0°
    // Day: sun above 0°

    if (sunAltitude <= -18) {
      // Full night - dark blue-black gradient
      return (
        const Color(0xFF0A0A1A), // Zenith: very dark blue
        const Color(0xFF0D0D20), // Horizon: slightly lighter dark blue
      );
    } else if (sunAltitude <= -12) {
      // Nautical twilight - deep blues
      final t = (sunAltitude + 18) / 6; // 0 at -18, 1 at -12
      return (
        Color.lerp(const Color(0xFF0A0A1A), const Color(0xFF0F1028), t)!,
        Color.lerp(const Color(0xFF0D0D20), const Color(0xFF1A1A38), t)!,
      );
    } else if (sunAltitude <= -6) {
      // Civil twilight - navy to deep purple/blue
      final t = (sunAltitude + 12) / 6; // 0 at -12, 1 at -6
      return (
        Color.lerp(const Color(0xFF0F1028), const Color(0xFF1A1A40), t)!,
        Color.lerp(const Color(0xFF1A1A38), const Color(0xFF2D2040), t)!,
      );
    } else if (sunAltitude <= 0) {
      // Golden hour - purple/blue to orange/pink at horizon
      final t = (sunAltitude + 6) / 6; // 0 at -6, 1 at 0
      return (
        Color.lerp(const Color(0xFF1A1A40), const Color(0xFF252050), t)!,
        Color.lerp(const Color(0xFF2D2040), const Color(0xFF4A3048), t)!,
      );
    } else {
      // Daytime (sun above the horizon): keep a dark star-chart sky instead of
      // washing the field out with a bright blue. The planetarium is used as a
      // planning chart, so the full sky (stars / DSOs / constellations) stays
      // readable at any hour rather than vanishing into daylight.
      return (
        const Color(0xFF0A0A1A), // Zenith: very dark blue (same as full night)
        const Color(0xFF0D0D20), // Horizon: slightly lighter dark blue
      );
    }
  }

  void _drawMilkyWay(Canvas canvas, Size size, Offset center, double scale) {
    if (milkyWayPoints == null) return;

    // Check if we can reuse a cached Milky Way Picture.
    // The Milky Way is fixed on the sky, so it only needs redrawing when the view moves.
    final poseLst = viewState.viewMode == SkyViewMode.horizontal
        ? _lstHours
        : null;
    if (_milkyWayCache.isValid(viewState, size, poseLst)) {
      canvas.drawPicture(_milkyWayCache.picture!);
      return;
    }

    // Cache miss: record Milky Way into a Picture
    final recorder = ui.PictureRecorder();
    final recordCanvas = Canvas(recorder);

    // Calculate appropriate blur and point size based on FOV
    final fovFactor = viewState.fieldOfView / 60;
    final blurRadius = (8 * fovFactor).clamp(4.0, 20.0);
    final pointRadius = (3 * fovFactor).clamp(2.0, 8.0);

    // Milky Way color - subtle blue-white glow
    const baseColor = Color(0xFF8090A8);

    // Batch Milky Way points into Float32List groups by intensity bucket
    // to minimize draw calls
    final glowPoints = <double>[];
    final corePoints = <double>[];

    for (final point in milkyWayPoints!) {
      final offset = _celestialToScreen(point.coordinates, center, scale);
      if (offset == null || !_isInView(offset, size)) continue;

      glowPoints.add(offset.dx);
      glowPoints.add(offset.dy);

      if (point.intensity > 0.5) {
        corePoints.add(offset.dx);
        corePoints.add(offset.dy);
      }
    }

    // Draw all glow points as a single batch
    if (glowPoints.isNotEmpty) {
      final glowPaint = _PaintCache.getBlurPaint(
        blurRadius,
        baseColor,
        alpha: 0.12,
      );
      glowPaint.strokeWidth = pointRadius * 4;
      glowPaint.strokeCap = StrokeCap.round;
      recordCanvas.drawRawPoints(
        ui.PointMode.points,
        Float32List.fromList(glowPoints),
        glowPaint,
      );
    }

    // Draw brighter core points as a second batch
    if (corePoints.isNotEmpty) {
      final corePaint = _PaintCache.getBlurPaint(
        blurRadius * 0.5,
        baseColor,
        alpha: 0.18,
      );
      corePaint.strokeWidth = pointRadius * 2;
      corePaint.strokeCap = StrokeCap.round;
      recordCanvas.drawRawPoints(
        ui.PointMode.points,
        Float32List.fromList(corePoints),
        corePaint,
      );
    }

    final picture = recorder.endRecording();
    _milkyWayCache.store(picture, viewState, size, poseLst);

    canvas.drawPicture(picture);
  }
}
