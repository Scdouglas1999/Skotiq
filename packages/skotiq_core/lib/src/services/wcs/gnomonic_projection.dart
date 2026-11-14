// Gnomonic (TAN) projection between sky (RA, Dec) and image pixel
// coordinates: the one projection for every overlay and cross-match on a
// plate-solved frame.

import 'dart:math' as math;

import '../../models/science/science_models.dart' show WcsSolution;
import '../../models/imaging/sip_terms.dart';

/// Solved World Coordinate System for a captured frame, expressed in the
/// units the existing `PlateSolveResult` carries:
///
/// - [raHours]      — right ascension of the reference pixel (hours, J2000)
/// - [decDegrees]   — declination of the reference pixel (degrees, J2000)
/// - [rotationDeg]  — field rotation in degrees as the native parser reports
///                    it (ASTAP's CROTA2: east of north if not flipped).
/// - [pixelScaleArcsec] — plate scale in arcseconds per pixel.
/// - [imageWidth] / [imageHeight] — image dimensions in pixels.
///
/// Pixel coordinates are FITS buffer coordinates, 0-based, with integer
/// values at pixel centres: (0, 0) is the centre of the first stored pixel,
/// x runs along a row and y along the stored row order. This is the frame the
/// star detector reports in and the order the preview draws rows in. The
/// reference pixel is ([referenceX], [referenceY]) when given, else the image
/// centre `((W - 1) / 2, (H - 1) / 2)`; either is the FITS CRPIX less one.
///
/// The sky-to-pixel mapping is the standard FITS one: `(xi, eta) = CD (u, v)`
/// with `(u, v)` the offset from the reference pixel. When the CD matrix is
/// absent it is rebuilt from [rotationDeg] and [pixelScaleArcsec], with the
/// sky's own parity unless [mirrored] says the frame went through a mirror.
class SolvedWcs {
  final double raHours;
  final double decDegrees;
  final double rotationDeg;
  final double pixelScaleArcsec;
  final int imageWidth;
  final int imageHeight;

  /// Full CD matrix (deg/pixel) exactly as the solver wrote it. When all four
  /// are present the projection uses it; otherwise it rebuilds one from the
  /// rotation, scale and [mirrored].
  final double? cd1_1;
  final double? cd1_2;
  final double? cd2_1;
  final double? cd2_2;

  /// SIP distortion. Without the inverse (`AP`/`BP`) the projection inverts
  /// the forward polynomials by Newton iteration.
  final SipTerms sip;

  /// Whether the frame's parity is mirrored (det CD > 0), e.g. one reflection
  /// in a Newtonian. Only consulted when no CD matrix is present, because the
  /// matrix carries its own parity.
  final bool mirrored;

