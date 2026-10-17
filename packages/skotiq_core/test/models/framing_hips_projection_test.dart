// Tests for the shared sky <-> screen projection used by the HiPS framing tile
// layer ([FramingSkyProjection], [FramingProjectionView] and the
// [FramingPlateScaleResolution.resolveForCanvas] mirror).
//
// These pin the projection to the framing render-path conventions:
//   * plate-scale resolution must be byte-identical to
//     `FramingCanvas._resolvePlateScale`
//     (`packages/skotiq_app/lib/screens/framing/widgets/framing_canvas.dart`
//     lines 89-111);
//   * the sky sign convention must match `FramingProvider._recenterFromPan`
//     (`framing_provider.dart` lines 798-818): +pan x -> decreasing RA,
//     +pan y -> increasing Dec, north up;
//   * forward and inverse must round-trip;
//   * rotation must be rotate-about-canvas-center, matching
//     `FramingSurveyImagePainter.paint`.

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/framing_hips_projection.dart';
import 'package:skotiq_core/src/models/framing_plate_scale.dart';

const _loadedScale = FramingPlateScale(
  surveyFovWidthDeg: 2.0,
  surveyFovHeightDeg: 2.0,
  imagePixelWidth: 800,
  imagePixelHeight: 800,
);

FramingProjectionView _view({
  FramingPlateScale? plateScale = _loadedScale,
  double previewFovDegrees = 5.0,
  double centerRaHours = 6.0,
  double centerDecDegrees = 30.0,
  double zoom = 1.0,
  double panX = 0.0,
  double panY = 0.0,
  double rotationDegrees = 0.0,
}) {
  return FramingProjectionView(
    plateScale: plateScale,
    previewFovDegrees: previewFovDegrees,
    centerRaHours: centerRaHours,
    centerDecDegrees: centerDecDegrees,
    zoom: zoom,
    panX: panX,
    panY: panY,
    rotationDegrees: rotationDegrees,
  );
}

