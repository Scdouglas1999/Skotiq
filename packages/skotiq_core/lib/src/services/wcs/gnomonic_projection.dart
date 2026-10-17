// Pure-Dart gnomonic (TAN) projection between sky (RA, Dec) and image pixel
// coordinates. Used by the catalog overlay (F5-CATALOG-OVERLAY) to draw
// Messier / NGC / IC / bright stars on a plate-solved capture.
//
// Why a dedicated module: the legacy `WcsOverlay` in `wcs_overlay.dart`
// uses a small-angle approximation (no `tan`, no proper denominator) that
// breaks down at the >1 degree FOV scales most amateur astrographs work at.
// Catalog overlay needs the real spherical math so a galaxy 30 arcmin off
// the optical axis still lands on the correct pixel.

import 'dart:math' as math;

/// Solved World Coordinate System for a captured frame, expressed in the
/// units the existing `PlateSolveResult` carries:
///
/// - [raHours]      — image-centre right ascension (hours, J2000)
/// - [decDegrees]   — image-centre declination (degrees, J2000)
/// - [rotationDeg]  — sky-to-pixel rotation (degrees). Convention matches
///                    the rest of Skotiq: positive rotation goes from
///                    +RA toward +Dec on the image, measured CCW from
///                    image-up.
/// - [pixelScaleArcsec] — plate scale in arcseconds per pixel (assumed
///                    isotropic; ASTAP / astrometry.net always report a
///                    single CDELT for solved frames in this codebase).
/// - [imageWidth] / [imageHeight] — image dimensions in pixels.
///
/// Pixel origin is the top-left of the image (Flutter / image convention),
/// with +X to the right and +Y down. RA increases eastward (to the left
/// on the sky); the projection accounts for that by flipping the sign of
/// the standard coordinate before applying [rotationDeg].
class SolvedWcs {
  final double raHours;
  final double decDegrees;
  final double rotationDeg;
  final double pixelScaleArcsec;
  final int imageWidth;
  final int imageHeight;

  /// Full anisotropic CD matrix (deg/pixel) as read from the WCS. When all
  /// four are non-null the projection drives the (xi, eta) <-> pixel linear
  /// mapping from the matrix directly instead of the isotropic
  /// scale-plus-rotation collapse. Sign convention matches the native
  /// `WcsInfo::from_plate_solve` (`cd1_1 = -scale*cos`, `cd1_2 = scale*sin`,
  /// `cd2_1 = scale*sin`, `cd2_2 = scale*cos`) so the matrix is consistent
  /// with the cdelt/crota reconstruction in `_resolveMasterWcs` and
  /// `_overlayFromSolution`. Null -> behaves exactly as the isotropic path.
  final double? cd1_1;
  final double? cd1_2;
  final double? cd2_1;
  final double? cd2_2;

  /// SIP forward distortion (`A_ORDER`/`B_ORDER` and their coefficient
  /// lists, row-major `(i, j)` at index `i * (order + 1) + j`). Empty/zero ->
  /// no forward distortion. AP/BP are the SIP inverse; when absent the
  /// projection falls back to an iterative Newton correction.
  final int aOrder;
  final int bOrder;
  final List<double> aCoeffs;
  final List<double> bCoeffs;
  final int apOrder;
  final int bpOrder;
  final List<double> apCoeffs;
  final List<double> bpCoeffs;

  const SolvedWcs({
    required this.raHours,
    required this.decDegrees,
    required this.rotationDeg,
    required this.pixelScaleArcsec,
    required this.imageWidth,
    required this.imageHeight,
    this.cd1_1,
    this.cd1_2,
    this.cd2_1,
    this.cd2_2,
    this.aOrder = 0,
    this.bOrder = 0,
    this.aCoeffs = const [],
    this.bCoeffs = const [],
    this.apOrder = 0,
    this.bpOrder = 0,
    this.apCoeffs = const [],
    this.bpCoeffs = const [],
  });

  /// True iff a full, finite, invertible CD matrix is present.
  bool get hasCdMatrix =>
      cd1_1 != null &&
      cd1_2 != null &&
      cd2_1 != null &&
      cd2_2 != null &&
      cd1_1!.isFinite &&
      cd1_2!.isFinite &&
      cd2_1!.isFinite &&
      cd2_2!.isFinite &&
      (cd1_1! * cd2_2! - cd1_2! * cd2_1!).abs() > 1e-30;

