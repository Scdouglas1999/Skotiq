import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/src/models/imaging/annotation.dart';
import 'package:skotiq_core/src/models/imaging/star_photometry.dart';
import 'package:skotiq_core/src/services/color_calibration_service.dart';
import 'package:skotiq_core/src/services/master_annotation_service.dart';
import 'package:skotiq_core/src/services/post_session_seam.dart';
import 'package:skotiq_core/src/services/wcs/gnomonic_projection.dart';

class _NoSeam implements PostSessionSeam {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// Pixel offset (east, north) in degrees on the tangent plane at
/// ([ra0], [dec0]) of the sky point ([ra], [dec]), from the textbook gnomonic
/// formula, so the tests do not check the projection against itself.
(double, double) _standard(double ra0, double dec0, double ra, double dec) {
  const d = math.pi / 180;
  final dRa = (ra - ra0) * d;
  final denominator =
      math.sin(dec0 * d) * math.sin(dec * d) +
      math.cos(dec0 * d) * math.cos(dec * d) * math.cos(dRa);
  final xi = math.cos(dec * d) * math.sin(dRa) / denominator;
  final eta =
      (math.cos(dec0 * d) * math.sin(dec * d) -
          math.sin(dec0 * d) * math.cos(dec * d) * math.cos(dRa)) /
      denominator;
  return (xi / d, eta / d);
}

void main() {
  // A master's WCS reaches the annotation overlay and the color calibrator as
  // the FITS scalars CRVAL / CRPIX / CD.
  group('a real 1.0° x 0.8° Newtonian master (NGC 891)', () {
    final f =
        jsonDecode(
              File(
                'test/fixtures/wcs/ngc891_l0001_solve.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final cd = [for (final v in f['cd'] as List) (v as num).toDouble()];
    final wcs = SolvedWcs.tryFromFits(
      crval1: (f['crval1'] as num).toDouble(),
      crval2: (f['crval2'] as num).toDouble(),
      crpix1: (f['crpix1'] as num).toDouble(),
      crpix2: (f['crpix2'] as num).toDouble(),
      cd1_1: cd[0],
      cd1_2: cd[1],
      cd2_1: cd[2],
      cd2_2: cd[3],
      imageWidth: f['imageWidth'] as int,
      imageHeight: f['imageHeight'] as int,
    )!;

    test('is mirrored and referenced at the 0-based image center', () {
      expect(wcs.isMirrored, isTrue);
      expect(wcs.referenceX, (f['crpix1'] as num) - 1);
    });

    test('puts every catalog object within 2 px of its star', () {
      // The truth pixels include the solver's SIP terms, which the master row
      // does not store; they are worth under 2 px on this frame. The linear
      // sky offsets this replaced were 3.9 px off at HIP 11185.
      final projection = GnomonicProjection(wcs);
      for (final o in (f['objects'] as List).cast<Map<String, dynamic>>()) {
        // Off the frame the solver's SIP polynomial is an extrapolation.
        final inFrame =
            (o['x'] as num) >= 0 &&
            (o['x'] as num) < wcs.imageWidth &&
            (o['y'] as num) >= 0 &&
            (o['y'] as num) < wcs.imageHeight;
        if (!inFrame) continue;
        final projected = projection.worldToPixel(
          raDegrees: (o['ra'] as num).toDouble(),
          decDegrees: (o['dec'] as num).toDouble(),
        )!;
        final error = math.sqrt(
          math.pow(projected.pixel.x - (o['x'] as num), 2) +
              math.pow(projected.pixel.y - (o['y'] as num), 2),
        );
        expect(error, lessThan(2.0), reason: '${o['name']}');
      }
      final hip = (f['objects'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((o) => o['name'] == 'HIP 11185');
      final projected = projection.worldToPixel(
        raDegrees: (hip['ra'] as num).toDouble(),
        decDegrees: (hip['dec'] as num).toDouble(),
      )!;
      expect(projected.pixel.x, closeTo(hip['x'] as num, 1.0));
      expect(projected.pixel.y, closeTo(hip['y'] as num, 1.0));
    });
  });

  group('a 5.6° field at declination 60°', () {
    // 5"/px, 4000 x 4000, north up, east left, referenced at the center.
    const scale = 5.0 / 3600.0;
    final wcs = SolvedWcs.tryFromFits(
      crval1: 30,
      crval2: 60,
      crpix1: 2000.5,
      crpix2: 2000.5,
      cd1_1: -scale,
      cd1_2: 0,
      cd2_1: 0,
      cd2_2: scale,
      imageWidth: 4000,
      imageHeight: 4000,
    )!;
    // A star 2° of right ascension east and 1.5° north of the center.
    const starRa = 32.0;
    const starDec = 61.5;
    final (xi, eta) = _standard(30, 60, starRa, starDec);
    final trueX = 1999.5 - xi / scale;
    final trueY = 1999.5 + eta / scale;

    test('the annotation lands on the star', () async {
      final service = MasterAnnotationService(
        dsoSearch:
            ({
              required double ra,
              required double dec,
              required double radiusDegrees,
              double? maxMagnitude,
            }) async => const [],
        starSearch: (_, __, {maxMagnitude}) async => [
          const Star(
            id: 'HIP 1',
            name: 'Segin',
            coordinates: CelestialCoordinate(ra: starRa / 15.0, dec: starDec),
            magnitude: 3.0,
          ),
        ],
      );

      final layer = await service.annotate(wcs: wcs);

      final Annotation marker = layer.items.single;
      // The linear sky offsets this replaced put it 33 px away.
      expect(marker.x, closeTo(trueX, 0.01));
      expect(marker.y, closeTo(trueY, 0.01));
    });

    test('color calibration matches a detection to its catalog star', () {
      final service = ColorCalibrationService(
        seam: _NoSeam(),
        starSearch: (_, __, {maxMagnitude}) async => const [],
      );

      final matched = service.crossMatch(
        photometry: StarPhotometryResult(
          width: 4000,
          height: 4000,
          channels: 3,
          stars: [
            DetectedStarPhotometry(
              x: trueX,
              y: trueY,
              flux: 1000,
              snr: 50,
              hfr: 2,
              fwhm: 3,
              eccentricity: 0.1,
              peak: 1000,
              channelFlux: const [1000, 900, 800],
            ),
          ],
        ),
        wcs: wcs,
        catalog: const [
          Star(
            id: 'HIP 1',
            name: 'HIP 1',
            coordinates: CelestialCoordinate(ra: starRa / 15.0, dec: starDec),
            magnitude: 8,
            colorIndex: 0.65,
          ),
        ],
        channels: 3,
      );

      expect(matched, hasLength(1));
      expect(matched.single.separationArcsec, lessThan(0.1));
    });
  });
}
