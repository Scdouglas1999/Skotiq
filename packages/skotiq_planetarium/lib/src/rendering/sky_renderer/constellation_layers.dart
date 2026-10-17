// ignore_for_file: unused_element, unused_field

part of '../sky_renderer.dart';

extension _SkyCanvasPainterConstellationLayers on SkyCanvasPainter {
  void _drawConstellationBoundaries(
    Canvas canvas,
    Size size,
    Offset center,
    double scale,
  ) {
    final boundaryPaint = Paint()
      ..color = config.constellationBoundaryColor
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;

    final boundaries = ConstellationBoundaries.all;
    final path = Path();

    // Boundary edges run along constant RA or constant declination, so they are
    // small circles on the sphere, not straight screen lines. Drawing each edge
    // as a single chord between its two projected endpoints cut across the sky:
    // the data contains edges spanning tens of degrees (e.g. Apus runs 4.6h of
    // RA — 69 deg — at a constant Dec of -67.5), and those chords sliced right
    // through the polar region. Subdivide instead, interpolating in RA/Dec so
    // the drawn line follows the actual boundary.
    final stepDeg = (viewState.fieldOfView / 8.0).clamp(0.05, 2.0);

    for (final entry in boundaries.entries) {
      final vertices = entry.value;
      if (vertices.length < 3) continue;

      for (var i = 0; i < vertices.length; i++) {
        final v0 = vertices[i];
        final v1 = vertices[(i + 1) % vertices.length];

        // Take the short way around the 0h/24h seam.
        var dRaHours = v1.ra - v0.ra;
        if (dRaHours > 12) dRaHours -= 24;
        if (dRaHours < -12) dRaHours += 24;
        final dDec = v1.dec - v0.dec;

        // Angular extent, weighted so RA converges toward the poles.
        final meanDecRad = (v0.dec + v1.dec) / 2 * SkyCanvasPainter._deg2rad;
        final raSpanDeg = (dRaHours * 15.0 * math.cos(meanDecRad)).abs();
        final spanDeg = math.sqrt(raSpanDeg * raSpanDeg + dDec * dDec);
        final steps = (spanDeg / stepDeg).ceil().clamp(1, 512);

        Offset? prev;
        for (var s = 0; s <= steps; s++) {
          final t = s / steps;
          var ra = v0.ra + dRaHours * t;
          ra = ra % 24.0;
          if (ra < 0) ra += 24.0;
          final dec = v0.dec + dDec * t;

          if (_cull!.isCulled(ra * 15, dec)) {
            prev = null;
            continue;
          }
          final pt = _celestialToScreen(
            CelestialCoordinate(ra: ra, dec: dec),
            center,
            scale,
          );
          if (pt == null) {
            prev = null;
            continue;
          }

          final start = prev;
          prev = pt;
          if (start == null) continue;
          if (!_isInView(start, size) && !_isInView(pt, size)) continue;

          // Dash along this (short) sub-segment.
          final dx = pt.dx - start.dx;
          final dy = pt.dy - start.dy;
          final length = math.sqrt(dx * dx + dy * dy);
          if (length < 1) continue;

          const dashLength = 4.0;
          const gapLength = 4.0;
          final unitDx = dx / length;
          final unitDy = dy / length;

          var dist = 0.0;
          while (dist < length) {
            final segEnd = math.min(dist + dashLength, length);
            path.moveTo(start.dx + unitDx * dist, start.dy + unitDy * dist);
            path.lineTo(start.dx + unitDx * segEnd, start.dy + unitDy * segEnd);
            dist += dashLength + gapLength;
          }
        }
      }
    }

    canvas.drawPath(path, boundaryPaint);
  }

  void _drawConstellationLines(
    Canvas canvas,
    Size size,
    Offset center,
    double scale,
  ) {
    // Check if we can reuse a cached Picture of constellation lines.
    // Constellation lines are static relative to the sky — they only change
    // when the view moves, so caching saves redrawing hundreds of line segments.
    // The cached geometry is only reusable at the same full pose — including
    // roll, projection, frame and (in the horizontal frame) sidereal time.
    final poseLst = viewState.viewMode == SkyViewMode.horizontal
        ? _lstHours
        : null;
    if (_constellationLineCache.isValid(
      viewState,
      size,
      poseLst,
      constellations.length,
    )) {
      canvas.drawPicture(_constellationLineCache.picture!);
      return;
    }

    // Cache miss: record constellation lines into a Picture
    final recorder = ui.PictureRecorder();
    final recordCanvas = Canvas(recorder);

    final paint = _PaintCache.getConstellationPaint(
      config.constellationLineColor,
    );

    // Batch all lines into a single Path for better performance
    final path = Path();

    for (final constellation in constellations) {
      for (final line in constellation.lines) {
        // Cull a segment only when BOTH endpoints are outside the cull cone;
        // a segment with one endpoint inside can still cross the viewport.
        if (_cull!.isCulled(line.start.raDegrees, line.start.dec) &&
            _cull!.isCulled(line.end.raDegrees, line.end.dec)) {
          continue;
        }
        final start = _celestialToScreen(line.start, center, scale);
        final end = _celestialToScreen(line.end, center, scale);

        if (start != null && end != null) {
          if (_isInView(start, size) || _isInView(end, size)) {
            path.moveTo(start.dx, start.dy);
            path.lineTo(end.dx, end.dy);
          }
        }
      }
    }

    // Single draw call for all constellation lines
    recordCanvas.drawPath(path, paint);

    final picture = recorder.endRecording();
    _constellationLineCache.store(
      picture,
      viewState,
      size,
      poseLst,
      constellations.length,
    );

    // Draw the picture to the real canvas
    canvas.drawPicture(picture);
  }