  /// True iff forward SIP coefficients are present.
  bool get hasForwardSip =>
      aOrder > 0 && bOrder > 0 && aCoeffs.isNotEmpty && bCoeffs.isNotEmpty;

  /// True iff inverse SIP coefficients are present.
  bool get hasInverseSip =>
      apOrder > 0 && bpOrder > 0 && apCoeffs.isNotEmpty && bpCoeffs.isNotEmpty;

  /// True iff every WCS field is finite and the plate scale is positive.
  /// The overlay must refuse to project against a zero pixel scale: dividing
  /// by it produces ±inf pixel coordinates and hides the broken WCS.
  bool get isValid =>
      raHours.isFinite &&
      decDegrees.isFinite &&
      rotationDeg.isFinite &&
      pixelScaleArcsec.isFinite &&
      pixelScaleArcsec > 0 &&
      imageWidth > 0 &&
      imageHeight > 0;
}

/// Image-pixel position. (0, 0) is the top-left of the frame.
class PixelPoint {
  final double x;
  final double y;

  const PixelPoint(this.x, this.y);

  @override
  String toString() =>
      'PixelPoint(${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)})';
}

/// Rectangular RA / Dec bounding box for a frame. RA is in degrees in the
/// range [0, 360); the [crossesRaWrap] flag indicates whether the box
/// spans the 0/360 boundary so callers can do two range queries instead
/// of one.
class SkyBoundingBox {
  /// Inclusive RA lower bound in degrees. When [crossesRaWrap] is true,
  /// this is the larger value (e.g. 358) and [raMaxDeg] is the smaller
  /// value (e.g. 2) — the box covers [raMinDeg, 360) ∪ [0, raMaxDeg].
  final double raMinDeg;

  /// Inclusive RA upper bound in degrees.
  final double raMaxDeg;

  /// Inclusive Dec lower bound in degrees (clamped to -90).
  final double decMinDeg;

  /// Inclusive Dec upper bound in degrees (clamped to +90).
  final double decMaxDeg;

  /// True iff the box wraps across RA = 0 (e.g. for a target near 0h).
  final bool crossesRaWrap;

  /// True iff the box includes a pole. When set, the RA bounds are
  /// effectively the full [0, 360) range — every RA appears at the pole
  /// — and callers should not pre-filter by RA.
  final bool touchesPole;

  const SkyBoundingBox({
    required this.raMinDeg,
    required this.raMaxDeg,
    required this.decMinDeg,
    required this.decMaxDeg,
    required this.crossesRaWrap,
    required this.touchesPole,
  });

  /// Whether the given RA (degrees, in [0, 360)) is inside the box.
  /// Handles wrap and pole inclusion.
  bool containsRaDeg(double raDeg) {
    if (touchesPole) return true;
    if (!crossesRaWrap) {
      return raDeg >= raMinDeg && raDeg <= raMaxDeg;
    }
    return raDeg >= raMinDeg || raDeg <= raMaxDeg;
  }

  /// Whether the given Dec (degrees) is inside the box.
  bool containsDecDeg(double decDeg) =>
      decDeg >= decMinDeg && decDeg <= decMaxDeg;

  /// Whether the given coordinate falls within the bounding box.
  bool contains({required double raDeg, required double decDeg}) =>
      containsDecDeg(decDeg) && containsRaDeg(raDeg);
}

/// Result of projecting a single sky coordinate to image space. Carries
/// the pixel and whether the pixel falls within the image frame so the
/// caller can drop off-frame catalog objects in a single pass.
class ProjectedPoint {
  final PixelPoint pixel;
  final bool onImage;

  const ProjectedPoint({required this.pixel, required this.onImage});
}

/// Gnomonic (TAN) projection helper. All trigonometric work happens in
/// radians; inputs are kept in the units the rest of Skotiq uses
/// (RA hours, Dec degrees, rotation degrees, arcsec/px) so callers don't
/// have to remember unit conversions at every site.
class GnomonicProjection {
  final SolvedWcs wcs;

  /// Cached radian forms of the centre — recomputed once per overlay
  /// rather than per projection so a 500-object query stays cheap.
  final double _ra0Rad;
  final double _dec0Rad;
  final double _sinDec0;
  final double _cosDec0;
  final double _sinRot;
  final double _cosRot;
  final double _pixelScaleDegrees;

  /// Inverse of the CD matrix (deg/pixel -> pixel/deg), cached when [wcs]
  /// carries a full matrix. Null falls back to the isotropic scale+rotation.
  final double? _invCd1_1;
  final double? _invCd1_2;
  final double? _invCd2_1;
  final double? _invCd2_2;

