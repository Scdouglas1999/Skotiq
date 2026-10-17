// Tests for the pure guide-star finder ([findGuideStarCandidates]) used by the
// framing canvas's guide-star overlay.
//
// The invariant under test: for a SEEDED FOV (a known plate scale + look
// direction on a known canvas), the finder keeps exactly the bright (V <
// maxMagnitude) catalog stars that fall INSIDE the imaging FOV, rejects the
// target itself, sorts brightest-first, caps the count, and projects each star
// through the SAME [FramingSkyProjection] the reticle uses (so a marker lands on
// the imagery to the pixel).

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/framing_guide_star.dart';
import 'package:skotiq_core/src/models/framing_hips_projection.dart';
import 'package:skotiq_core/src/models/framing_plate_scale.dart';

// A 2deg x 2deg survey cutout at 1000x1000 px -> 500 px/deg on a 1000x1000
// canvas at zoom 1.0, so 1 degree of sky == 500 logical pixels.
const _scale = FramingPlateScale(
  surveyFovWidthDeg: 2.0,
  surveyFovHeightDeg: 2.0,
  imagePixelWidth: 1000,
  imagePixelHeight: 1000,
);

const _canvas = Size(1000, 1000);
const _centerRaHours = 6.0;
const _centerDecDeg = 30.0;

FramingSkyProjection _projection({
  double zoom = 1.0,
  Offset pan = Offset.zero,
  double rotationDegrees = 0.0,
}) {
  return FramingSkyProjection.fromView(
    _canvas,
    FramingProjectionView(
      plateScale: _scale,
      previewFovDegrees: 2.0,
      centerRaHours: _centerRaHours,
      centerDecDegrees: _centerDecDeg,
      zoom: zoom,
      panX: pan.dx,
      panY: pan.dy,
      rotationDegrees: rotationDegrees,
    ),
  );
}

/// Builds a star at a tangent-plane offset (degrees east / north) from the FOV
/// center, mirroring the projection's RA-fold-by-cos(dec) so the offset is the
/// real on-sky position.
GuideStarInput _starAtOffset({
  required String id,
  required double eastDeg,
  required double northDeg,
  required double magnitude,
}) {
  final cosDec = math.cos(_centerDecDeg * math.pi / 180.0);
  final raHours = _centerRaHours + (eastDeg / cosDec) / 15.0;
  final decDeg = _centerDecDeg + northDeg;
  return GuideStarInput(
    id: id,
    name: id,
    raHours: raHours,
    decDegrees: decDeg,
    magnitude: magnitude,
  );
}

