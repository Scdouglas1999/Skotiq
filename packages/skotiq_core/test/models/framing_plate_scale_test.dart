// Tests for [FramingPlateScale] — the single source of truth for the framing
// canvas's astrometric scale.
//
// These pin the geometry to `FramingSurveyImagePainter`'s fit-to-canvas math
// (see
// `packages/skotiq_app/lib/screens/framing/painters/framing_background_painters.dart`,
// lines 28-42). If the painter's draw math changes, these must change in
// lock-step — they are two views of the same geometry.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/framing_plate_scale.dart';

void main() {
  group('FramingPlateScale.pixelsPerDegree', () {
    test('is identical whether the image is letterboxed horizontally or '
        'vertically relative to the canvas', () {
      // A square survey cutout: 2.0deg x 2.0deg, 800x800px. Because the FOV
      // aspect equals the pixel aspect, the angular scale must be isotropic and
      // therefore identical regardless of which fit branch (width-pinned vs
      // height-pinned) the canvas aspect selects.
      const scale = FramingPlateScale(
        surveyFovWidthDeg: 2.0,
        surveyFovHeightDeg: 2.0,
        imagePixelWidth: 800,
        imagePixelHeight: 800,
      );

      // Landscape canvas: imageAspect (1.0) <= canvasAspect (1.5) -> the image
      // is letterboxed left/right, height pinned to canvas height.
      const landscapeCanvas = Size(1200, 800);
      // Portrait canvas: imageAspect (1.0) > canvasAspect (0.667) -> the image
      // is letterboxed top/bottom, width pinned to canvas width.
      const portraitCanvas = Size(800, 1200);

      final landscapePxPerDeg = scale.pixelsPerDegree(landscapeCanvas, 1.0);
      final portraitPxPerDeg = scale.pixelsPerDegree(portraitCanvas, 1.0);

      // For the square image, the constraining extent is 800px in both cases
      // (canvas height in landscape, canvas width in portrait), so px/deg is
      // 800 / 2.0 = 400 in both orientations.
      expect(landscapePxPerDeg, closeTo(400.0, 1e-9));
      expect(portraitPxPerDeg, closeTo(400.0, 1e-9));
      expect(landscapePxPerDeg, closeTo(portraitPxPerDeg, 1e-9));
    });

    test('width-pinned case yields the expected px/deg', () {
      // 2.0deg-wide survey, 800px image, fit into a 1000px-wide canvas where
      // the image is wider than the canvas so the width is pinned.
      //
      // imageAspect = 800/400 = 2.0; canvasAspect = 1000/1000 = 1.0; since
      // imageAspect > canvasAspect, drawWidth = canvasWidth * zoom = 1000, and
      // px/deg = drawWidth / surveyFovWidthDeg = 1000 / 2.0 = 500.
      const scale = FramingPlateScale(
        surveyFovWidthDeg: 2.0,
        surveyFovHeightDeg: 1.0,
        imagePixelWidth: 800,
        imagePixelHeight: 400,
      );

      const canvas = Size(1000, 1000);
      expect(scale.pixelsPerDegree(canvas, 1.0), closeTo(500.0, 1e-9));
    });

    test('scales linearly with zoom', () {
      const scale = FramingPlateScale(
        surveyFovWidthDeg: 2.0,
        surveyFovHeightDeg: 2.0,
        imagePixelWidth: 800,
        imagePixelHeight: 800,
      );
      const canvas = Size(1000, 1000);

      final atOne = scale.pixelsPerDegree(canvas, 1.0);
      final atTwo = scale.pixelsPerDegree(canvas, 2.0);
      final atHalf = scale.pixelsPerDegree(canvas, 0.5);

      expect(atTwo, closeTo(atOne * 2.0, 1e-9));
      expect(atHalf, closeTo(atOne * 0.5, 1e-9));
    });
  });

  group('FramingPlateScale.drawRectFor', () {
    test('centers the draw rect on the canvas when pan is zero', () {
      const scale = FramingPlateScale(
        surveyFovWidthDeg: 2.0,
        surveyFovHeightDeg: 2.0,
        imagePixelWidth: 800,
        imagePixelHeight: 800,
      );
      const canvas = Size(1000, 1000);

      final rect = scale.drawRectFor(canvas, 1.0, Offset.zero);

      expect(rect.center.dx, closeTo(500.0, 1e-9));
      expect(rect.center.dy, closeTo(500.0, 1e-9));
      // Square image fit into a square canvas at zoom 1.0 fills it exactly.
      expect(rect.width, closeTo(1000.0, 1e-9));
      expect(rect.height, closeTo(1000.0, 1e-9));
    });

    test('offsets the draw rect by pan', () {
      const scale = FramingPlateScale(
        surveyFovWidthDeg: 2.0,
        surveyFovHeightDeg: 2.0,
        imagePixelWidth: 800,
        imagePixelHeight: 800,
      );
      const canvas = Size(1000, 1000);
      const pan = Offset(120, -45);

      final rect = scale.drawRectFor(canvas, 1.0, pan);

      // Center is canvas center displaced by pan.
      expect(rect.center.dx, closeTo(500.0 + 120, 1e-9));
      expect(rect.center.dy, closeTo(500.0 - 45, 1e-9));
      // Size is unaffected by pan.
      expect(rect.width, closeTo(1000.0, 1e-9));
      expect(rect.height, closeTo(1000.0, 1e-9));
    });

    test(
      'matches FramingSurveyImagePainter draw math for a non-square image',
      () {
        // imageAspect = 800/400 = 2.0; canvasAspect = 1000/1000 = 1.0.
        // imageAspect > canvasAspect -> drawWidth = 1000 * zoom, drawHeight =
        // drawWidth / imageAspect.
        const scale = FramingPlateScale(
          surveyFovWidthDeg: 2.0,
          surveyFovHeightDeg: 1.0,
          imagePixelWidth: 800,
          imagePixelHeight: 400,
        );
        const canvas = Size(1000, 1000);
        const zoom = 1.5;
        const pan = Offset(10, 20);

        final rect = scale.drawRectFor(canvas, zoom, pan);

        const expectedWidth = 1000 * zoom; // 1500
        const expectedHeight = expectedWidth / 2.0; // 750
        expect(rect.width, closeTo(expectedWidth, 1e-9));
        expect(rect.height, closeTo(expectedHeight, 1e-9));
        expect(rect.center.dx, closeTo(500.0 + 10, 1e-9));
        expect(rect.center.dy, closeTo(500.0 + 20, 1e-9));
      },
    );
  });

  group('FramingPlateScale value semantics', () {
    test('== and hashCode are structural', () {
      const a = FramingPlateScale(
        surveyFovWidthDeg: 2.0,
        surveyFovHeightDeg: 1.0,
        imagePixelWidth: 800,
        imagePixelHeight: 400,
      );
      const b = FramingPlateScale(
        surveyFovWidthDeg: 2.0,
        surveyFovHeightDeg: 1.0,
        imagePixelWidth: 800,
        imagePixelHeight: 400,
      );
      const c = FramingPlateScale(
        surveyFovWidthDeg: 2.0,
        surveyFovHeightDeg: 1.0,
        imagePixelWidth: 800,
        imagePixelHeight: 401,
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });

    test('copyWith overrides only the provided fields', () {
      const base = FramingPlateScale(
        surveyFovWidthDeg: 2.0,
        surveyFovHeightDeg: 1.0,
        imagePixelWidth: 800,
        imagePixelHeight: 400,
      );

      final widened = base.copyWith(surveyFovWidthDeg: 3.0);
      expect(widened.surveyFovWidthDeg, 3.0);
      expect(widened.surveyFovHeightDeg, base.surveyFovHeightDeg);
      expect(widened.imagePixelWidth, base.imagePixelWidth);
      expect(widened.imagePixelHeight, base.imagePixelHeight);

      final resized = base.copyWith(imagePixelHeight: 600);
      expect(resized.imagePixelHeight, 600);
      expect(resized.surveyFovWidthDeg, base.surveyFovWidthDeg);
    });
  });
}
