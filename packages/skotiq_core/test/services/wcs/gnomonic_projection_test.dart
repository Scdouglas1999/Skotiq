import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/wcs/gnomonic_projection.dart';

void main() {
  group('GnomonicProjection.worldToPixel', () {
    test('projects the centre RA/Dec to the image centre', () {
      const wcs = SolvedWcs(
        raHours: 5.5,
        decDegrees: -5.0,
        rotationDeg: 0,
        pixelScaleArcsec: 1.5,
        imageWidth: 2048,
        imageHeight: 1024,
      );
      final proj = GnomonicProjection(wcs);

      final p = proj.worldToPixel(raDegrees: 5.5 * 15.0, decDegrees: -5.0)!;

      expect(p.pixel.x, closeTo(1024.0, 1e-6));
      expect(p.pixel.y, closeTo(512.0, 1e-6));
      expect(p.onImage, isTrue);
    });

    test('forward+inverse roundtrip is identity to better than 0.001 px', () {
      // Why: the mission requires sub-millipixel accuracy for the
      // projection. Sample 25 points across the frame at a few different
      // sky positions / rotations to catch any sign-flip bug.
      final cases = <SolvedWcs>[
        const SolvedWcs(
          raHours: 0.5,
          decDegrees: 30,
          rotationDeg: 0,
          pixelScaleArcsec: 1.2,
          imageWidth: 4096,
          imageHeight: 2731,
        ),
        const SolvedWcs(
          raHours: 12.0,
          decDegrees: -45.0,
          rotationDeg: 32.5,
          pixelScaleArcsec: 0.75,
          imageWidth: 2048,
          imageHeight: 2048,
        ),
        const SolvedWcs(
          raHours: 23.9,
          decDegrees: 78.0,
          rotationDeg: -119.0,
          pixelScaleArcsec: 3.2,
          imageWidth: 1024,
          imageHeight: 768,
        ),
      ];

      for (final wcs in cases) {
        final proj = GnomonicProjection(wcs);
        for (
          var px = 16;
          px <= wcs.imageWidth - 16;
          px += wcs.imageWidth ~/ 4
        ) {
          for (
            var py = 16;
            py <= wcs.imageHeight - 16;
            py += wcs.imageHeight ~/ 4
          ) {
            final world = proj.pixelToWorld(x: px.toDouble(), y: py.toDouble());
            final back = proj.worldToPixel(
              raDegrees: world.raDegrees,
              decDegrees: world.decDegrees,
            );
            expect(back, isNotNull);
            expect(
              (back!.pixel.x - px).abs(),
              lessThan(0.001),
              reason: 'X mismatch at ($px,$py) for $wcs: got ${back.pixel.x}',
            );
            expect(
              (back.pixel.y - py).abs(),
              lessThan(0.001),
              reason: 'Y mismatch at ($px,$py) for $wcs: got ${back.pixel.y}',
            );
          }
        }
      }
    });

    test('returns null on the back hemisphere', () {
      const wcs = SolvedWcs(
        raHours: 0,
        decDegrees: 0,
        rotationDeg: 0,
        pixelScaleArcsec: 1,
        imageWidth: 1024,
        imageHeight: 1024,
      );
      final proj = GnomonicProjection(wcs);

      // Antipode is RA = 12h, Dec = 0 — denominator goes to -1.
      expect(proj.worldToPixel(raDegrees: 180, decDegrees: 0), isNull);
    });

    test('rotation correctly orients +Dec to image up', () {
      // At rotation 0, a point one arcsecond north of the centre should
      // land one pixel above the centre (pixel Y decreases upward).
      const wcs = SolvedWcs(
        raHours: 6.0,
        decDegrees: 30,
        rotationDeg: 0,
        pixelScaleArcsec: 1,
        imageWidth: 1024,
        imageHeight: 1024,
      );
      final proj = GnomonicProjection(wcs);

      final p = proj.worldToPixel(
        raDegrees: 6.0 * 15.0,
        decDegrees: 30 + 1.0 / 3600.0,
      )!;

      expect(p.pixel.x, closeTo(512.0, 1e-3));
      expect(p.pixel.y, closeTo(511.0, 1e-3));
    });

    test('360-degree rotation symmetry', () {
      // Sanity: rotating by 360 degrees should not change pixel output.
      const baseline = SolvedWcs(
        raHours: 9.0,
        decDegrees: 15,
        rotationDeg: 17.0,
        pixelScaleArcsec: 1.0,
        imageWidth: 1024,
        imageHeight: 1024,
      );
      const rotated = SolvedWcs(
        raHours: 9.0,
        decDegrees: 15,
        rotationDeg: 17.0 + 360.0,
        pixelScaleArcsec: 1.0,
        imageWidth: 1024,
        imageHeight: 1024,
      );
      final a = GnomonicProjection(baseline);
      final b = GnomonicProjection(rotated);

      const raDeg = 9.0 * 15.0 + 0.1;
      final p1 = a.worldToPixel(raDegrees: raDeg, decDegrees: 15.05)!;
      final p2 = b.worldToPixel(raDegrees: raDeg, decDegrees: 15.05)!;
      expect((p1.pixel.x - p2.pixel.x).abs(), lessThan(1e-6));
      expect((p1.pixel.y - p2.pixel.y).abs(), lessThan(1e-6));
    });
  });

  group('GnomonicProjection.computeBoundingBox', () {
    test('non-pole, non-wrap frame: bbox centred on solved RA/Dec', () {
      const wcs = SolvedWcs(
        raHours: 5.5,
        decDegrees: -5,
        rotationDeg: 0,
        pixelScaleArcsec: 1.2,
        imageWidth: 4096,
        imageHeight: 2731,
      );
      final box = GnomonicProjection(wcs).computeBoundingBox();

      expect(box.touchesPole, isFalse);
      expect(box.crossesRaWrap, isFalse);
      const centerRaDeg = 5.5 * 15.0;
      expect(
        ((box.raMinDeg + box.raMaxDeg) / 2 - centerRaDeg).abs(),
        lessThan(0.05),
      );
      expect(((box.decMinDeg + box.decMaxDeg) / 2 + 5.0).abs(), lessThan(0.05));
      // Frame is ~1.36 deg wide; bbox should be at least that wide.
      expect(box.raMaxDeg - box.raMinDeg, greaterThan(1.0));
    });

    test('frame straddling RA=0 sets crossesRaWrap', () {
      const wcs = SolvedWcs(
        raHours: 0.02,
        decDegrees: 0,
        rotationDeg: 0,
        pixelScaleArcsec: 5.0,
        imageWidth: 1024,
        imageHeight: 1024,
      );
      final box = GnomonicProjection(wcs).computeBoundingBox();

      expect(box.crossesRaWrap, isTrue);
      expect(box.raMinDeg, greaterThan(350));
      expect(box.raMaxDeg, lessThan(10));
      expect(box.containsRaDeg(0.0), isTrue);
      // Pick an RA just inside raMin to confirm wrap-aware containment.
      expect(box.containsRaDeg(box.raMinDeg + 0.01), isTrue);
      expect(box.containsRaDeg(180.0), isFalse);
    });

    test('frame near the celestial pole marks touchesPole', () {
      const wcs = SolvedWcs(
        raHours: 2.0,
        decDegrees: 89.5,
        rotationDeg: 0,
        pixelScaleArcsec: 5.0,
        imageWidth: 2048,
        imageHeight: 2048,
      );
      final box = GnomonicProjection(wcs).computeBoundingBox();

      expect(box.touchesPole, isTrue);
      // Pole-touching bboxes must accept any RA.
      expect(box.containsRaDeg(0), isTrue);
      expect(box.containsRaDeg(180), isTrue);
      // Centre is at +89.5; the upper Dec bound must include the pole itself
      // (or get there after clamping) — at very least it must be above the
      // centre Dec.
      expect(box.decMaxDeg, greaterThan(89.5));
    });

    test('south-pole frame also marks touchesPole', () {
      const wcs = SolvedWcs(
        raHours: 10,
        decDegrees: -89.7,
        rotationDeg: 0,
        pixelScaleArcsec: 4.0,
        imageWidth: 2048,
        imageHeight: 2048,
      );
      final box = GnomonicProjection(wcs).computeBoundingBox();

      expect(box.touchesPole, isTrue);
      expect(box.decMinDeg, lessThan(-89.0));
    });

    test(
      'rotated FOV keeps the bounding box large enough to enclose corners',
      () {
        const wcs = SolvedWcs(
          raHours: 18.0,
          decDegrees: 22.0,
          rotationDeg: 45.0,
          pixelScaleArcsec: 2.0,
          imageWidth: 2048,
          imageHeight: 2048,
        );
        final proj = GnomonicProjection(wcs);
        final box = proj.computeBoundingBox();

        // Each corner re-projected forward must land back inside the image.
        final corners = <(double, double)>[
          (0, 0),
          (wcs.imageWidth.toDouble(), 0),
          (0, wcs.imageHeight.toDouble()),
          (wcs.imageWidth.toDouble(), wcs.imageHeight.toDouble()),
        ];
        for (final (px, py) in corners) {
          final world = proj.pixelToWorld(x: px, y: py);
          expect(
            box.contains(raDeg: world.raDegrees, decDeg: world.decDegrees),
            isTrue,
            reason:
                'Corner ($px,$py) -> (${world.raDegrees}, ${world.decDegrees}) '
                'must fall within the bounding box',
          );
        }
      },
    );
  });

  group('SolvedWcs.isValid', () {
    test('rejects non-positive plate scale', () {
      expect(
        const SolvedWcs(
          raHours: 0,
          decDegrees: 0,
          rotationDeg: 0,
          pixelScaleArcsec: 0,
          imageWidth: 100,
          imageHeight: 100,
        ).isValid,
        isFalse,
      );
    });

    test('rejects NaN inputs', () {
      expect(
        const SolvedWcs(
          raHours: double.nan,
          decDegrees: 0,
          rotationDeg: 0,
          pixelScaleArcsec: 1,
          imageWidth: 100,
          imageHeight: 100,
        ).isValid,
        isFalse,
      );
    });

    test('accepts realistic frame from a plate solve', () {
      expect(
        const SolvedWcs(
          raHours: 5.5,
          decDegrees: -5,
          rotationDeg: 12.5,
          pixelScaleArcsec: 1.2,
          imageWidth: 4096,
          imageHeight: 2731,
        ).isValid,
        isTrue,
      );
    });
  });
}