void main() {
  // A 1deg x 1deg imaging FOV, so the in/out boundary is at +/-0.5deg in each
  // axis. At 500 px/deg the FOV is 500px across, centered on the 1000px canvas.
  const fovQuery = GuideStarQuery(
    maxMagnitude: 10.0,
    fovWidthDeg: 1.0,
    fovHeightDeg: 1.0,
  );

  group('findGuideStarCandidates — seeded FOV selection', () {
    test('keeps only bright stars inside the FOV, brightest first', () {
      final stars = <GuideStarInput>[
        // Inside the FOV, bright -> KEEP.
        _starAtOffset(id: 'inA', eastDeg: 0.2, northDeg: 0.1, magnitude: 8.0),
        _starAtOffset(id: 'inB', eastDeg: -0.3, northDeg: -0.2, magnitude: 6.5),
        // Inside but too faint (V > 10) -> REJECT.
        _starAtOffset(
          id: 'faint',
          eastDeg: 0.1,
          northDeg: 0.1,
          magnitude: 11.2,
        ),
        // Just outside the FOV in RA (0.6deg > 0.5deg half-width) -> REJECT.
        _starAtOffset(id: 'outRa', eastDeg: 0.6, northDeg: 0.0, magnitude: 5.0),
        // Just outside the FOV in Dec (0.7deg > 0.5deg half-height) -> REJECT.
        _starAtOffset(
          id: 'outDec',
          eastDeg: 0.0,
          northDeg: 0.7,
          magnitude: 4.0,
        ),
        // No photometry -> REJECT (cannot be a guide star).
        const GuideStarInput(
          id: 'noMag',
          name: 'noMag',
          raHours: _centerRaHours,
          decDegrees: _centerDecDeg + 0.1,
          magnitude: null,
        ),
      ];

      final result = findGuideStarCandidates(
        projection: _projection(),
        stars: stars,
        query: fovQuery,
      );

      // Only the two bright in-FOV stars survive, brightest (lowest mag) first.
      expect(result.map((c) => c.id).toList(), ['inB', 'inA']);
      expect(result.first.magnitude, 6.5);
    });

    test('rejects the target itself at the FOV center', () {
      final stars = <GuideStarInput>[
        // Numerically at the center == the framed target.
        const GuideStarInput(
          id: 'target',
          name: 'target',
          raHours: _centerRaHours,
          decDegrees: _centerDecDeg,
          magnitude: 7.0,
        ),
        _starAtOffset(id: 'guide', eastDeg: 0.2, northDeg: 0.2, magnitude: 9.0),
      ];

      final result = findGuideStarCandidates(
        projection: _projection(),
        stars: stars,
        query: fovQuery,
      );

      expect(result.map((c) => c.id).toList(), ['guide']);
    });

    test('de-duplicates by id and caps at maxCandidates', () {
      final stars = <GuideStarInput>[
        for (var i = 0; i < 30; i++)
          _starAtOffset(
            id: 'dup', // same id -> only the first survives
            eastDeg: 0.1,
            northDeg: 0.1,
            magnitude: 5.0 + i * 0.01,
          ),
        for (var i = 0; i < 30; i++)
          _starAtOffset(
            id: 'star$i',
            eastDeg: -0.4 + i * 0.02,
            northDeg: 0.0,
            magnitude: 9.0 - i * 0.05,
          ),
      ];

      final result = findGuideStarCandidates(
        projection: _projection(),
        stars: stars,
        query: const GuideStarQuery(
          maxMagnitude: 10.0,
          fovWidthDeg: 1.0,
          fovHeightDeg: 1.0,
          maxCandidates: 5,
        ),
      );

      expect(result.length, 5);
      // 'dup' appears at most once.
      expect(result.where((c) => c.id == 'dup').length, lessThanOrEqualTo(1));
      // Sorted brightest-first (non-decreasing magnitude).
      for (var i = 1; i < result.length; i++) {
        expect(
          result[i].magnitude,
          greaterThanOrEqualTo(result[i - 1].magnitude),
        );
      }
    });

    test('returns empty for a degenerate (zero) FOV', () {
      final stars = <GuideStarInput>[
        _starAtOffset(id: 'in', eastDeg: 0.0, northDeg: 0.0, magnitude: 5.0),
      ];
      final result = findGuideStarCandidates(
        projection: _projection(),
        stars: stars,
        query: const GuideStarQuery(fovWidthDeg: 0.0, fovHeightDeg: 0.0),
      );
      expect(result, isEmpty);
    });
  });

  group('findGuideStarCandidates — query center (dragged aim)', () {
    // The FOV box dragged 0.4deg east / 0.3deg north of the view centre. The
    // inside-FOV test must measure around THIS point while the projection that
    // places the markers stays centred on the view (the sky the user sees).
    final cosDec = math.cos(_centerDecDeg * math.pi / 180.0);
    final aimRaHours = _centerRaHours + (0.4 / cosDec) / 15.0;
    const aimDecDeg = _centerDecDeg + 0.3;

    test('inside-FOV is measured around the query centre, not the projection '
        'centre', () {
      final query = GuideStarQuery(
        maxMagnitude: 10.0,
        fovWidthDeg: 1.0,
        fovHeightDeg: 1.0,
        centerRaHours: aimRaHours,
        centerDecDegrees: aimDecDeg,
      );

      final stars = <GuideStarInput>[
        // 0.6deg east of the VIEW centre: outside the unmoved box, but only
        // 0.2deg from the dragged aim -> inside the moved box.
        _starAtOffset(
          id: 'nearAim',
          eastDeg: 0.6,
          northDeg: 0.3,
          magnitude: 7.0,
        ),
        // 0.4deg west of the view centre: inside the unmoved box but 0.8deg
        // from the aim -> outside the moved box.
        _starAtOffset(
          id: 'behindBox',
          eastDeg: -0.4,
          northDeg: 0.0,
          magnitude: 6.0,
        ),
        // The view centre itself sits 0.4deg/0.3deg from the aim — still inside
        // the moved box and NOT the aim point, so it is a legitimate guide star.
        const GuideStarInput(
          id: 'viewCentre',
          name: 'viewCentre',
          raHours: _centerRaHours,
          decDegrees: _centerDecDeg,
          magnitude: 8.0,
        ),
      ];

      final withAim = findGuideStarCandidates(
        projection: _projection(),
        stars: stars,
        query: query,
      );
      expect(withAim.map((c) => c.id).toSet(), {'nearAim', 'viewCentre'});

      // Without a query centre the same stars resolve against the projection
      // centre — 'behindBox' is inside, 'nearAim' is not, and 'viewCentre' is
      // rejected as the target itself.
      final withProjection = findGuideStarCandidates(
        projection: _projection(),
        stars: stars,
        query: fovQuery,
      );
      expect(withProjection.map((c) => c.id).toList(), ['behindBox']);
    });

    test(
      'a star at the query centre is rejected as the aim, not the target',
      () {
        final query = GuideStarQuery(
          maxMagnitude: 10.0,
          fovWidthDeg: 1.0,
          fovHeightDeg: 1.0,
          centerRaHours: aimRaHours,
          centerDecDegrees: aimDecDeg,
        );
        final stars = <GuideStarInput>[
          GuideStarInput(
            id: 'atAim',
            name: 'atAim',
            raHours: aimRaHours,
            decDegrees: aimDecDeg,
            magnitude: 5.0,
          ),
          _starAtOffset(
            id: 'guide',
            eastDeg: 0.5,
            northDeg: 0.3,
            magnitude: 9.0,
          ),
        ];

        final result = findGuideStarCandidates(
          projection: _projection(),
          stars: stars,
          query: query,
        );
        expect(result.map((c) => c.id).toList(), ['guide']);
      },
    );

    test(
      'screen positions still project through the view-centre projection',
      () {
        final proj = _projection();
        final star = _starAtOffset(
          id: 's',
          eastDeg: 0.55,
          northDeg: 0.35,
          magnitude: 7.0,
        );
        final result = findGuideStarCandidates(
          projection: proj,
          stars: [star],
          query: GuideStarQuery(
            maxMagnitude: 10.0,
            fovWidthDeg: 1.0,
            fovHeightDeg: 1.0,
            centerRaHours: aimRaHours,
            centerDecDegrees: aimDecDeg,
          ),
        );
        expect(result, hasLength(1));
        // The marker lands where the VIEW-centred projection puts the star — the
        // aim only decides membership, never the marker's pixel.
        expect(
          result.single.screenPosition,
          proj.raDecToScreen(star.raHours, star.decDegrees),
        );
      },
    );
  });

  group('findGuideStarCandidates — screen registration', () {
    test('candidate screen position matches the shared projection exactly', () {
      final proj = _projection();
      final star = _starAtOffset(
        id: 's',
        eastDeg: 0.3,
        northDeg: -0.2,
        magnitude: 7.0,
      );

      final result = findGuideStarCandidates(
        projection: proj,
        stars: [star],
        query: fovQuery,
      );

      expect(result, hasLength(1));
      final expected = proj.raDecToScreen(star.raHours, star.decDegrees);
      expect(result.single.screenPosition, expected);

      // And it lands at center + (east·pxPerDeg, -north·pxPerDeg): +RA -> +x,
      // +Dec -> -y, at 500 px/deg. 0.3deg east -> +150px, 0.2deg south -> +100px.
      expect(result.single.screenPosition.dx, closeTo(500 + 150, 1e-3));
      expect(result.single.screenPosition.dy, closeTo(500 + 100, 1e-3));
    });

    test('inside-FOV test is rotation-invariant (sky-space, not screen-space)', () {
      // A star 0.45deg east is inside the 1deg FOV (half-width 0.5deg). Rotating
      // the field must NOT change whether it is selected (the inside test is in
      // sky space), though its screen position rotates.
      final star = _starAtOffset(
        id: 'edge',
        eastDeg: 0.45,
        northDeg: 0.0,
        magnitude: 6.0,
      );

      final unrotated = findGuideStarCandidates(
        projection: _projection(),
        stars: [star],
        query: fovQuery,
      );
      final rotated = findGuideStarCandidates(
        projection: _projection(rotationDegrees: 40.0),
        stars: [star],
        query: fovQuery,
      );

      expect(unrotated.map((c) => c.id), ['edge']);
      expect(rotated.map((c) => c.id), ['edge']);
      // Screen position differs under rotation (proves rotation is applied).
      expect(
        (unrotated.single.screenPosition - rotated.single.screenPosition)
            .distance,
        greaterThan(1.0),
      );
    });
  });
}
