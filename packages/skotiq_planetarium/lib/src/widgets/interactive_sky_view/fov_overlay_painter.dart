part of '../interactive_sky_view.dart';

/// Projects sky coordinates onto the sky view's canvas with the *exact*
/// geometry the star field is drawn with.
///
/// An equipment FOV overlay is how an imager sees where their sensor lands on
/// the sky, so a box that disagrees with the stars is worse than no box at all:
/// it states, falsely, that the frame covers sky it does not. This projector is
/// a term-for-term mirror of `SkyCanvasPainter._projectAroundCenter` — the sign
/// convention (increasing RA runs to the LEFT), the `cos(dec)` foreshortening
/// that falls out of the spherical maths, the back-face cull, all three
/// [SkyProjection] branches, the view rotation, and the
/// [SkyViewMode.horizontal] frame. `test/fov_overlay_projection_test.dart` pins
/// this implementation against the sky painter's own rendered output so the two
/// cannot silently diverge again.
///
/// It is declared in this part file for a mechanical reason: Dart part files
/// cannot declare imports, so `_FOVOverlayPainter` below can only reference
/// symbols the enclosing `interactive_sky_view.dart` library imports. Declaring
/// the projector here makes it a public member of that (exported) library,
/// which is what lets the multi-rig overlay and the standalone FOV overlay
/// painter share this one implementation rather than each carrying a copy.
@immutable
class SkyFovProjector {
  /// The pose the sky is currently drawn at.
  final SkyViewState viewState;

  /// Screen position of the view center, i.e. `Offset(w / 2, h / 2)`.
  final Offset screenCenter;

  /// Screen pixels per degree of sky along the short canvas axis.
  final double pixelsPerDegree;

  /// Observer latitude in degrees. Only read in [SkyViewMode.horizontal].
  final double latitude;

  /// Local sidereal time in hours. Required — and only used — to project a
  /// fixed RA/Dec in [SkyViewMode.horizontal]. Null means "not supplied", in
  /// which case RA/Dec projection in that frame returns null rather than
  /// guessing (see [canProjectSkyCoordinates]).
  final double? lstHours;

  static const double _deg2rad = math.pi / 180;
  static const double _rad2deg = 180 / math.pi;

  const SkyFovProjector({
    required this.viewState,
    required this.screenCenter,
    required this.pixelsPerDegree,
    this.latitude = 0,
    this.lstHours,
  });

  /// Build a projector for a canvas of [size], using the same degrees→pixels
  /// mapping the sky painter uses (`min(w, h) / 2 / (fov / 2)`).
  factory SkyFovProjector.forSize(
    SkyViewState viewState,
    Size size, {
    double latitude = 0,
    double? lstHours,
  }) {
    return SkyFovProjector(
      viewState: viewState,
      screenCenter: Offset(size.width / 2, size.height / 2),
      pixelsPerDegree: scaleFor(size, viewState.fieldOfView),
      latitude: latitude,
      lstHours: lstHours,
    );
  }

  /// Degrees→pixels scale for a canvas of [size] showing [fieldOfViewDeg]
  /// across its short axis. Identical to the sky painter's own scale.
  static double scaleFor(Size size, double fieldOfViewDeg) =>
      math.min(size.width, size.height) / 2 / (fieldOfViewDeg / 2);

  /// Wrap a right-ascension difference into (-12, +12] hours.
  ///
  /// The 0h/24h seam is where naive overlays break: a target at RA 0.2h with
  /// the view at RA 23.9h has a raw difference of -23.7h (-355.5°), which a
  /// flat small-angle overlay scales into a box hundreds of screens away — so
  /// the FOV indicator simply vanishes for M31 and everything else near 0h.
  /// The spherical projection below is immune by construction (only the cosine
  /// and sine of the longitude difference enter it); this helper exists for
  /// callers that need the wrapped separation itself.
  static double normalizeRaDeltaHours(double deltaHours) {
    if (!deltaHours.isFinite) return deltaHours;
    var wrapped = deltaHours % 24;
    if (wrapped > 12) wrapped -= 24;
    if (wrapped <= -12) wrapped += 24;
    return wrapped;
  }