  GnomonicProjection(this.wcs)
    : assert(wcs.isValid, 'GnomonicProjection requires a valid SolvedWcs'),
      _ra0Rad = wcs.raHours * 15.0 * math.pi / 180.0,
      _dec0Rad = wcs.decDegrees * math.pi / 180.0,
      _sinDec0 = math.sin(wcs.decDegrees * math.pi / 180.0),
      _cosDec0 = math.cos(wcs.decDegrees * math.pi / 180.0),
      _sinRot = math.sin(wcs.rotationDeg * math.pi / 180.0),
      _cosRot = math.cos(wcs.rotationDeg * math.pi / 180.0),
      _pixelScaleDegrees = wcs.pixelScaleArcsec / 3600.0,
      _invCd1_1 = wcs.hasCdMatrix ? wcs.cd2_2! / _cdDet(wcs) : null,
      _invCd1_2 = wcs.hasCdMatrix ? -wcs.cd1_2! / _cdDet(wcs) : null,
      _invCd2_1 = wcs.hasCdMatrix ? -wcs.cd2_1! / _cdDet(wcs) : null,
      _invCd2_2 = wcs.hasCdMatrix ? wcs.cd1_1! / _cdDet(wcs) : null;

  static double _cdDet(SolvedWcs w) =>
      w.cd1_1! * w.cd2_2! - w.cd1_2! * w.cd2_1!;

  /// Project (RA, Dec) to image pixels using the TAN (gnomonic) projection.
  ///
  /// Returns null when the point is on the back hemisphere relative to
  /// the projection centre — at that location the gnomonic denominator
  /// goes to zero or negative and there's no real pixel.
  ProjectedPoint? worldToPixel({
    required double raDegrees,
    required double decDegrees,
  }) {
    final raRad = raDegrees * math.pi / 180.0;
    final decRad = decDegrees * math.pi / 180.0;

    // Wrap (ra - ra0) into [-pi, pi] so the cosine identity below is
    // numerically well-behaved when the target is on the other side of
    // RA = 0 from the projection centre.
    var dRa = raRad - _ra0Rad;
    while (dRa > math.pi) {
      dRa -= 2 * math.pi;
    }
    while (dRa < -math.pi) {
      dRa += 2 * math.pi;
    }

    final cosDec = math.cos(decRad);
    final sinDec = math.sin(decRad);
    final cosDRa = math.cos(dRa);
    final sinDRa = math.sin(dRa);

    // Standard gnomonic denominator. <= 0 means the point is on or behind
    // the tangent plane's antipode — undefined pixel, skip.
    final denom = _sinDec0 * sinDec + _cosDec0 * cosDec * cosDRa;
    if (denom <= 0) return null;

    // Standard (xi, eta) tangent-plane coordinates in radians. xi is +east
    // (which is -X on a normal sky image where RA increases right-to-left).
    final xi = cosDec * sinDRa / denom;
    final eta = (_cosDec0 * sinDec - _sinDec0 * cosDec * cosDRa) / denom;

    final xiDeg = xi * 180.0 / math.pi;
    final etaDeg = eta * 180.0 / math.pi;

    double x;
    double y;
    if (_invCd1_1 != null) {
      // (intermediate-pixel) = CD^-1 * (xi, eta). Undo SIP forward (AP/BP, or
      // Newton when the inverse coeffs are absent) before mapping to canvas.
      var a = _invCd1_1 * xiDeg + _invCd1_2! * etaDeg;
      var b = _invCd2_1! * xiDeg + _invCd2_2! * etaDeg;
      if (wcs.hasForwardSip) {
        final undistorted = _undistortIntermediate(a, b);
        a = undistorted.$1;
        b = undistorted.$2;
      }
      x = wcs.imageWidth / 2.0 - a;
      y = wcs.imageHeight / 2.0 - b;
    } else {
      // Apply rotation. With rotationDeg = 0 we want +eta (north on the sky)
      // to come out the top of the image (pixel Y up = pixel -Y on canvas)
      // and +xi (east) to come out the left (pixel -X). This matches the
      // existing _skyToPixel helper in live_preview_area.dart (used for
      // moving-object tracks) so behavior is consistent across overlays.
      final xRot = xiDeg * _cosRot - etaDeg * _sinRot;
      final yRot = xiDeg * _sinRot + etaDeg * _cosRot;

      final pxFromCenter = xRot / _pixelScaleDegrees;
      final pyFromCenter = yRot / _pixelScaleDegrees;

      x = wcs.imageWidth / 2.0 + pxFromCenter;
      y = wcs.imageHeight / 2.0 - pyFromCenter;
    }

    final onImage =
        x >= 0 && x <= wcs.imageWidth && y >= 0 && y <= wcs.imageHeight;
    return ProjectedPoint(pixel: PixelPoint(x, y), onImage: onImage);
  }