void main() {
  group('FramingPlateScaleResolution.resolveForCanvas', () {
    test('returns the loaded plate scale verbatim when present', () {
      final resolved = FramingPlateScaleResolution.resolveForCanvas(
        const Size(1280, 800),
        _view(plateScale: _loadedScale),
      );
      expect(resolved, same(_loadedScale));
    });

    test(
      'mirrors FramingCanvas._resolvePlateScale for the no-image fallback',
      () {
        // Byte-identical to framing_canvas.dart:99-110: pixelHeight=1000,
        // pixelWidth = round(1000 * aspect), FOV width = previewFov, FOV height =
        // previewFov / aspect.
        const canvas = Size(1280, 800);
        const previewFov = 5.0;
        final resolved = FramingPlateScaleResolution.resolveForCanvas(
          canvas,
          _view(plateScale: null, previewFovDegrees: previewFov),
        );

        final aspect = canvas.width / canvas.height; // 1.6
        expect(resolved.imagePixelHeight, 1000);
        expect(resolved.imagePixelWidth, (1000 * aspect).round()); // 1600
        expect(resolved.surveyFovWidthDeg, previewFov);
        expect(resolved.surveyFovHeightDeg, closeTo(previewFov / aspect, 1e-9));
      },
    );

    test('falls back to unit aspect for an empty canvas', () {
      final resolved = FramingPlateScaleResolution.resolveForCanvas(
        Size.zero,
        _view(plateScale: null, previewFovDegrees: 5.0),
      );
      expect(resolved.imagePixelWidth, 1000);
      expect(resolved.imagePixelHeight, 1000);
      expect(resolved.surveyFovWidthDeg, 5.0);
      expect(resolved.surveyFovHeightDeg, 5.0);
    });
  });

  group('FramingSkyProjection registration with FramingPlateScale', () {
    test('canvas center projects to the target RA/Dec', () {
      const canvas = Size(1000, 1000);
      final proj = FramingSkyProjection.fromView(canvas, _view());

      final center = proj.raDecToScreen(6.0, 30.0);
      expect(center.dx, closeTo(500.0, 1e-6));
      expect(center.dy, closeTo(500.0, 1e-6));
    });

    test('pixelsPerDegree matches the shared plate scale exactly', () {
      const canvas = Size(1000, 1000);
      const zoom = 1.5;
      final proj = FramingSkyProjection.fromView(canvas, _view(zoom: zoom));
      expect(
        proj.pixelsPerDegree,
        closeTo(_loadedScale.pixelsPerDegree(canvas, zoom), 1e-12),
      );
    });

    test('a sky offset lands at canvas center + Δdeg·pxPerDeg relative to the '
        'survey draw rect center (overlay registration)', () {
      // This is the registration invariant the overlays rely on: a sky point at
      // angular offset Δ from center maps to drawRect.center + (sign·Δ·pxPerDeg).
      const canvas = Size(1000, 1000);
      const pan = Offset(40, -25);
      final view = _view(panX: pan.dx, panY: pan.dy);
      final proj = FramingSkyProjection.fromView(canvas, view);

      final drawRect = _loadedScale.drawRectFor(canvas, 1.0, pan);
      final pxPerDeg = _loadedScale.pixelsPerDegree(canvas, 1.0);

      // Point 0.5deg east (RA +) and 0.25deg north (Dec +) of center.
      const dRaDeg = 0.5;
      const dDecDeg = 0.25;
      final raHours = 6.0 + dRaDeg / math.cos(30.0 * math.pi / 180) / 15.0;
      const decDeg = 30.0 + dDecDeg;

      final screen = proj.raDecToScreen(raHours, decDeg);

      // +RA -> +x (because +pan x lowers the center RA), +Dec -> -y (north up).
      expect(screen.dx, closeTo(drawRect.center.dx + dRaDeg * pxPerDeg, 1e-4));
      expect(screen.dy, closeTo(drawRect.center.dy - dDecDeg * pxPerDeg, 1e-4));
    });
  });

  group('Sign convention matches FramingProvider._recenterFromPan', () {
    test('+pan x moves the same sky point right and reveals decreasing RA', () {
      const canvas = Size(1000, 1000);
      // Where does the center-target land when we pan right by 100px?
      final proj = FramingSkyProjection.fromView(canvas, _view(panX: 100));
      final pos = proj.raDecToScreen(6.0, 30.0);
      // The target was at center; panning right moves it right by 100px.
      expect(pos.dx, closeTo(600.0, 1e-6));
      expect(pos.dy, closeTo(500.0, 1e-6));

      // The sky now under the canvas center has *decreased* RA (west revealed),
      // exactly mirroring FramingProvider._recenterFromPan:
      //   raOffsetHours = (-raDisplacementDeg / 15) / cos(dec),
      //   raDisplacementDeg = panX / pxPerDeg.
      final atCenter = proj.screenToRaDec(const Offset(500, 500));
      final pxPerDeg = _loadedScale.pixelsPerDegree(canvas, 1.0);
      final raDisplacementDeg = 100 / pxPerDeg;
      final expectedRaHours =
          (6.0 + (-raDisplacementDeg / 15.0) / math.cos(30.0 * math.pi / 180)) %
          24.0;
      expect(atCenter.raHours, closeTo(expectedRaHours, 1e-6));
    });

    test('+pan y reveals increasing Dec (north) at the canvas center', () {
      const canvas = Size(1000, 1000);
      final proj = FramingSkyProjection.fromView(canvas, _view(panY: 100));
      final atCenter = proj.screenToRaDec(const Offset(500, 500));
      final pxPerDeg = _loadedScale.pixelsPerDegree(canvas, 1.0);
      final expectedDec = 30.0 + 100 / pxPerDeg;
      expect(atCenter.decDegrees, closeTo(expectedDec, 1e-6));
    });
  });

  group('Forward/inverse round-trip', () {
    test('screenToRaDec ∘ raDecToScreen is identity over a grid', () {
      const canvas = Size(1280, 800);
      final view = _view(zoom: 1.7, panX: 37, panY: -52, rotationDegrees: 23.0);
      final proj = FramingSkyProjection.fromView(canvas, view);

      for (final sx in [0.0, 200.0, 640.0, 1100.0, 1280.0]) {
        for (final sy in [0.0, 150.0, 400.0, 800.0]) {
          final screen = Offset(sx, sy);
          final sky = proj.screenToRaDec(screen);
          final back = proj.raDecToScreen(sky.raHours, sky.decDegrees);
          expect(
            back.dx,
            closeTo(screen.dx, 1e-3),
            reason: 'dx mismatch at $screen',
          );
          expect(
            back.dy,
            closeTo(screen.dy, 1e-3),
            reason: 'dy mismatch at $screen',
          );
        }
      }
    });

    test('round-trips across the 0h/24h RA seam', () {
      const canvas = Size(1000, 1000);
      // Center the look direction right at 0h so the visible field straddles the
      // 24h -> 0h wrap.
      final view = _view(centerRaHours: 0.0, centerDecDegrees: 0.0, zoom: 1.0);
      final proj = FramingSkyProjection.fromView(canvas, view);

      // A point a little west of center wraps to ~23.9h; it must still project
      // to just left/right of center, not jump a whole revolution.
      const raJustBelowWrap = 23.95;
      final screen = proj.raDecToScreen(raJustBelowWrap, 0.5);
      final sky = proj.screenToRaDec(screen);
      // Compare on the circle.
      var dRa = (sky.raHours - raJustBelowWrap).abs();
      if (dRa > 12) dRa = 24 - dRa;
      expect(dRa, closeTo(0.0, 1e-6));
      expect(sky.decDegrees, closeTo(0.5, 1e-6));
    });
  });

  group('Rotation is rotate-about-canvas-center', () {
    test('a 90deg rotation maps the +x screen direction to +y', () {
      const canvas = Size(1000, 1000);
      final unrot = FramingSkyProjection.fromView(canvas, _view());
      final rot90 = FramingSkyProjection.fromView(
        canvas,
        _view(rotationDegrees: 90),
      );

      // Take the sky point that (unrotated) sits 100px to the right of center.
      final skyRight = unrot.screenToRaDec(const Offset(600, 500));
      // Under +90deg rotation that same sky point must move to 100px *below*
      // center (rotate-about-center: (dx,dy) -> (dx·cos-dy·sin, dx·sin+dy·cos),
      // with +90deg: (100,0) -> (0,100)).
      final pos = rot90.raDecToScreen(skyRight.raHours, skyRight.decDegrees);
      expect(pos.dx, closeTo(500.0, 1e-3));
      expect(pos.dy, closeTo(600.0, 1e-3));
    });
  });

  group('arcsecPerPixel for Norder selection', () {
    test('is 3600 / pixelsPerDegree', () {
      const canvas = Size(1000, 1000);
      final proj = FramingSkyProjection.fromView(canvas, _view());
      expect(proj.arcsecPerPixel, closeTo(3600.0 / proj.pixelsPerDegree, 1e-9));
    });

    test('halves when zoom doubles (finer resolution -> higher Norder)', () {
      const canvas = Size(1000, 1000);
      final z1 = FramingSkyProjection.fromView(canvas, _view(zoom: 1.0));
      final z2 = FramingSkyProjection.fromView(canvas, _view(zoom: 2.0));
      expect(z2.arcsecPerPixel, closeTo(z1.arcsecPerPixel / 2.0, 1e-9));
    });

    test('is infinite (surfaced, not silent) for a degenerate scale', () {
      // A zero-FOV plate scale yields zero px/deg; arcsecPerPixel must surface
      // the degeneracy rather than dividing silently.
      const degenerate = FramingPlateScale(
        surveyFovWidthDeg: 0.0,
        surveyFovHeightDeg: 0.0,
        imagePixelWidth: 800,
        imagePixelHeight: 800,
      );
      final proj = FramingSkyProjection.fromResolved(
        plateScale: degenerate,
        canvasSize: const Size(1000, 1000),
        centerRaHours: 6.0,
        centerDecDegrees: 30.0,
        zoom: 1.0,
        pan: Offset.zero,
        rotationDegrees: 0.0,
      );
      expect(proj.arcsecPerPixel, double.infinity);
      expect(
        () => proj.screenToRaDec(const Offset(500, 500)),
        throwsStateError,
      );
    });
  });

  group('visibleSkyCorners', () {
    test('returns the four canvas corners in clockwise order', () {
      const canvas = Size(1280, 800);
      final proj = FramingSkyProjection.fromView(canvas, _view());
      final corners = proj.visibleSkyCorners();
      expect(corners.length, 4);

      // The corners must match projecting each canvas corner individually.
      final tl = proj.screenToRaDec(Offset.zero);
      final tr = proj.screenToRaDec(const Offset(1280, 0));
      final br = proj.screenToRaDec(const Offset(1280, 800));
      final bl = proj.screenToRaDec(const Offset(0, 800));
      expect(corners[0].raHours, closeTo(tl.raHours, 1e-9));
      expect(corners[1].raHours, closeTo(tr.raHours, 1e-9));
      expect(corners[2].decDegrees, closeTo(br.decDegrees, 1e-9));
      expect(corners[3].decDegrees, closeTo(bl.decDegrees, 1e-9));
    });
  });

  group('FramingProjectionView value semantics', () {
    test('== and hashCode are structural', () {
      final a = _view();
      final b = _view();
      final c = _view(zoom: 2.0);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });
  });
}