  /// Whether a fixed RA/Dec can be placed at all in the current view mode.
  ///
  /// The horizontal frame needs sidereal time to rotate RA/Dec into alt/az; if
  /// [lstHours] was not supplied, callers must draw nothing rather than fall
  /// back to the equatorial frame, which would put the box somewhere arbitrary.
  bool get canProjectSkyCoordinates =>
      viewState.viewMode != SkyViewMode.horizontal || lstHours != null;

  /// Project a celestial coordinate. Returns null when the point is behind the
  /// projection plane, when the pose is degenerate, or when the inputs are not
  /// finite — the caller must then draw nothing.
  Offset? project(CelestialCoordinate coord) =>
      projectRaDec(coord.ra, coord.dec);

  /// Project an RA (hours) / Dec (degrees) pair.
  Offset? projectRaDec(double raHours, double decDeg) {
    if (!raHours.isFinite || !decDeg.isFinite) return null;

    if (viewState.viewMode == SkyViewMode.horizontal) {
      final lst = lstHours;
      if (lst == null) return null;
      final (alt, az) = AstronomyCalculations.equatorialToHorizontal(
        raDeg: raHours * 15,
        decDeg: decDeg,
        latitudeDeg: latitude,
        lstHours: lst,
      );
      return projectAltAz(alt, az);
    }

    return _project(
      lonDeg: raHours * 15,
      latDeg: decDeg,
      centerLonDeg: viewState.centerRA * 15,
      centerLatDeg: viewState.centerDec,
    );
  }

  /// Project an alt/az pair in the horizontal frame. Azimuth is negated so East
  /// falls to the right of the screen, matching the sky painter.
  Offset? projectAltAz(double altDeg, double azDeg) {
    if (!altDeg.isFinite || !azDeg.isFinite) return null;
    return _project(
      lonDeg: -azDeg,
      latDeg: altDeg,
      centerLonDeg: -viewState.centerAz,
      centerLatDeg: viewState.centerAltitude,
    );
  }

  /// Screen-space angle (radians, clockwise from screen "up") of celestial
  /// north as seen at [coord].
  ///
  /// A sensor's position angle is measured from north, and north is only
  /// straight up at the view center — everywhere else the projection tilts it.
  /// Measured by finite difference through the real projection so it stays
  /// correct in every projection and view mode. Returns null when the point
  /// cannot be projected.
  double? northAngleAt(CelestialCoordinate coord) {
    const epsDeg = 0.01;
    // Step toward the pole we are not sitting on, so a target at +90° dec
    // still yields a usable tangent.
    final sign = coord.dec + epsDeg > 90 ? -1.0 : 1.0;
    final here = projectRaDec(coord.ra, coord.dec);
    final northward = projectRaDec(coord.ra, coord.dec + sign * epsDeg);
    if (here == null || northward == null) return null;
    final v = (northward - here) * sign;
    if (v.distance < 1e-9 || !v.dx.isFinite || !v.dy.isFinite) return null;
    return math.atan2(v.dx, -v.dy);
  }

  /// Inverse of [project]: turn a screen point back into a sky coordinate.
  ///
  /// Returns null when the point falls outside the projectable disc (possible
  /// for the orthographic and azimuthal-equidistant projections) or when the
  /// horizontal frame is active without a [lstHours].
  CelestialCoordinate? unproject(Offset point) {
    if (!point.dx.isFinite || !point.dy.isFinite) return null;

    if (viewState.viewMode == SkyViewMode.horizontal) {
      final lst = lstHours;
      if (lst == null) return null;
      final inverse = _inverse(
        point,
        centerLonDeg: -viewState.centerAz,
        centerLatDeg: viewState.centerAltitude,
      );
      if (inverse == null) return null;
      final (lonDeg, latDeg) = inverse;
      final (raDeg, decDeg) = AstronomyCalculations.horizontalToEquatorial(
        altDeg: latDeg,
        azDeg: -lonDeg,
        latitudeDeg: latitude,
        lstHours: lst,
      );
      return CelestialCoordinate(
        ra: _wrapRaHours(raDeg / 15),
        dec: decDeg.clamp(-90.0, 90.0),
      );
    }

    final inverse = _inverse(
      point,
      centerLonDeg: viewState.centerRA * 15,
      centerLatDeg: viewState.centerDec,
    );
    if (inverse == null) return null;
    final (lonDeg, latDeg) = inverse;
    return CelestialCoordinate(
      ra: _wrapRaHours(lonDeg / 15),
      dec: latDeg.clamp(-90.0, 90.0),
    );
  }