  /// Invert the projection: convert an image pixel back to (RA, Dec) in
  /// degrees. Always returns a finite coordinate; pixels far outside the
  /// frame are simply projected back through the tangent plane and clip.
  ({double raDegrees, double decDegrees}) pixelToWorld({
    required double x,
    required double y,
  }) {
    double xiDeg;
    double etaDeg;
    if (_invCd1_1 != null) {
      // Canvas -> intermediate-pixel (the negated CD^-1 frame), apply SIP
      // forward (A/B) to that frame, then map through the CD matrix.
      var a = wcs.imageWidth / 2.0 - x;
      var b = wcs.imageHeight / 2.0 - y;
      if (wcs.hasForwardSip) {
        final fa = _sipPoly(wcs.aOrder, wcs.aCoeffs, a, b);
        final fb = _sipPoly(wcs.bOrder, wcs.bCoeffs, a, b);
        a += fa;
        b += fb;
      }
      xiDeg = wcs.cd1_1! * a + wcs.cd1_2! * b;
      etaDeg = wcs.cd2_1! * a + wcs.cd2_2! * b;
    } else {
      final pxFromCenter = x - wcs.imageWidth / 2.0;
      final pyFromCenter = wcs.imageHeight / 2.0 - y;

      final xRot = pxFromCenter * _pixelScaleDegrees;
      final yRot = pyFromCenter * _pixelScaleDegrees;

      // Inverse rotation.
      xiDeg = xRot * _cosRot + yRot * _sinRot;
      etaDeg = -xRot * _sinRot + yRot * _cosRot;
    }

    final xi = xiDeg * math.pi / 180.0;
    final eta = etaDeg * math.pi / 180.0;

    // Standard inverse gnomonic — see Calabretta & Greisen 2002 §5.1.3.
    final rho = math.sqrt(xi * xi + eta * eta);
    if (rho < 1e-12) {
      return (
        raDegrees: _normaliseRaDeg(_ra0Rad * 180.0 / math.pi),
        decDegrees: _dec0Rad * 180.0 / math.pi,
      );
    }
    final c = math.atan(rho);
    final sinC = math.sin(c);
    final cosC = math.cos(c);

    final decRad = math.asin(
      (cosC * _sinDec0 + eta * sinC * _cosDec0 / rho).clamp(-1.0, 1.0),
    );
    final raRad =
        _ra0Rad +
        math.atan2(xi * sinC, rho * _cosDec0 * cosC - eta * _sinDec0 * sinC);

    return (
      raDegrees: _normaliseRaDeg(raRad * 180.0 / math.pi),
      decDegrees: decRad * 180.0 / math.pi,
    );
  }

