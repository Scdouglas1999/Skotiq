import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:skotiq_core/skotiq_core.dart';

/// Pixel geometry for DepthLock: turning what the operator drew on the
/// displayed frame into the frozen TAN reference a goal stores, and turning a
/// stored sky rectangle back into pixels so it can be drawn over a later
/// frame.
///
/// Kept pure and separate from the layer that draws it so the conventions can
/// be tested on their own — they are the part that is easy to get subtly
/// wrong and impossible to see wrong on screen.

/// The rectangle two drag corners describe, in image pixels, with the corners
/// in any order.
Rect depthLockNormalizedRect(Offset a, Offset b) => Rect.fromLTRB(
      math.min(a.dx, b.dx),
      math.min(a.dy, b.dy),
      math.max(a.dx, b.dx),
      math.max(a.dy, b.dy),
    );

/// The frozen reference geometry equivalent to [wcs], or null when [wcs]
/// cannot anchor a region.
///
/// The native side speaks FITS: 1-based `CRPIX`, and a CD matrix that maps
/// `(x − (crpix1−1), y − (crpix2−1))` straight to the tangent-plane
/// `(xi, eta)` in degrees. [SolvedWcs] speaks the preview's language instead —
/// 0-based pixels with +Y down, a reference pixel hard-coded at the image
/// centre, and either a full CD matrix in its own negated frame or an
/// isotropic scale-and-rotation collapse. This converts between them, so the
/// two describe the same sky for the same pixel.
///
/// Derivation for the isotropic path, which is the one the app actually
/// populates today: `gnomonic_projection.dart` computes
/// `xi = s·(u·cosR − v·sinR)` and `eta = s·(−u·sinR − v·cosR)` for
/// `u = x − W/2`, `v = y − H/2` and `s` the plate scale in degrees, which is
/// exactly `cd1_1 = s·cosR, cd1_2 = −s·sinR, cd2_1 = −s·sinR,
/// cd2_2 = −s·cosR`. The determinant is `−s²`: negative, because a sky image
/// has flipped parity, which the native validator accepts (it asks for square,
/// orthogonal pixels, not for a handedness).
ReferenceGeometry? depthLockReferenceFromSolvedWcs(SolvedWcs wcs) {
  if (!wcs.isValid) return null;
  final double crval1 = _normaliseRaDeg(wcs.raHours * 15.0);
  final double crval2 = wcs.decDegrees;
  // The native validator refuses a reference outside ±85° — the tangent plane
  // stops behaving near the pole — so refuse here rather than let the create
  // call fail with geometry the operator cannot see anything wrong with.
  if (crval2.abs() > 85.0) return null;

  // 0-based image centre, expressed in the FITS 1-based convention the
  // reference stores.
  final double crpix1 = wcs.imageWidth / 2.0 + 1.0;
  final double crpix2 = wcs.imageHeight / 2.0 + 1.0;

  if (wcs.hasCdMatrix) {
    // The projection's CD path works in `a = W/2 − x`, `b = H/2 − y` — both
    // axes negated relative to the frame the native side uses — so the matrix
    // carries straight over with its sign flipped.
    return ReferenceGeometry(
      width: wcs.imageWidth,
      height: wcs.imageHeight,
      crval1: crval1,
      crval2: crval2,
      crpix1: crpix1,
      crpix2: crpix2,
      cd1_1: -wcs.cd1_1!,
      cd1_2: -wcs.cd1_2!,
      cd2_1: -wcs.cd2_1!,
      cd2_2: -wcs.cd2_2!,
    );
  }

  final double scaleDeg = wcs.pixelScaleArcsec / 3600.0;
  final double rot = wcs.rotationDeg * math.pi / 180.0;
  final double cosR = math.cos(rot);
  final double sinR = math.sin(rot);
  return ReferenceGeometry(
    width: wcs.imageWidth,
    height: wcs.imageHeight,
    crval1: crval1,
    crval2: crval2,
    crpix1: crpix1,
    crpix2: crpix2,
    cd1_1: scaleDeg * cosR,
    cd1_2: -scaleDeg * sinR,
    cd2_1: -scaleDeg * sinR,
    cd2_2: -scaleDeg * cosR,
  );
}