  static double _wrapRaHours(double hours) {
    if (!hours.isFinite) return 0;
    var wrapped = hours % 24;
    if (wrapped < 0) wrapped += 24;
    return wrapped;
  }

  /// The shared spherical projector. Mirrors
  /// `SkyCanvasPainter._projectAroundCenter` exactly.
  Offset? _project({
    required double lonDeg,
    required double latDeg,
    required double centerLonDeg,
    required double centerLatDeg,
  }) {
    if (!pixelsPerDegree.isFinite || pixelsPerDegree <= 0) return null;
    if (!centerLonDeg.isFinite || !centerLatDeg.isFinite) return null;

    final lon1 = centerLonDeg * _deg2rad;
    final lat1 = centerLatDeg * _deg2rad;
    final lon2 = lonDeg * _deg2rad;
    final lat2 = latDeg * _deg2rad;

    final cosc =
        math.sin(lat1) * math.sin(lat2) +
        math.cos(lat1) * math.cos(lat2) * math.cos(lon2 - lon1);

    // Behind the projection plane — the sky painter culls here too.
    if (cosc.isNaN || cosc < 0.01) return null;

    double x;
    double y;

    switch (viewState.projection) {
      case SkyProjection.stereographic:
        final k = 2 / (1 + cosc);
        x = k * math.cos(lat2) * math.sin(lon2 - lon1);
        y =
            k *
            (math.cos(lat1) * math.sin(lat2) -
                math.sin(lat1) * math.cos(lat2) * math.cos(lon2 - lon1));
        break;

      case SkyProjection.orthographic:
        x = math.cos(lat2) * math.sin(lon2 - lon1);
        y =
            math.cos(lat1) * math.sin(lat2) -
            math.sin(lat1) * math.cos(lat2) * math.cos(lon2 - lon1);
        break;

      case SkyProjection.azimuthalEquidistant:
        final c = math.acos(cosc.clamp(-1.0, 1.0));
        if (c < 0.0001) {
          x = 0;
          y = 0;
        } else {
          final k = c / math.sin(c);
          x = k * math.cos(lat2) * math.sin(lon2 - lon1);
          y =
              k *
              (math.cos(lat1) * math.sin(lat2) -
                  math.sin(lat1) * math.cos(lat2) * math.cos(lon2 - lon1));
        }
        break;
    }

    final rotRad = viewState.rotation * _deg2rad;
    final xRot = x * math.cos(rotRad) - y * math.sin(rotRad);
    final yRot = x * math.sin(rotRad) + y * math.cos(rotRad);

    // Note the subtraction: increasing RA runs LEFT across the screen, which is
    // the whole point of routing overlays through this projector.
    final offset = Offset(
      screenCenter.dx - xRot * pixelsPerDegree * _rad2deg,
      screenCenter.dy - yRot * pixelsPerDegree * _rad2deg,
    );
    if (!offset.dx.isFinite || !offset.dy.isFinite) return null;
    return offset;
  }

