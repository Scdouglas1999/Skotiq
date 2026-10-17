// The pixel conventions DepthLock depends on, checked against the projection
// the preview actually draws with.
//
// These are the part of the feature that cannot be seen to be wrong: a sign
// error in the CD matrix puts a goal's rectangle somewhere plausible on the
// frame and nothing on screen says otherwise. So the reference geometry is
// asserted by round-tripping it through the same gnomonic projection the
// overlay uses.

import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/depthlock/depthlock_geometry.dart';
import 'package:skotiq_core/skotiq_core.dart';

const SolvedWcs _wcs = SolvedWcs(
  raHours: 13.4980,
  decDegrees: 47.1952,
  rotationDeg: 23.5,
  pixelScaleArcsec: 1.04,
  imageWidth: 4144,
  imageHeight: 2822,
);

/// Sky position of a pixel through the frozen reference geometry, computed the
/// way the native sampler does: 0-based pixel, FITS 1-based CRPIX, CD straight
/// to the tangent plane.
({double ra, double dec}) _referenceWorld(
  ReferenceGeometry geometry,
  double x,
  double y,
) {
  final double u = x - (geometry.crpix1 - 1.0);
  final double v = y - (geometry.crpix2 - 1.0);
  final double xi = geometry.cd1_1 * u + geometry.cd1_2 * v;
  final double eta = geometry.cd2_1 * u + geometry.cd2_2 * v;
  // Inverse gnomonic, Calabretta & Greisen 2002 §5.1.3.
  final double xiRad = xi * math.pi / 180.0;
  final double etaRad = eta * math.pi / 180.0;
  final double ra0 = geometry.crval1 * math.pi / 180.0;
  final double dec0 = geometry.crval2 * math.pi / 180.0;
  final double rho = math.sqrt(xiRad * xiRad + etaRad * etaRad);
  if (rho < 1e-12) {
    return (ra: geometry.crval1, dec: geometry.crval2);
  }
  final double c = math.atan(rho);
  final double sinC = math.sin(c);
  final double cosC = math.cos(c);
  final double dec = math.asin(
    cosC * math.sin(dec0) + etaRad * sinC * math.cos(dec0) / rho,
  );
  final double ra = ra0 +
      math.atan2(
        xiRad * sinC,
        rho * math.cos(dec0) * cosC - etaRad * math.sin(dec0) * sinC,
      );
  var raDeg = (ra * 180.0 / math.pi) % 360.0;
  if (raDeg < 0) raDeg += 360.0;
  return (ra: raDeg, dec: dec * 180.0 / math.pi);
}