  /// 0-based reference pixel, or null for the image centre.
  final double? referenceX;
  final double? referenceY;

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
    this.sip = noSipTerms,
    this.mirrored = false,
    this.referenceX,
    this.referenceY,
  });

  /// The WCS a FITS header states as CRVAL (degrees), CRPIX (1-based), a CD
  /// matrix (degrees per pixel) and its SIP terms, or null when a scalar is
  /// missing or not finite, or the matrix is singular.
  static SolvedWcs? tryFromFits({
    required double? crval1,
    required double? crval2,
    required double? crpix1,
    required double? crpix2,
    required double? cd1_1,
    required double? cd1_2,
    required double? cd2_1,
    required double? cd2_2,
    SipTerms sip = noSipTerms,
    required int imageWidth,
    required int imageHeight,
  }) {
    if (crval1 == null ||
        crval2 == null ||
        crpix1 == null ||
        crpix2 == null ||
        cd1_1 == null ||
        cd1_2 == null ||
        cd2_1 == null ||
        cd2_2 == null) {
      return null;
    }
    final determinant = cd1_1 * cd2_2 - cd1_2 * cd2_1;
    final scalars = [crval1, crval2, crpix1, crpix2, determinant];
    if (!scalars.every((v) => v.isFinite) || determinant.abs() <= 1e-30) {
      return null;
    }
    return SolvedWcs(
      raHours: crval1 / 15.0,
      decDegrees: crval2,
      rotationDeg: rotationFromCd(
        cd1_1: cd1_1,
        cd1_2: cd1_2,
        cd2_1: cd2_1,
        cd2_2: cd2_2,
      ),
      pixelScaleArcsec: math.sqrt(determinant.abs()) * 3600.0,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      cd1_1: cd1_1,
      cd1_2: cd1_2,
      cd2_1: cd2_1,
      cd2_2: cd2_2,
      sip: sip,
      referenceX: crpix1 - 1.0,
      referenceY: crpix2 - 1.0,
    );
  }

  /// A science solve over a [imageWidth] x [imageHeight] frame.
  factory SolvedWcs.ofSolution(
    WcsSolution solution, {
    required int imageWidth,
    required int imageHeight,
  }) => SolvedWcs(
    raHours: solution.raHours,
    decDegrees: solution.decDegrees,
    rotationDeg: solution.rotationDegrees,
    pixelScaleArcsec: solution.pixelScaleArcsecPerPixel,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    cd1_1: solution.cd1_1,
    cd1_2: solution.cd1_2,
    cd2_1: solution.cd2_1,
    cd2_2: solution.cd2_2,
    sip: solution.sip,
  );

  /// The 0-based pixel the solution is referenced at: [referenceX] and
  /// [referenceY] when given, else the image centre.
  ({double x, double y}) get referencePixel => (
    x: referenceX ?? (imageWidth - 1) / 2.0,
    y: referenceY ?? (imageHeight - 1) / 2.0,
  );

  /// This solution as a FITS header states it: CRVAL in degrees, the 1-based
  /// CRPIX, and the CD matrix the projection uses ([effectiveCd]).
  ({
    double crval1,
    double crval2,
    double crpix1,
    double crpix2,
    double cd1_1,
    double cd1_2,
    double cd2_1,
    double cd2_2,
  })
  get fitsTerms {
    final cd = effectiveCd;
    final reference = referencePixel;
    return (
      crval1: raHours * 15.0,
      crval2: decDegrees,
      crpix1: reference.x + 1.0,
      crpix2: reference.y + 1.0,
      cd1_1: cd.cd1_1,
      cd1_2: cd.cd1_2,
      cd2_1: cd.cd2_1,
      cd2_2: cd.cd2_2,
    );
  }

  /// Radius in degrees of a catalog cone search that covers the frame: half
  /// the diagonal plus a 10 % margin, kept to the range a cone search answers
  /// usefully.
  double get coneSearchRadiusDegrees {
    final halfDiagonal =
        0.5 *
        math.sqrt(imageWidth * imageWidth + imageHeight * imageHeight) *
        pixelScaleArcsec /
        3600.0;
    return (halfDiagonal * 1.1).clamp(0.05, 30.0);
  }

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

  /// The CD matrix the projection uses: the solver's own when present, else
  /// one rebuilt from rotation and scale with the native parser's convention
  /// (`rotation = atan2(cd2_1, -cd1_1)` for sky parity, `atan2(cd2_1, cd1_1)`
  /// for a mirrored frame).
  ({double cd1_1, double cd1_2, double cd2_1, double cd2_2}) get effectiveCd {
    if (hasCdMatrix) {
      return (cd1_1: cd1_1!, cd1_2: cd1_2!, cd2_1: cd2_1!, cd2_2: cd2_2!);
    }
    return cdFromRotation(
      pixelScaleArcsec: pixelScaleArcsec,
      rotationDeg: rotationDeg,
      mirrored: mirrored,
    );
  }

  /// True iff the effective CD matrix has mirrored parity (det > 0).
  bool get isMirrored {
    final cd = effectiveCd;
    return cd.cd1_1 * cd.cd2_2 - cd.cd1_2 * cd.cd2_1 > 0;
  }

  /// Rebuild a CD matrix from an isotropic scale and rotation. The inverse of
  /// the rotation the native `.wcs` parser reports.
  static ({double cd1_1, double cd1_2, double cd2_1, double cd2_2})
  cdFromRotation({
    required double pixelScaleArcsec,
    required double rotationDeg,
    bool mirrored = false,
  }) {
    final s = pixelScaleArcsec / 3600.0;
    final r = rotationDeg * math.pi / 180.0;
    final c = math.cos(r);
    final n = math.sin(r);
    if (mirrored) {
      return (cd1_1: s * c, cd1_2: -s * n, cd2_1: s * n, cd2_2: s * c);
    }
    return (cd1_1: -s * c, cd1_2: s * n, cd2_1: s * n, cd2_2: s * c);
  }

  /// Field rotation implied by a CD matrix, in the native parser's
  /// convention, so a stored scalar rotation can be checked against its
  /// matrix.
  static double rotationFromCd({
    required double cd1_1,
    required double cd1_2,
    required double cd2_1,
    required double cd2_2,
  }) {
    final mirrored = cd1_1 * cd2_2 - cd1_2 * cd2_1 > 0;
    final rad = mirrored ? math.atan2(cd2_1, cd1_1) : math.atan2(cd2_1, -cd1_1);
    return rad * 180.0 / math.pi;
  }

  /// True iff forward SIP coefficients are present.
  bool get hasForwardSip =>
      sip.aOrder > 0 &&
      sip.bOrder > 0 &&
      sip.aCoeffs.isNotEmpty &&
      sip.bCoeffs.isNotEmpty;

  /// True iff inverse SIP coefficients are present.
  bool get hasInverseSip =>
      sip.apOrder > 0 &&
      sip.bpOrder > 0 &&
      sip.apCoeffs.isNotEmpty &&
      sip.bpCoeffs.isNotEmpty;

  /// The same solution over the same frame: every field, coefficients
  /// included.
  @override
  bool operator ==(Object other) =>
      other is SolvedWcs &&
      other.raHours == raHours &&
      other.decDegrees == decDegrees &&
      other.rotationDeg == rotationDeg &&
      other.pixelScaleArcsec == pixelScaleArcsec &&
      other.imageWidth == imageWidth &&
      other.imageHeight == imageHeight &&
      other.cd1_1 == cd1_1 &&
      other.cd1_2 == cd1_2 &&
      other.cd2_1 == cd2_1 &&
      other.cd2_2 == cd2_2 &&
      other.mirrored == mirrored &&
      other.referenceX == referenceX &&
      other.referenceY == referenceY &&
      other.sip.aOrder == sip.aOrder &&
      other.sip.bOrder == sip.bOrder &&
      other.sip.apOrder == sip.apOrder &&
      other.sip.bpOrder == sip.bpOrder &&
      _sameValues(other.sip.aCoeffs, sip.aCoeffs) &&
      _sameValues(other.sip.bCoeffs, sip.bCoeffs) &&
      _sameValues(other.sip.apCoeffs, sip.apCoeffs) &&
      _sameValues(other.sip.bpCoeffs, sip.bpCoeffs);

  @override
  int get hashCode => Object.hash(
    raHours,
    decDegrees,
    rotationDeg,
    pixelScaleArcsec,
    imageWidth,
    imageHeight,
    cd1_1,
    cd1_2,
    cd2_1,
    cd2_2,
    mirrored,
    referenceX,
    referenceY,
    sip.aOrder,
    Object.hashAll(sip.aCoeffs),
    Object.hashAll(sip.bCoeffs),
  );

  static bool _sameValues(List<double> a, List<double> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

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
  final double _pixelScaleDegrees;

  /// The CD matrix in use and its inverse (pixel/deg).
  final double _cd1_1;
  final double _cd1_2;
  final double _cd2_1;
  final double _cd2_2;
  final double _invCd1_1;
  final double _invCd1_2;
  final double _invCd2_1;
  final double _invCd2_2;

  /// 0-based reference pixel.
  final double _refX;
  final double _refY;

  factory GnomonicProjection(SolvedWcs wcs) {
    assert(wcs.isValid, 'GnomonicProjection requires a valid SolvedWcs');
    final cd = wcs.effectiveCd;
    return GnomonicProjection._(wcs, cd.cd1_1, cd.cd1_2, cd.cd2_1, cd.cd2_2);
  }

  GnomonicProjection._(
    this.wcs,
    this._cd1_1,
    this._cd1_2,
    this._cd2_1,
    this._cd2_2,
  ) : _ra0Rad = wcs.raHours * 15.0 * math.pi / 180.0,
      _dec0Rad = wcs.decDegrees * math.pi / 180.0,
      _sinDec0 = math.sin(wcs.decDegrees * math.pi / 180.0),
      _cosDec0 = math.cos(wcs.decDegrees * math.pi / 180.0),
      _pixelScaleDegrees = wcs.pixelScaleArcsec / 3600.0,
      _invCd1_1 = _cd2_2 / (_cd1_1 * _cd2_2 - _cd1_2 * _cd2_1),
      _invCd1_2 = -_cd1_2 / (_cd1_1 * _cd2_2 - _cd1_2 * _cd2_1),
      _invCd2_1 = -_cd2_1 / (_cd1_1 * _cd2_2 - _cd1_2 * _cd2_1),
      _invCd2_2 = _cd1_1 / (_cd1_1 * _cd2_2 - _cd1_2 * _cd2_1),
      _refX = wcs.referencePixel.x,
      _refY = wcs.referencePixel.y;

  /// Project (RA, Dec) to image pixels using the TAN (gnomonic) projection.
  ///
  /// Returns null when the point is on the back hemisphere relative to
  /// the projection centre — at that location the gnomonic denominator
  /// goes to zero or negative and there's no real pixel.
  ProjectedPoint? worldToPixel({
    required double raDegrees,
    required double decDegrees,
  }) {
    final standard = _standardCoordinates(raDegrees, decDegrees);
    if (standard == null) return null;
    final xiDeg = standard.$1;
    final etaDeg = standard.$2;

    // (u, v) = CD^-1 (xi, eta) is the offset from the reference pixel after
    // distortion; SIP is undone on top of it.
    var u = _invCd1_1 * xiDeg + _invCd1_2 * etaDeg;
    var v = _invCd2_1 * xiDeg + _invCd2_2 * etaDeg;
    if (wcs.hasForwardSip) {
      final undistorted = _undistortIntermediate(u, v);
      u = undistorted.$1;
      v = undistorted.$2;
    }
    final x = _refX + u;
    final y = _refY + v;

    final onImage =
        x >= -0.5 &&
        x <= wcs.imageWidth - 0.5 &&
        y >= -0.5 &&
        y <= wcs.imageHeight - 0.5;
    return ProjectedPoint(pixel: PixelPoint(x, y), onImage: onImage);
  }

  /// Invert the projection: convert an image pixel back to (RA, Dec) in
  /// degrees. Always returns a finite coordinate; pixels far outside the
  /// frame are simply projected back through the tangent plane and clip.
  ({double raDegrees, double decDegrees}) pixelToWorld({
    required double x,
    required double y,
  }) {
    var u = x - _refX;
    var v = y - _refY;
    if (wcs.hasForwardSip) {
      final fu = _sipPoly(wcs.sip.aOrder, wcs.sip.aCoeffs, u, v);
      final fv = _sipPoly(wcs.sip.bOrder, wcs.sip.bCoeffs, u, v);
      u += fu;
      v += fv;
    }
    final xiDeg = _cd1_1 * u + _cd1_2 * v;
    final etaDeg = _cd2_1 * u + _cd2_2 * v;

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

  /// Sky position of the image centre.
  ({double raDegrees, double decDegrees}) get imageCentre => pixelToWorld(
    x: (wcs.imageWidth - 1) / 2.0,
    y: (wcs.imageHeight - 1) / 2.0,
  );

  /// Direction of north and east on the image at the reference pixel, as
  /// unit vectors in pixel coordinates (+x along a row, +y along the stored
  /// row order). Overlays that draw a compass use these instead of a scalar
  /// rotation, which cannot carry the frame's parity.
  ({double northX, double northY, double eastX, double eastY})
  get skyAxesOnImage {
    // Pixel offset per unit eta (north) and per unit xi (east).
    final nx = _invCd1_2;
    final ny = _invCd2_2;
    final ex = _invCd1_1;
    final ey = _invCd2_1;
    final nl = math.sqrt(nx * nx + ny * ny);
    final el = math.sqrt(ex * ex + ey * ey);
    return (northX: nx / nl, northY: ny / nl, eastX: ex / el, eastY: ey / el);
  }

  /// Tangent-plane (xi, eta) in degrees, or null behind the tangent plane.
  (double, double)? _standardCoordinates(double raDegrees, double decDegrees) {
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

    final denom = _sinDec0 * sinDec + _cosDec0 * cosDec * cosDRa;
    if (denom <= 0) return null;

    // xi is +east, eta is +north.
    final xi = cosDec * sinDRa / denom;
    final eta = (_cosDec0 * sinDec - _sinDec0 * cosDec * cosDRa) / denom;
    return (xi * 180.0 / math.pi, eta * 180.0 / math.pi);
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

  /// Recover the pixel offset (u, v) from the reference pixel given the
  /// distorted intermediate coordinate CD^-1 (xi, eta). Uses the AP/BP
  /// inverse SIP when present; otherwise a few Newton iterations against the
  /// forward A/B polynomials, so it inverts [_sipPoly] as applied in
  /// [pixelToWorld].
  (double, double) _undistortIntermediate(double a, double b) {
    if (wcs.hasInverseSip) {
      return (
        a + _sipPoly(wcs.sip.apOrder, wcs.sip.apCoeffs, a, b),
        b + _sipPoly(wcs.sip.bpOrder, wcs.sip.bpCoeffs, a, b),
      );
    }
    var u = a;
    var w = b;
    for (var iter = 0; iter < 8; iter++) {
      final fu = u + _sipPoly(wcs.sip.aOrder, wcs.sip.aCoeffs, u, w);
      final fw = w + _sipPoly(wcs.sip.bOrder, wcs.sip.bCoeffs, u, w);
      u -= fu - a;
      w -= fw - b;
    }
    return (u, w);
  }
}