  /// Analytic inverse of [_project] for each projection branch.
  (double lonDeg, double latDeg)? _inverse(
    Offset point, {
    required double centerLonDeg,
    required double centerLatDeg,
  }) {
    if (!pixelsPerDegree.isFinite || pixelsPerDegree <= 0) return null;

    // Screen pixels back to the projector's radian plane.
    final perRadian = pixelsPerDegree * _rad2deg;
    final xRot = (screenCenter.dx - point.dx) / perRadian;
    final yRot = (screenCenter.dy - point.dy) / perRadian;

    final rotRad = viewState.rotation * _deg2rad;
    final x = xRot * math.cos(rotRad) + yRot * math.sin(rotRad);
    final y = -xRot * math.sin(rotRad) + yRot * math.cos(rotRad);

    final rho = math.sqrt(x * x + y * y);
    if (!rho.isFinite) return null;
    if (rho < 1e-12) return (centerLonDeg, centerLatDeg);

    double c;
    switch (viewState.projection) {
      case SkyProjection.stereographic:
        c = 2 * math.atan(rho / 2);
        break;
      case SkyProjection.orthographic:
        if (rho > 1) return null; // outside the visible hemisphere
        c = math.asin(rho);
        break;
      case SkyProjection.azimuthalEquidistant:
        if (rho > math.pi) return null;
        c = rho;
        break;
    }

    final sinc = math.sin(c);
    final cosc = math.cos(c);
    final lon1 = centerLonDeg * _deg2rad;
    final lat1 = centerLatDeg * _deg2rad;

    final lat = math.asin(
      (cosc * math.sin(lat1) + y * sinc * math.cos(lat1) / rho).clamp(
        -1.0,
        1.0,
      ),
    );
    final lon =
        lon1 +
        math.atan2(
          x * sinc,
          rho * math.cos(lat1) * cosc - y * math.sin(lat1) * sinc,
        );

    if (!lon.isFinite || !lat.isFinite) return null;
    return (lon * _rad2deg, lat * _rad2deg);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SkyFovProjector &&
          runtimeType == other.runtimeType &&
          viewState == other.viewState &&
          screenCenter == other.screenCenter &&
          pixelsPerDegree == other.pixelsPerDegree &&
          latitude == other.latitude &&
          lstHours == other.lstHours;

  @override
  int get hashCode =>
      Object.hash(viewState, screenCenter, pixelsPerDegree, latitude, lstHours);
}

/// FOV rectangle overlay painter.
///
/// Everything it draws is placed through [SkyFovProjector], so the sensor
/// footprint lands exactly where the stars say it should.
///
/// One limitation is deliberate and explicit: pinning the box to a fixed
/// [fovCenter] in [SkyViewMode.horizontal] needs the observer latitude and
/// local sidereal time to rotate RA/Dec into alt/az, and the host does not pass
/// them to this painter (it does pass them to the measurement overlay). In that
/// frame a *pinned* box is therefore not drawn at all rather than drawn in the
/// wrong place. An unpinned box — the common case, [fovCenter] `null` — is
/// centered on the view and is correct in both frames.
class _FOVOverlayPainter extends CustomPainter {
  final SkyViewState viewState;
  final double? fovWidth;
  final double? fovHeight;
  final CelestialCoordinate? fovCenter;
  final double rotation;
  final bool showCrosshair;