/// The four corners of [rectangle] in image pixels on the frame [wcs]
/// describes, or null when any corner falls on the far hemisphere.
///
/// Corners are returned clockwise from the rectangle's `(−width/2, −height/2)`
/// corner. The offsets from the centre are computed on the local tangent
/// plane: a goal's rectangle is at most a degree across (the native limit), so
/// treating arcseconds of separation as flat here costs far less than the
/// width of the stroke that draws it.
///
/// [SkyRectangle.rotationDeg] is the position angle of the rectangle's height
/// axis, east of north: the height axis points `(cos θ north, sin θ east)` and
/// the width axis is perpendicular to it.
List<Offset>? depthLockRectangleCorners({
  required SkyRectangle rectangle,
  required ReferenceGeometry geometry,
}) {
  // The rectangle's corners live on its own tangent plane, oriented by its
  // position angle, exactly as the native grid lays its apertures out; each
  // corner is then carried through the reference's TAN solution. That keeps
  // a drawn box and its measured apertures on the same pixels whether the
  // solution came from Skotiq's plate solve (tangent point at the image
  // centre) or from a FITS header (tangent point anywhere).
  final double theta = rectangle.rotationDeg * math.pi / 180.0;
  final double cosT = math.cos(theta);
  final double sinT = math.sin(theta);
  final double halfWidth = rectangle.widthArcsec / 2.0 / 3600.0;
  final double halfHeight = rectangle.heightArcsec / 2.0 / 3600.0;

  const List<(double, double)> unitCorners = <(double, double)>[
    (-1, -1),
    (1, -1),
    (1, 1),
    (-1, 1),
  ];

  final corners = <Offset>[];
  for (final (double su, double sv) in unitCorners) {
    final double u = su * halfWidth;
    final double v = sv * halfHeight;
    // Local tangent-plane offsets in degrees, matching the native
    // `SkyRectangle::grid` orientation: +x runs west (CD1_1 negative),
    // +y runs along the position angle.
    final double xi = -cosT * u + sinT * v;
    final double eta = sinT * u + cosT * v;
    final (double ra, double dec) = depthLockTanDeproject(
      rectangle.raDeg,
      rectangle.decDeg,
      xi,
      eta,
    );
    final projected = depthLockWorldToPixel(geometry, ra, dec);
    if (projected == null) return null;
    corners.add(projected);
  }
  return corners;
}

/// Sky → 0-based pixel through a reference's TAN solution, mirroring the
/// native `SipWcs::world_to_pixel`: gnomonic projection about
/// (CRVAL1, CRVAL2), then the inverse CD matrix, then the 1-based CRPIX
/// offset. `null` on the far hemisphere or for a singular matrix.
Offset? depthLockWorldToPixel(
    ReferenceGeometry g, double raDeg, double decDeg) {
  final double det = g.cd1_1 * g.cd2_2 - g.cd1_2 * g.cd2_1;
  if (!det.isFinite || det.abs() < 1e-18) return null;
  final projected = depthLockTanProject(g.crval1, g.crval2, raDeg, decDeg);
  if (projected == null) return null;
  final (double xi, double eta) = projected;
  final double inv = 1.0 / det;
  final double u = (g.cd2_2 * xi - g.cd1_2 * eta) * inv;
  final double v = (-g.cd2_1 * xi + g.cd1_1 * eta) * inv;
  return Offset(u + g.crpix1 - 1.0, v + g.crpix2 - 1.0);
}

/// 0-based pixel → sky (degrees, RA in [0, 360)) through a reference's TAN
/// solution; the exact inverse of [depthLockWorldToPixel].
(double, double) depthLockPixelToWorld(
    ReferenceGeometry g, double x, double y) {
  final double u = x - (g.crpix1 - 1.0);
  final double v = y - (g.crpix2 - 1.0);
  final double xi = g.cd1_1 * u + g.cd1_2 * v;
  final double eta = g.cd2_1 * u + g.cd2_2 * v;
  return depthLockTanDeproject(g.crval1, g.crval2, xi, eta);
}

/// Gnomonic projection of (ra, dec) about the tangent point (ra0, dec0);
/// all in degrees, standard coordinates out in degrees. `null` when the
/// point is on the far hemisphere.
(double, double)? depthLockTanProject(
  double ra0Deg,
  double dec0Deg,
  double raDeg,
  double decDeg,
) {
  const double d2r = math.pi / 180.0;
  final double ra0 = ra0Deg * d2r;
  final double dec0 = dec0Deg * d2r;
  final double ra = raDeg * d2r;
  final double dec = decDeg * d2r;
  final double cosC = math.sin(dec0) * math.sin(dec) +
      math.cos(dec0) * math.cos(dec) * math.cos(ra - ra0);
  if (!(cosC > 1e-12)) return null;
  final double xi = math.cos(dec) * math.sin(ra - ra0) / cosC;
  final double eta = (math.cos(dec0) * math.sin(dec) -
          math.sin(dec0) * math.cos(dec) * math.cos(ra - ra0)) /
      cosC;
  return (xi / d2r, eta / d2r);
}

