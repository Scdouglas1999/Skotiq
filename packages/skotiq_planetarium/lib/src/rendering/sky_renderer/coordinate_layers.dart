// ignore_for_file: unused_element, unused_field

part of '../sky_renderer.dart';

extension _SkyCanvasPainterCoordinateLayers on SkyCanvasPainter {
  /// "Nice" grid spacings in degrees, coarse to fine. Chosen so labels stay
  /// readable (whole degrees and common sub-degree fractions).
  static const List<double> _decSpacingLadderDeg = [
    30.0,
    15.0,
    10.0,
    5.0,
    2.0,
    1.0,
    0.5,
    0.25,
    0.1,
  ];

  /// "Nice" right-ascension spacings in hours: 2h, 1h, 30m, 15m, 10m, 5m, 2m,
  /// 1m, 30s, 10s.
  static const List<double> _raSpacingLadderHours = [
    2.0,
    1.0,
    0.5,
    0.25,
    1.0 / 6.0,
    1.0 / 12.0,
    1.0 / 30.0,
    1.0 / 60.0,
    1.0 / 120.0,
    1.0 / 360.0,
  ];

  /// Pick the coarsest spacing from [ladder] that is still finer than [target],
  /// so roughly a handful of grid lines cross the field at any zoom.
  static double _chooseSpacing(List<double> ladder, double target) {
    for (final s in ladder) {
      if (s <= target) return s;
    }
    return ladder.last;
  }