  _FOVOverlayPainter({
    required this.viewState,
    this.fovWidth,
    this.fovHeight,
    this.fovCenter,
    this.rotation = 0,
    this.showCrosshair = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final width = fovWidth;
    final height = fovHeight;
    if (width == null || height == null) return;
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      return;
    }
    if (size.shortestSide <= 0 || viewState.fieldOfView <= 0) return;

    final projector = SkyFovProjector.forSize(viewState, size);
    final center = projector.screenCenter;
    final scale = projector.pixelsPerDegree;

    // Convert FOV to screen pixels
    final rectWidth = width * scale;
    final rectHeight = height * scale;

    // Place the box. An unpinned box sits at the view center; a pinned one is
    // projected through the same maths as the stars, so it lands on the target
    // in every projection, at any view rotation, and across the 0h/24h seam.
    // A null projection means the target is behind the viewer (or unplaceable
    // in this frame) — draw nothing rather than garbage.
    Offset rectCenter = center;
    // Screen angle of celestial north at the box: exactly the view rotation at
    // the view center, and the projection-tilted local north anywhere else.
    double northAngleRad = viewState.rotation * math.pi / 180;
    final target = fovCenter;
    if (target != null) {
      final projected = projector.project(target);
      if (projected == null) return;
      rectCenter = projected;
      northAngleRad = projector.northAngleAt(target) ?? northAngleRad;
    }

    // Draw FOV rectangle
    canvas.save();
    canvas.translate(rectCenter.dx, rectCenter.dy);
    canvas.rotate(rotation * math.pi / 180 + northAngleRad);

    final rect = Rect.fromCenter(
      center: Offset.zero,
      width: rectWidth,
      height: rectHeight,
    );

    // Draw border
    final borderPaint = Paint()
      ..color = const Color(0xFF00E676)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    canvas.drawRect(rect, borderPaint);

    // Draw corner brackets
    final bracketLength = math.min(rectWidth, rectHeight) * 0.1;
    final bracketPaint = Paint()
      ..color = const Color(0xFF00E676)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    // Top-left
    canvas.drawLine(
      Offset(-rectWidth / 2, -rectHeight / 2 + bracketLength),
      Offset(-rectWidth / 2, -rectHeight / 2),
      bracketPaint,
    );
    canvas.drawLine(
      Offset(-rectWidth / 2, -rectHeight / 2),
      Offset(-rectWidth / 2 + bracketLength, -rectHeight / 2),
      bracketPaint,
    );

    // Top-right
    canvas.drawLine(
      Offset(rectWidth / 2 - bracketLength, -rectHeight / 2),
      Offset(rectWidth / 2, -rectHeight / 2),
      bracketPaint,
    );
    canvas.drawLine(
      Offset(rectWidth / 2, -rectHeight / 2),
      Offset(rectWidth / 2, -rectHeight / 2 + bracketLength),
      bracketPaint,
    );

    // Bottom-right
    canvas.drawLine(
      Offset(rectWidth / 2, rectHeight / 2 - bracketLength),
      Offset(rectWidth / 2, rectHeight / 2),
      bracketPaint,
    );
    canvas.drawLine(
      Offset(rectWidth / 2, rectHeight / 2),
      Offset(rectWidth / 2 - bracketLength, rectHeight / 2),
      bracketPaint,
    );

    // Bottom-left
    canvas.drawLine(
      Offset(-rectWidth / 2 + bracketLength, rectHeight / 2),
      Offset(-rectWidth / 2, rectHeight / 2),
      bracketPaint,
    );
    canvas.drawLine(
      Offset(-rectWidth / 2, rectHeight / 2),
      Offset(-rectWidth / 2, rectHeight / 2 - bracketLength),
      bracketPaint,
    );

    if (showCrosshair) {
      // Draw center crosshair
      final crosshairPaint = Paint()
        ..color = const Color(0xFF00E676).withValues(alpha: 0.5)
        ..strokeWidth = 1;

      canvas.drawLine(
        const Offset(-15, 0),
        const Offset(15, 0),
        crosshairPaint,
      );
      canvas.drawLine(
        const Offset(0, -15),
        const Offset(0, 15),
        crosshairPaint,
      );
    }

    // Draw rotation indicator
    if (rotation != 0) {
      canvas.drawLine(
        Offset(0, -rectHeight / 2 - 20),
        Offset(0, -rectHeight / 2 - 5),
        borderPaint,
      );
    }

    canvas.restore();

    // Draw FOV dimensions label
    final fovText =
        '${width.toStringAsFixed(2)}° × ${height.toStringAsFixed(2)}°';
    final textPainter = TextPainter(
      text: TextSpan(
        text: fovText,
        style: const TextStyle(
          color: Color(0xFF00E676),
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(
        rectCenter.dx - textPainter.width / 2,
        rectCenter.dy + rectHeight / 2 + 10,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant _FOVOverlayPainter oldDelegate) {
    return showCrosshair != oldDelegate.showCrosshair ||
        viewState != oldDelegate.viewState ||
        fovWidth != oldDelegate.fovWidth ||
        fovHeight != oldDelegate.fovHeight ||
        // Without this the box stays where it was when the user picks a new
        // target — the overlay would point at the previous object.
        fovCenter != oldDelegate.fovCenter ||
        rotation != oldDelegate.rotation;
  }
}