/// Inverse gnomonic projection: standard coordinates (degrees) about
/// (ra0, dec0) back to (ra, dec) in degrees, RA normalised to [0, 360).
(double, double) depthLockTanDeproject(
  double ra0Deg,
  double dec0Deg,
  double xiDeg,
  double etaDeg,
) {
  const double d2r = math.pi / 180.0;
  final double ra0 = ra0Deg * d2r;
  final double dec0 = dec0Deg * d2r;
  final double xi = xiDeg * d2r;
  final double eta = etaDeg * d2r;
  final double denom = math.cos(dec0) - eta * math.sin(dec0);
  final double ra = ra0 + math.atan2(xi, denom);
  final double dec = math.atan2(
    math.sin(dec0) + eta * math.cos(dec0),
    math.sqrt(xi * xi + denom * denom),
  );
  return (_normaliseRaDeg(ra / d2r), dec / d2r);
}

double _normaliseRaDeg(double raDeg) {
  var value = raDeg % 360.0;
  if (value < 0) value += 360.0;
  return value;
}

/// The eight grips on an editable rectangle: four corners and four edge
/// midpoints.
enum DepthLockHandle {
  topLeft,
  top,
  topRight,
  right,
  bottomRight,
  bottom,
  bottomLeft,
  left;

  bool get movesLeft =>
      this == DepthLockHandle.topLeft ||
      this == DepthLockHandle.left ||
      this == DepthLockHandle.bottomLeft;

  bool get movesRight =>
      this == DepthLockHandle.topRight ||
      this == DepthLockHandle.right ||
      this == DepthLockHandle.bottomRight;

  bool get movesTop =>
      this == DepthLockHandle.topLeft ||
      this == DepthLockHandle.top ||
      this == DepthLockHandle.topRight;

  bool get movesBottom =>
      this == DepthLockHandle.bottomLeft ||
      this == DepthLockHandle.bottom ||
      this == DepthLockHandle.bottomRight;
}

/// Where [handle] sits on [rect], in the rectangle's own coordinates.
Offset depthLockHandlePosition(Rect rect, DepthLockHandle handle) => Offset(
      handle.movesLeft
          ? rect.left
          : handle.movesRight
              ? rect.right
              : rect.center.dx,
      handle.movesTop
          ? rect.top
          : handle.movesBottom
              ? rect.bottom
              : rect.center.dy,
    );

/// [rect] with [handle] dragged to [to].
///
/// Only the edges the handle owns move, so dragging the top edge changes the
/// height and nothing else. The result is normalised, so pulling an edge past
/// its opposite flips the rectangle rather than producing a negative one the
/// native converter would refuse.
Rect depthLockResize(Rect rect, DepthLockHandle handle, Offset to) {
  final double left = handle.movesLeft ? to.dx : rect.left;
  final double right = handle.movesRight ? to.dx : rect.right;
  final double top = handle.movesTop ? to.dy : rect.top;
  final double bottom = handle.movesBottom ? to.dy : rect.bottom;
  return depthLockNormalizedRect(Offset(left, top), Offset(right, bottom));
}

/// The handle of [rect] within [tolerance] of [point], or null.
///
/// Corners are tested before edges so the shared hit area at a corner grabs
/// the corner, which is the one that resizes in two directions and therefore
/// the one the pointer was aiming at.
DepthLockHandle? depthLockHandleAt(
  Rect rect,
  Offset point, {
  required double tolerance,
}) {
  const corners = <DepthLockHandle>[
    DepthLockHandle.topLeft,
    DepthLockHandle.topRight,
    DepthLockHandle.bottomRight,
    DepthLockHandle.bottomLeft,
  ];
  const edges = <DepthLockHandle>[
    DepthLockHandle.top,
    DepthLockHandle.right,
    DepthLockHandle.bottom,
    DepthLockHandle.left,
  ];
  for (final group in <List<DepthLockHandle>>[corners, edges]) {
    for (final handle in group) {
      if ((depthLockHandlePosition(rect, handle) - point).distance <=
          tolerance) {
        return handle;
      }
    }
  }
  return null;
}

/// [rect] translated by [delta], which is what dragging its interior does.
Rect depthLockMove(Rect rect, Offset delta) => rect.shift(delta);