void main() {
  test('a drag rectangle normalises whichever way it was dragged', () {
    const a = Offset(120, 300);
    const b = Offset(40, 80);
    final rect = depthLockNormalizedRect(a, b);
    expect(rect.left, 40);
    expect(rect.top, 80);
    expect(rect.right, 120);
    expect(rect.bottom, 300);
    expect(depthLockNormalizedRect(b, a), rect);
  });

  test('the reference geometry puts pixels where the preview puts them', () {
    final geometry = depthLockReferenceFromSolvedWcs(_wcs)!;
    final projection = GnomonicProjection(_wcs);

    for (final point in const <Offset>[
      Offset(0, 0),
      Offset(2072, 1411),
      Offset(4143, 2821),
      Offset(900, 2400),
    ]) {
      final preview = projection.pixelToWorld(x: point.dx, y: point.dy);
      final reference = _referenceWorld(geometry, point.dx, point.dy);
      // Half a milliarcsecond: far below the 1.04"/px plate scale, so any
      // real sign or convention error would fail by orders of magnitude.
      expect(
        reference.ra,
        closeTo(preview.raDegrees, 1e-7),
        reason: 'RA disagrees at $point',
      );
      expect(
        reference.dec,
        closeTo(preview.decDegrees, 1e-7),
        reason: 'Dec disagrees at $point',
      );
    }
  });

  test('the reference pixel scale matches the frame it came from', () {
    final geometry = depthLockReferenceFromSolvedWcs(_wcs)!;
    expect(geometry.pixelScaleArcsec, closeTo(_wcs.pixelScaleArcsec, 1e-9));
    expect(geometry.width, _wcs.imageWidth);
    expect(geometry.height, _wcs.imageHeight);
  });

  test('a pole-adjacent solve cannot anchor a region', () {
    const polar = SolvedWcs(
      raHours: 2,
      decDegrees: 89.2,
      rotationDeg: 0,
      pixelScaleArcsec: 1.04,
      imageWidth: 1000,
      imageHeight: 1000,
    );
    expect(depthLockReferenceFromSolvedWcs(polar), isNull);
  });

  test('a stored rectangle comes back to the pixels it was drawn on', () {
    final geometry = depthLockReferenceFromSolvedWcs(_wcs)!;
    // A 200 x 140 pixel box near the centre of the frame.
    const double x0 = 1900;
    const double y0 = 1300;
    const double x1 = 2100;
    const double y1 = 1440;
    final centre = _referenceWorld(geometry, (x0 + x1) / 2, (y0 + y1) / 2);
    final rectangle = SkyRectangle(
      raDeg: centre.ra,
      decDeg: centre.dec,
      widthArcsec: (x1 - x0) * _wcs.pixelScaleArcsec,
      heightArcsec: (y1 - y0) * _wcs.pixelScaleArcsec,
      // The native converter reports the position angle of image +y as
      // `atan2(cd1_2, cd2_2)`, which for this geometry is the frame rotation
      // turned through half a circle because image +y points south.
      rotationDeg: math.atan2(geometry.cd1_2, geometry.cd2_2) * 180.0 / math.pi,
    );

    final corners = depthLockRectangleCorners(
      rectangle: rectangle,
      geometry: geometry,
    )!;
    final xs = corners.map((c) => c.dx).toList()..sort();
    final ys = corners.map((c) => c.dy).toList()..sort();
    // Within a pixel: the corners are re-derived through a small-angle offset
    // on the tangent plane rather than the exact inverse, which is far finer
    // than the stroke that draws them.
    expect(xs.first, closeTo(x0, 1.0));
    expect(xs.last, closeTo(x1, 1.0));
    expect(ys.first, closeTo(y0, 1.0));
    expect(ys.last, closeTo(y1, 1.0));
  });

  test('the TAN projection matches the native solver on a header geometry', () {
    // The synthetic night's reference: 2"/px, north up, east left, tangent
    // point at the FITS centre — and, for the second case, a header whose
    // tangent point is nowhere near the centre.
    const centred = ReferenceGeometry(
      width: 512,
      height: 384,
      crval1: 90.0,
      crval2: 30.0,
      crpix1: 256.5,
      crpix2: 192.5,
      cd1_1: -2.0 / 3600.0,
      cd1_2: 0.0,
      cd2_1: 0.0,
      cd2_2: 2.0 / 3600.0,
    );
    // The goal the native API created at reference pixel (200, 150).
    final pixel = depthLockWorldToPixel(
      centred,
      90.03559499248212,
      29.976939660226954,
    )!;
    expect(pixel.dx, closeTo(200.0, 1e-4));
    expect(pixel.dy, closeTo(150.0, 1e-4));

    const offCentre = ReferenceGeometry(
      width: 512,
      height: 384,
      crval1: 83.82,
      crval2: -5.39,
      crpix1: 40.0,
      crpix2: 700.0,
      cd1_1: -1.3e-4,
      cd1_2: 3.1e-4,
      cd2_1: 3.1e-4,
      cd2_2: 1.3e-4,
    );
    for (final (double x, double y) in const <(double, double)>[
      (0, 0),
      (511, 383),
      (200, 150),
      (39, 699),
    ]) {
      final (ra, dec) = depthLockPixelToWorld(offCentre, x, y);
      final back = depthLockWorldToPixel(offCentre, ra, dec)!;
      expect(back.dx, closeTo(x, 1e-6), reason: 'x at ($x,$y)');
      expect(back.dy, closeTo(y, 1e-6), reason: 'y at ($x,$y)');
    }

    // A rectangle centred on a pixel projects back onto it, for either
    // geometry: the drawn box and the measured apertures share pixels.
    for (final geometry in <ReferenceGeometry>[centred, offCentre]) {
      final (ra, dec) = depthLockPixelToWorld(geometry, 200, 150);
      final corners = depthLockRectangleCorners(
        rectangle: SkyRectangle(
          raDeg: ra,
          decDeg: dec,
          widthArcsec: 40,
          heightArcsec: 40,
          rotationDeg:
              math.atan2(geometry.cd1_2, geometry.cd2_2) * 180 / math.pi,
        ),
        geometry: geometry,
      )!;
      final cx = corners.map((c) => c.dx).reduce((a, b) => a + b) / 4;
      final cy = corners.map((c) => c.dy).reduce((a, b) => a + b) / 4;
      expect(cx, closeTo(200, 1e-3));
      expect(cy, closeTo(150, 1e-3));
      final side = (corners[0] - corners[1]).distance;
      expect(side, closeTo(40 / geometry.pixelScaleArcsec, 1e-3));
    }
  });
}