  /// Compute a rectangular RA/Dec bounding box that fully encloses the
  /// image. Used to query the catalog efficiently before per-object
  /// projection. Adds a small padding margin so large objects whose
  /// centre is just off-frame still get drawn if their extent crosses
  /// the edge.
  SkyBoundingBox computeBoundingBox({double paddingFraction = 0.05}) {
    // Sample the four corners and the four edge midpoints to capture the
    // maximum Dec excursion (matters most for wide-FOV frames near the
    // poles where corners and edge midpoints disagree by several degrees).
    final w = wcs.imageWidth.toDouble();
    final h = wcs.imageHeight.toDouble();
    final padX = w * paddingFraction;
    final padY = h * paddingFraction;

    final samples = <({double raDegrees, double decDegrees})>[
      pixelToWorld(x: -padX, y: -padY),
      pixelToWorld(x: w / 2, y: -padY),
      pixelToWorld(x: w + padX, y: -padY),
      pixelToWorld(x: -padX, y: h / 2),
      pixelToWorld(x: w + padX, y: h / 2),
      pixelToWorld(x: -padX, y: h + padY),
      pixelToWorld(x: w / 2, y: h + padY),
      pixelToWorld(x: w + padX, y: h + padY),
    ];

    var decMin = double.infinity;
    var decMax = double.negativeInfinity;
    for (final s in samples) {
      if (s.decDegrees < decMin) decMin = s.decDegrees;
      if (s.decDegrees > decMax) decMax = s.decDegrees;
    }
    decMin = decMin.clamp(-90.0, 90.0);
    decMax = decMax.clamp(-90.0, 90.0);

    // If the projection centre is within roughly half the field-of-view
    // of a pole, declare the box pole-touching so the RA query is
    // skipped — every RA appears at the pole and a naive min/max would
    // pick a tiny RA slice that throws away most of the visible field.
    final approxFovDeg = math.max(w, h) * _pixelScaleDegrees;
    final centerDecDeg = wcs.decDegrees;
    final touchesPole = (90.0 - centerDecDeg.abs()) <= approxFovDeg;
    if (touchesPole) {
      // Extend the box all the way to the relevant pole so the catalog
      // query doesn't miss objects sitting near the pole inside the FOV
      // (the pixelToWorld samples can't reach ±90 exactly because the
      // gnomonic projection flattens near the pole).
      if (centerDecDeg >= 0) {
        decMax = 90.0;
      } else {
        decMin = -90.0;
      }
      return SkyBoundingBox(
        raMinDeg: 0,
        raMaxDeg: 360,
        decMinDeg: decMin,
        decMaxDeg: decMax,
        crossesRaWrap: false,
        touchesPole: true,
      );
    }

    // For RA: normalise each sample relative to the centre, then take
    // signed min/max so a frame centred near RA = 0 yields a box that
    // straddles the wrap rather than a box of width 360.
    final centerRaDeg = _normaliseRaDeg(wcs.raHours * 15.0);
    var raDeltaMin = double.infinity;
    var raDeltaMax = double.negativeInfinity;
    for (final s in samples) {
      var delta = s.raDegrees - centerRaDeg;
      while (delta > 180.0) {
        delta -= 360.0;
      }
      while (delta < -180.0) {
        delta += 360.0;
      }
      if (delta < raDeltaMin) raDeltaMin = delta;
      if (delta > raDeltaMax) raDeltaMax = delta;
    }

    final raMin = _normaliseRaDeg(centerRaDeg + raDeltaMin);
    final raMax = _normaliseRaDeg(centerRaDeg + raDeltaMax);
    final crossesWrap = raMin > raMax;

    return SkyBoundingBox(
      raMinDeg: raMin,
      raMaxDeg: raMax,
      decMinDeg: decMin,
      decMaxDeg: decMax,
      crossesRaWrap: crossesWrap,
      touchesPole: false,
    );
  }

  /// Approximate field-of-view (width, height) in degrees, useful for
  /// sizing the catalog query window.
  ({double widthDeg, double heightDeg}) get fieldOfViewDeg => (
    widthDeg: wcs.imageWidth * _pixelScaleDegrees,
    heightDeg: wcs.imageHeight * _pixelScaleDegrees,
  );

  static double _normaliseRaDeg(double raDeg) {
    var v = raDeg % 360.0;
    if (v < 0) v += 360.0;
    return v;
  }

  /// Evaluate a row-major SIP polynomial sum(coeff[i,j] * u^i * v^j) with the
  /// coefficient at index `i * (order + 1) + j`, matching the native packing.
  static double _sipPoly(int order, List<double> coeffs, double u, double v) {
    final stride = order + 1;
    var acc = 0.0;
    for (var i = 0; i <= order; i++) {
      for (var j = 0; j + i <= order; j++) {
        final c = coeffs[i * stride + j];
        if (c == 0.0) continue;
        acc += c * math.pow(u, i) * math.pow(v, j);
      }
    }
    return acc;
  }

  /// Recover the undistorted intermediate-pixel coordinate from a distorted
  /// one. Uses the AP/BP inverse SIP when present; otherwise a few Newton
  /// iterations against the forward A/B polynomials. Both branches operate in
  /// the CD-companion frame so they invert [_sipPoly] applied in pixelToWorld.
  (double, double) _undistortIntermediate(double a, double b) {
    if (wcs.hasInverseSip) {
      return (
        a + _sipPoly(wcs.apOrder, wcs.apCoeffs, a, b),
        b + _sipPoly(wcs.bpOrder, wcs.bpCoeffs, a, b),
      );
    }
    var u = a;
    var w = b;
    for (var iter = 0; iter < 8; iter++) {
      final fu = u + _sipPoly(wcs.aOrder, wcs.aCoeffs, u, w);
      final fw = w + _sipPoly(wcs.bOrder, wcs.bCoeffs, u, w);
      u -= fu - a;
      w -= fw - b;
    }
    return (u, w);
  }
}