  void _drawConstellationLabels(
    Canvas canvas,
    Size size,
    Offset center,
    double scale,
  ) {
    final textStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.5),
      fontSize: 10,
      fontWeight: FontWeight.w500,
    );

    for (final constellation in constellations) {
      // A constellation centred below the observer's horizon is not in the sky
      // they are looking at. Printing 'GRUS' or 'CRUX' across the ground was the
      // loudest version of this: those figures are never visible from 40N.
      if (_isBehindGround(
        constellation.center.raDegrees,
        constellation.center.dec,
      )) {
        continue;
      }

      final offset = _celestialToScreen(constellation.center, center, scale);

      if (offset != null && _isInView(offset, size)) {
        // Use cached TextPainter for constellation labels
        final textPainter = _TextCache.get(
          constellation.name.toUpperCase(),
          textStyle,
        );
        // Route through the shared layout manager rather than painting blind.
        // These were the labels most often seen collided with a star or planet
        // name (e.g. "CANIS MINOR" printed through "Procyon"), because the
        // constellation pass was the only label pass that never reserved space.
        final labelPos = _labelManager.findPlacement(
          offset - Offset(textPainter.width / 2, textPainter.height / 2),
          Size(textPainter.width, textPainter.height),
          size,
        );
        if (labelPos == null) continue;
        textPainter.paint(canvas, labelPos);
      }
    }
  }

  void _drawConstellationArt(
    Canvas canvas,
    Size size,
    Offset center,
    double scale,
  ) {
    // Gold/amber fill with 20% opacity
    final fillPaint = Paint()
      ..color =
          const Color(0x33DAA520) // goldenrod at ~20% opacity
      ..style = PaintingStyle.fill;

    // Slightly brighter stroke for figure outlines
    final strokePaint = Paint()
      ..color =
          const Color(0x28DAA520) // goldenrod at ~16% opacity
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    for (final figure in SkyCanvasPainter._constellationArtFigures) {
      // Quick visibility check: find the constellation data to get its center
      final constellationData = constellations
          .where((c) => c.abbreviation == figure.abbreviation)
          .firstOrNull;
      if (constellationData == null) continue;

      final centerOffset = _celestialToScreen(
        constellationData.center,
        center,
        scale,
      );
      if (centerOffset == null) continue;

      // Skip if constellation center is far off-screen (generous margin for large figures)
      if (centerOffset.dx < -size.width ||
          centerOffset.dx > size.width * 2 ||
          centerOffset.dy < -size.height ||
          centerOffset.dy > size.height * 2) {
        continue;
      }

      // Build the Canvas path from the art segments.
      //
      // Any vertex can project to null (the projector rejects anything ~89.4
      // deg or more from the view center). When that happens the current
      // subpath must END — never be continued with a `lineTo` from whatever
      // came before. A `lineTo` into an unopened subpath makes Skia inject an
      // implicit start at (0, 0), which draws the figure as a filled wedge
      // anchored to the canvas corner.
      final path = Path();
      var hasVisiblePoint = false;
      var subpathOpen = false;

      void moveTo(Offset p) {
        path.moveTo(p.dx, p.dy);
        subpathOpen = true;
      }

      /// Extend the current subpath, or start a new one if the previous vertex
      /// was culled.
      void lineOrMoveTo(Offset p) {
        if (subpathOpen) {
          path.lineTo(p.dx, p.dy);
        } else {
          moveTo(p);
        }
      }

      for (final segment in figure.segments) {
        switch (segment) {
          case ArtMoveTo(:final point):
            final screenPt = _celestialToScreen(point, center, scale);
            if (screenPt == null) {
              subpathOpen = false;
              continue;
            }
            moveTo(screenPt);
            if (_isInView(screenPt, size)) hasVisiblePoint = true;
          case ArtLineTo(:final point):
            final screenPt = _celestialToScreen(point, center, scale);
            if (screenPt == null) {
              subpathOpen = false;
              continue;
            }
            lineOrMoveTo(screenPt);
            if (_isInView(screenPt, size)) hasVisiblePoint = true;
          case ArtQuadTo(:final control, :final point):
            final ctrlPt = _celestialToScreen(control, center, scale);
            final endPt = _celestialToScreen(point, center, scale);
            if (endPt == null) {
              subpathOpen = false;
              continue;
            }
            if (ctrlPt != null && subpathOpen) {
              path.quadraticBezierTo(ctrlPt.dx, ctrlPt.dy, endPt.dx, endPt.dy);
            } else {
              // Control point behind the projection, or no open subpath to
              // curve from: fall back to a straight segment / fresh start.
              lineOrMoveTo(endPt);
            }
            if (_isInView(endPt, size)) hasVisiblePoint = true;
          case ArtClose():
            if (subpathOpen) {
              path.close();
              subpathOpen = false;
            }
        }
      }

      // Only draw if at least one point is visible on screen
      if (hasVisiblePoint) {
        canvas.drawPath(path, fillPaint);
        canvas.drawPath(path, strokePaint);
      }
    }
  }
}