  void _drawEquatorialGrid(
    Canvas canvas,
    Size size,
    Offset center,
    double scale,
  ) {
    // Use cached paint object instead of creating new one
    final paint = _PaintCache.getGridPaint(config.gridColor);

    final fov = viewState.fieldOfView;
    final cull = _cull!;

    // Grid spacing and sampling step both scale continuously with the field.
    //
    // A segment is only emitted between two CONSECUTIVE on-screen samples, so
    // a fixed ladder (0.25h of RA, 5 deg of declination) leaves consecutive
    // samples screens apart below a ~4 deg field and the grid stops being drawn
    // at all — across the whole range an imager works in.
    final targetSpacingDeg = fov / 4.0;
    final decSpacing = _chooseSpacing(_decSpacingLadderDeg, targetSpacingDeg);

    // RA lines converge with declination, so the hour spacing that yields the
    // same on-sky separation depends on where we are looking.
    final cosCenterDec = math
        .cos(cull.centerDecDeg * SkyCanvasPainter._deg2rad)
        .abs()
        .clamp(0.02, 1.0);
    final raSpacing = _chooseSpacing(
      _raSpacingLadderHours,
      targetSpacingDeg / 15.0 / cosCenterDec,
    );

    // Sample finely enough that a great circle reads as a curve, but never so
    // finely that a narrow field walks the whole sphere.
    final decStep = (fov / 8.0).clamp(0.01, 5.0);
    final raStep = (decStep / 15.0 / cosCenterDec).clamp(1.0 / 3600.0, 0.5);

    // Only the window that can be visible is walked (see [_CullContext]); the
    // per-sample dot-product cull then rejects the corners of that window.
    final (minDec, maxDec) = cull.decWindow;
    final raHalf = cull.raHalfWindowHours;
    final centerRaHours = cull.centerRaDeg / 15.0;

    // Draw RA lines (constant right ascension, running in declination).
    final firstRaIndex = ((centerRaHours - raHalf) / raSpacing).floor();
    final lastRaIndex = ((centerRaHours + raHalf) / raSpacing).ceil();
    for (var i = firstRaIndex; i <= lastRaIndex; i++) {
      var ra = i * raSpacing;
      ra = ra % 24.0;
      if (ra < 0) ra += 24.0;
      final raDeg = ra * 15;

      final path = Path();
      var firstPoint = true;
      for (var dec = minDec; dec <= maxDec; dec += decStep) {
        if (cull.isCulled(raDeg, dec)) {
          firstPoint = true;
          continue;
        }
        final offset = _celestialToScreen(
          CelestialCoordinate(ra: ra, dec: dec),
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

    // Draw Dec lines (constant declination, running in right ascension).
    final firstDecIndex = (minDec / decSpacing).floor();
    final lastDecIndex = (maxDec / decSpacing).ceil();
    for (var i = firstDecIndex; i <= lastDecIndex; i++) {
      final dec = i * decSpacing;
      if (dec <= -90 || dec >= 90) continue;

      final path = Path();
      var firstPoint = true;
      for (var raOffset = -raHalf; raOffset <= raHalf; raOffset += raStep) {
        var ra = (centerRaHours + raOffset) % 24.0;
        if (ra < 0) ra += 24.0;
        if (cull.isCulled(ra * 15, dec)) {
          firstPoint = true;
          continue;
        }
        final offset = _celestialToScreen(
          CelestialCoordinate(ra: ra, dec: dec),
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

    // Labels are drawn at every zoom: they follow the view center, and at a
    // framing field the coordinate readout is more useful, not less.
    _drawGridLabels(canvas, size, center, scale, raSpacing, decSpacing);
  }

  void _drawGridLabels(
    Canvas canvas,
    Size size,
    Offset center,
    double scale,
    double raSpacing,
    double decSpacing,
  ) {
    final textStyle = TextStyle(
      color: config.gridColor.withValues(alpha: 0.7),
      fontSize: 10,
      fontWeight: FontWeight.w500,
    );
    final cull = _cull!;
    final centerRaHours = cull.centerRaDeg / 15.0;

    // Label each line where it passes closest to the view center, rather than
    // on the celestial equator / the RA 0h meridian: those two reference lines
    // are usually nowhere near the field, so anything but a very wide view
    // would carry no labels at all.
    final (minDec, maxDec) = cull.decWindow;
    final raHalf = cull.raHalfWindowHours;

    // RA labels, placed at the declination of the view center.
    final firstRaIndex = ((centerRaHours - raHalf) / raSpacing).floor();
    final lastRaIndex = ((centerRaHours + raHalf) / raSpacing).ceil();
    for (var i = firstRaIndex; i <= lastRaIndex; i++) {
      var ra = i * raSpacing;
      ra = ra % 24.0;
      if (ra < 0) ra += 24.0;

      final offset = _celestialToScreen(
        CelestialCoordinate(ra: ra, dec: cull.centerDecDeg),
        center,
        scale,
      );
      if (offset == null || !_isInView(offset, size)) continue;

      final textPainter = _TextCache.get(
        _formatRaLabel(ra, raSpacing),
        textStyle,
      );
      final pos = _labelManager.findPlacement(
        offset + Offset(-textPainter.width / 2, 4),
        Size(textPainter.width, textPainter.height),
        size,
      );
      if (pos != null) textPainter.paint(canvas, pos);
    }

    // Dec labels, placed at the right ascension of the view center.
    final firstDecIndex = (minDec / decSpacing).floor();
    final lastDecIndex = (maxDec / decSpacing).ceil();
    for (var i = firstDecIndex; i <= lastDecIndex; i++) {
      final dec = i * decSpacing;
      if (dec <= -90 || dec >= 90) continue;

      final offset = _celestialToScreen(
        CelestialCoordinate(ra: centerRaHours, dec: dec),
        center,
        scale,
      );
      if (offset == null || !_isInView(offset, size)) continue;

      final textPainter = _TextCache.get(
        _formatDecLabel(dec, decSpacing),
        textStyle,
      );
      final pos = _labelManager.findPlacement(
        offset + Offset(4, -textPainter.height / 2),
        Size(textPainter.width, textPainter.height),
        size,
      );
      if (pos != null) textPainter.paint(canvas, pos);
    }
  }

  /// Format a right ascension, carrying only as much precision as [spacing]
  /// makes meaningful (whole hours at a wide field, minutes and then seconds as
  /// the grid tightens).
  static String _formatRaLabel(double raHours, double spacing) {
    if (spacing >= 1.0) return '${raHours.round()}h';
    final totalSeconds = (raHours * 3600).round();
    final h = totalSeconds ~/ 3600;
    final m = (totalSeconds % 3600) ~/ 60;
    final s = totalSeconds % 60;
    if (spacing >= 1.0 / 60.0) {
      return s == 0 && spacing >= 1.0 / 60.0 && m == 0 ? '${h}h' : '${h}h${m}m';
    }
    return '${h}h${m}m${s}s';
  }

  /// Format a declination, carrying arcminutes once the grid is finer than a
  /// degree.
  static String _formatDecLabel(double decDeg, double spacing) {
    final sign = decDeg < 0 ? '-' : '+';
    final abs = decDeg.abs();
    if (spacing >= 1.0) return '$sign${abs.round()}°';
    final totalMinutes = (abs * 60).round();
    final d = totalMinutes ~/ 60;
    final m = totalMinutes % 60;
    return "$sign$d°$m'";
  }

  void _drawZenithMarker(
    Canvas canvas,
    Size size,
    Offset center,
    double scale,
  ) {
    // Calculate zenith position (altitude 90 degrees)
    // Memoized per paint (see [_lstHours]).
    final lst = _lstHours;
    final (ra, dec) = AstronomyCalculations.horizontalToEquatorial(
      altDeg: 90.0,
      azDeg: 0.0,
      latitudeDeg: latitude,
      lstHours: lst,
    );

    final zenithPos = _celestialToScreen(
      CelestialCoordinate(ra: ra / 15, dec: dec),
      center,
      scale,
    );
    if (zenithPos == null || !_isInView(zenithPos, size)) return;

    // Draw crosshair - use cached paint
    final paint = _PaintCache.getZenithCrossPaint(
      Colors.white.withValues(alpha: 0.4),
    );

    const length = 12.0;
    canvas.drawLine(
      zenithPos - const Offset(length, 0),
      zenithPos + const Offset(length, 0),
      paint,
    );
    canvas.drawLine(
      zenithPos - const Offset(0, length),
      zenithPos + const Offset(0, length),
      paint,
    );

    // Draw "Z" label - use cached TextPainter
    final textStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.6),
      fontSize: 12,
      fontWeight: FontWeight.bold,
    );
    final labelPaint = _TextCache.get('Z', textStyle);
    labelPaint.paint(
      canvas,
      zenithPos + Offset(length + 4, -labelPaint.height / 2),
    );
  }

  void _drawAltAzGrid(Canvas canvas, Size size, Offset center, double scale) {
    // Use cached paint instead of creating new one each frame
    final paint = _PaintCache.getAltAzPaint(
      config.gridColor.withValues(alpha: 0.3),
    );

    // Memoized per paint (see [_lstHours]).
    final lst = _lstHours;

    // Draw altitude circles
    for (var alt = 0; alt <= 90; alt += 30) {
      final path = Path();
      var firstPoint = true;

      for (var az = 0.0; az <= 360; az += 5) {
        // Convert alt/az to RA/Dec
        final (ra, dec) = AstronomyCalculations.horizontalToEquatorial(
          altDeg: alt.toDouble(),
          azDeg: az,
          latitudeDeg: latitude,
          lstHours: lst,
        );

        // Cull before projecting (ra is in degrees here).
        if (_cull!.isCulled(ra, dec)) {
          firstPoint = true;
          continue;
        }

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
  }

  void _drawEcliptic(Canvas canvas, Size size, Offset center, double scale) {
    // Use cached paint instead of creating new one each frame
    final paint = _PaintCache.getEclipticPaint(config.eclipticColor);

    final path = Path();
    var firstPoint = true;

    // Draw ecliptic as a great circle
    for (var lon = 0.0; lon <= 360; lon += 2) {
      final (ra, dec) = AstronomyCalculations.eclipticToEquatorial(
        lonDeg: lon,
        latDeg: 0,
        obliquityDeg: 23.44,
      );

      if (_cull!.isCulled(ra, dec)) {
        firstPoint = true;
        continue;
      }

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

  void _drawGalacticPlane(
    Canvas canvas,
    Size size,
    Offset center,
    double scale,
  ) {
    final paint = _PaintCache.getGalacticPlanePaint(config.galacticPlaneColor);

    final path = Path();
    var firstPoint = true;

    // Draw galactic equator as a great circle at galactic latitude 0
    for (var lon = 0.0; lon <= 360; lon += 2) {
      final (ra, dec) = AstronomyCalculations.galacticToEquatorial(
        lonDeg: lon,
        latDeg: 0,
      );

      if (_cull!.isCulled(ra, dec)) {
        firstPoint = true;
        continue;
      }

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

    // Draw "Galactic Equator" label at galactic center direction (l=0, b=0)
    final (labelRa, labelDec) = AstronomyCalculations.galacticToEquatorial(
      lonDeg: 0,
      latDeg: 0,
    );
    final labelOffset = _celestialToScreen(
      CelestialCoordinate(ra: labelRa / 15, dec: labelDec),
      center,
      scale,
    );
    if (labelOffset != null && _isInView(labelOffset, size)) {
      final textStyle = TextStyle(
        color: config.galacticPlaneColor.withValues(alpha: 0.8),
        fontSize: 10,
        fontWeight: FontWeight.w500,
      );
      final textPainter = _TextCache.get('Galactic Eq.', textStyle);

      final preferredPos =
          labelOffset + Offset(-textPainter.width / 2, -textPainter.height - 4);
      final labelPos = _labelManager.findPlacement(
        preferredPos,
        Size(textPainter.width, textPainter.height),
        size,
      );
      if (labelPos != null) {
        textPainter.paint(canvas, labelPos);
      }
    }
  }

  void _drawMeridianLine(
    Canvas canvas,
    Size size,
    Offset center,
    double scale,
  ) {
    if (!config.showMeridian) return;

    // Memoized per paint (see [_lstHours]).
    final lst = _lstHours;

    // Draw line from horizon to zenith along the meridian (azimuth 0/180)
    final path = Path();
    var firstPoint = true;

    for (var alt = 0.0; alt <= 90; alt += 2) {
      final (ra, dec) = AstronomyCalculations.horizontalToEquatorial(
        altDeg: alt,
        azDeg: 0.0, // North meridian
        latitudeDeg: latitude,
        lstHours: lst,
      );

      final pos = _celestialToScreen(
        CelestialCoordinate(ra: ra / 15, dec: dec),
        center,
        scale,
      );
      if (pos != null && _isInView(pos, size)) {
        if (firstPoint) {
          path.moveTo(pos.dx, pos.dy);
          firstPoint = false;
        } else {
          path.lineTo(pos.dx, pos.dy);
        }
      } else {
        firstPoint = true;
      }
    }

    // Also draw the south meridian
    firstPoint = true;
    for (var alt = 0.0; alt <= 90; alt += 2) {
      final (ra, dec) = AstronomyCalculations.horizontalToEquatorial(
        altDeg: alt,
        azDeg: 180.0, // South meridian
        latitudeDeg: latitude,
        lstHours: lst,
      );

      final pos = _celestialToScreen(
        CelestialCoordinate(ra: ra / 15, dec: dec),
        center,
        scale,
      );
      if (pos != null && _isInView(pos, size)) {
        if (firstPoint) {
          path.moveTo(pos.dx, pos.dy);
          firstPoint = false;
        } else {
          path.lineTo(pos.dx, pos.dy);
        }
      } else {
        firstPoint = true;
      }
    }

    // Use cached paint instead of creating new one each frame
    final paint = _PaintCache.getMeridianPaint(
      Colors.green.withValues(alpha: 0.4),
    );
    canvas.drawPath(path, paint);
  }
}
