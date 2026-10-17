import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/wcs/gnomonic_projection.dart';

// Self-consistency tests for the CD-matrix + SIP path. They assert the new
// code reduces to the isotropic path when CD/SIP are absent and round-trips
// to sub-pixel accuracy for synthetic anisotropic CD / low-order SIP. Real
// on-sky distortion accuracy still awaits validation against solved frames;
// these only verify the projection is its own inverse.

void main() {
  group('GnomonicProjection CD matrix', () {
    test('isotropic CD reproduces the scale+rotation path', () {
      const scaleArcsec = 1.7;
      const rotationDeg = 24.0;
      const scaleDeg = scaleArcsec / 3600.0;
      final cosR = math.cos(rotationDeg * math.pi / 180.0);
      final sinR = math.sin(rotationDeg * math.pi / 180.0);

      const base = SolvedWcs(
        raHours: 8.25,
        decDegrees: 17.0,
        rotationDeg: rotationDeg,
        pixelScaleArcsec: scaleArcsec,
        imageWidth: 3000,
        imageHeight: 2000,
      );
      final withCd = SolvedWcs(
        raHours: base.raHours,
        decDegrees: base.decDegrees,
        rotationDeg: base.rotationDeg,
        pixelScaleArcsec: base.pixelScaleArcsec,
        imageWidth: base.imageWidth,
        imageHeight: base.imageHeight,
        cd1_1: -scaleDeg * cosR,
        cd1_2: scaleDeg * sinR,
        cd2_1: scaleDeg * sinR,
        cd2_2: scaleDeg * cosR,
      );

      final isoProj = GnomonicProjection(base);
      final cdProj = GnomonicProjection(withCd);

      for (var px = 50; px <= base.imageWidth - 50; px += 400) {
        for (var py = 50; py <= base.imageHeight - 50; py += 400) {
          final iso = isoProj.pixelToWorld(x: px.toDouble(), y: py.toDouble());
          final cd = cdProj.pixelToWorld(x: px.toDouble(), y: py.toDouble());
          expect(cd.raDegrees, closeTo(iso.raDegrees, 1e-9));
          expect(cd.decDegrees, closeTo(iso.decDegrees, 1e-9));

          final back = cdProj.worldToPixel(
            raDegrees: cd.raDegrees,
            decDegrees: cd.decDegrees,
          )!;
          expect(back.pixel.x, closeTo(px.toDouble(), 1e-6));
          expect(back.pixel.y, closeTo(py.toDouble(), 1e-6));
        }
      }
    });

    test('anisotropic CD round-trips to sub-pixel accuracy', () {
      // Distinct row/column scales plus a small skew — what a tilted /
      // anamorphic train yields and the isotropic collapse cannot represent.
      const wcs = SolvedWcs(
        raHours: 14.0,
        decDegrees: -33.0,
        rotationDeg: 0,
        pixelScaleArcsec: 1.5,
        imageWidth: 2048,
        imageHeight: 2048,
        cd1_1: -4.1e-4,
        cd1_2: 2.3e-5,
        cd2_1: 1.8e-5,
        cd2_2: 3.7e-4,
      );
      final proj = GnomonicProjection(wcs);

      for (var px = 64; px <= wcs.imageWidth - 64; px += 256) {
        for (var py = 64; py <= wcs.imageHeight - 64; py += 256) {
          final world = proj.pixelToWorld(x: px.toDouble(), y: py.toDouble());
          final back = proj.worldToPixel(
            raDegrees: world.raDegrees,
            decDegrees: world.decDegrees,
          )!;
          expect(back.pixel.x, closeTo(px.toDouble(), 1e-4));
          expect(back.pixel.y, closeTo(py.toDouble(), 1e-4));
        }
      }
    });
  });

  group('GnomonicProjection SIP distortion', () {
    test('low-order forward SIP round-trips via Newton inverse', () {
      // 2nd-order A/B with no AP/BP — exercises the iterative inverse branch.
      const order = 2;
      final aCoeffs = List<double>.filled((order + 1) * (order + 1), 0.0);
      final bCoeffs = List<double>.filled((order + 1) * (order + 1), 0.0);
      aCoeffs[2 * (order + 1) + 0] = 2.0e-6;
      aCoeffs[1 * (order + 1) + 1] = -1.0e-6;
      bCoeffs[0 * (order + 1) + 2] = 1.5e-6;
      bCoeffs[1 * (order + 1) + 1] = 0.8e-6;

      final wcs = SolvedWcs(
        raHours: 6.0,
        decDegrees: 12.0,
        rotationDeg: 0,
        pixelScaleArcsec: 1.5,
        imageWidth: 2048,
        imageHeight: 2048,
        cd1_1: -4.0e-4,
        cd1_2: 0.0,
        cd2_1: 0.0,
        cd2_2: 4.0e-4,
        aOrder: order,
        bOrder: order,
        aCoeffs: aCoeffs,
        bCoeffs: bCoeffs,
      );
      final proj = GnomonicProjection(wcs);

      for (var px = 256; px <= wcs.imageWidth - 256; px += 256) {
        for (var py = 256; py <= wcs.imageHeight - 256; py += 256) {
          final world = proj.pixelToWorld(x: px.toDouble(), y: py.toDouble());
          final back = proj.worldToPixel(
            raDegrees: world.raDegrees,
            decDegrees: world.decDegrees,
          )!;
          expect(back.pixel.x, closeTo(px.toDouble(), 1e-3));
          expect(back.pixel.y, closeTo(py.toDouble(), 1e-3));
        }
      }
    });

    test('forward + analytic inverse SIP round-trips', () {
      // Forward A/B with matching first-order AP/BP so the inverse branch
      // (AP/BP) is taken rather than Newton.
      const order = 1;
      final aCoeffs = List<double>.filled((order + 1) * (order + 1), 0.0);
      final bCoeffs = List<double>.filled((order + 1) * (order + 1), 0.0);
      aCoeffs[0 * (order + 1) + 1] = 5.0e-5;
      bCoeffs[1 * (order + 1) + 0] = 5.0e-5;
      final apCoeffs = List<double>.filled((order + 1) * (order + 1), 0.0);
      final bpCoeffs = List<double>.filled((order + 1) * (order + 1), 0.0);
      apCoeffs[0 * (order + 1) + 1] = -5.0e-5;
      bpCoeffs[1 * (order + 1) + 0] = -5.0e-5;

      final wcs = SolvedWcs(
        raHours: 19.0,
        decDegrees: 41.0,
        rotationDeg: 10.0,
        pixelScaleArcsec: 2.0,
        imageWidth: 1600,
        imageHeight: 1200,
        cd1_1: -5.5e-4,
        cd1_2: 0.0,
        cd2_1: 0.0,
        cd2_2: 5.5e-4,
        aOrder: order,
        bOrder: order,
        aCoeffs: aCoeffs,
        bCoeffs: bCoeffs,
        apOrder: order,
        bpOrder: order,
        apCoeffs: apCoeffs,
        bpCoeffs: bpCoeffs,
      );
      final proj = GnomonicProjection(wcs);
      expect(wcs.hasInverseSip, isTrue);

      for (var px = 200; px <= wcs.imageWidth - 200; px += 200) {
        for (var py = 200; py <= wcs.imageHeight - 200; py += 200) {
          final world = proj.pixelToWorld(x: px.toDouble(), y: py.toDouble());
          final back = proj.worldToPixel(
            raDegrees: world.raDegrees,
            decDegrees: world.decDegrees,
          )!;
          expect(back.pixel.x, closeTo(px.toDouble(), 1.0));
          expect(back.pixel.y, closeTo(py.toDouble(), 1.0));
        }
      }
    });
  });
}
