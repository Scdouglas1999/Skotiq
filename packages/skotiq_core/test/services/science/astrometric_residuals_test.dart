import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/science/astrometric_residuals.dart';
import 'package:skotiq_core/src/services/wcs/gnomonic_projection.dart';

// The rig's NGC 891 frame (see test/fixtures/wcs/ngc891_l0001_solve.json):
// Gaia DR3 stars, Skotiq's own detections, and ASTAP's solve with and without
// SIP. Without SIP the linear solve is about 0.7" off at the centre and 5"
// in the corners, a radial pattern from the corrector.
void main() {
  final f =
      jsonDecode(
            File(
              'test/fixtures/wcs/ngc891_l0001_solve.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  List<double> doubles(Object? l) => [
    for (final v in l! as List) (v as num).toDouble(),
  ];
  final cd = doubles(f['cd']);
  final width = f['imageWidth'] as int;
  final height = f['imageHeight'] as int;
  SolvedWcs wcs({required bool sip}) => SolvedWcs(
    raHours: (f['crval1'] as num) / 15.0,
    decDegrees: (f['crval2'] as num).toDouble(),
    rotationDeg: -21.37,
    pixelScaleArcsec: 0.788,
    imageWidth: width,
    imageHeight: height,
    cd1_1: cd[0],
    cd1_2: cd[1],
    cd2_1: cd[2],
    cd2_2: cd[3],
    aOrder: sip ? f['aOrder'] as int : 0,
    bOrder: sip ? f['bOrder'] as int : 0,
    aCoeffs: sip ? doubles(f['a']) : const [],
    bCoeffs: sip ? doubles(f['b']) : const [],
    apOrder: sip ? f['apOrder'] as int : 0,
    bpOrder: sip ? f['bpOrder'] as int : 0,
    apCoeffs: sip ? doubles(f['ap']) : const [],
    bpCoeffs: sip ? doubles(f['bp']) : const [],
  );
  final gaia = [for (final g in f['gaia'] as List) doubles(g)];
  final detections = [for (final d in f['detections'] as List) doubles(d)];

  List<ResidualPair> pairsFor(GnomonicProjection projection) {
    final pairs = <ResidualPair>[];
    for (final g in gaia) {
      final p = projection.worldToPixel(raDegrees: g[0], decDegrees: g[1]);
      if (p == null || !p.onImage) continue;
      List<double>? best;
      var bestR = 10.0;
      for (final d in detections) {
        final r = math.sqrt(
          math.pow(d[0] - p.pixel.x, 2) + math.pow(d[1] - p.pixel.y, 2),
        );
        if (r < bestR) {
          bestR = r;
          best = d;
        }
      }
      if (best == null) continue;
      pairs.add((
        detectedX: best[0],
        detectedY: best[1],
        catalogX: p.pixel.x,
        catalogY: p.pixel.y,
      ));
    }
    return pairs;
  }

  test('a linear solve shows the corrector distortion, catalog minus '
      'measured', () {
    final linear = GnomonicProjection(wcs(sip: false));
    final truth = GnomonicProjection(wcs(sip: true));
    final map = buildAstrometricResidualMap(
      pairs: pairsFor(linear),
      pixelScaleArcsec: 0.788,
      imageWidth: width,
      imageHeight: height,
      maxMatchPx: 10,
      solveHasSip: false,
    )!;
    expect(map.suggestionCode, residualCodeLinearSolveDistortion);
    expect(map.rmsArcsec, inInclusiveRange(1.0, 4.0));
    // Each vector is where the linear WCS puts the star minus where it is,
    // and the star is where the SIP solve puts it.
    var checked = 0;
    for (final v in map.vectors) {
      final sky = truth.pixelToWorld(x: v.x, y: v.y);
      final model = linear.worldToPixel(
        raDegrees: sky.raDegrees,
        decDegrees: sky.decDegrees,
      )!;
      expect(v.dxArcsec, closeTo((model.pixel.x - v.x) * 0.788, 0.5));
      expect(v.dyArcsec, closeTo((model.pixel.y - v.y) * 0.788, 0.5));
      checked++;
    }
    expect(checked, greaterThan(100));
  });

  test('a SIP solve leaves sub-arcsecond residuals and no advice', () {
    final map = buildAstrometricResidualMap(
      pairs: pairsFor(GnomonicProjection(wcs(sip: true))),
      pixelScaleArcsec: 0.788,
      imageWidth: width,
      imageHeight: height,
      maxMatchPx: 10,
      solveHasSip: true,
    )!;
    expect(map.suggestionCode, isNull);
    expect(map.rmsArcsec, lessThan(1.0));
  });

  test('random pairs inside the match radius are refused', () {
    final rng = math.Random(7);
    final pairs = <ResidualPair>[
      for (var i = 0; i < 200; i++)
        () {
          final x = rng.nextDouble() * width;
          final y = rng.nextDouble() * height;
          final r = 10 * math.sqrt(rng.nextDouble());
          final a = rng.nextDouble() * 2 * math.pi;
          return (
            detectedX: x,
            detectedY: y,
            catalogX: x + r * math.cos(a),
            catalogY: y + r * math.sin(a),
          );
        }(),
    ];
    expect(
      buildAstrometricResidualMap(
        pairs: pairs,
        pixelScaleArcsec: 0.788,
        imageWidth: width,
        imageHeight: height,
        maxMatchPx: 10,
        solveHasSip: false,
      ),
      isNull,
    );
  });

  test('legacy single-frame advice codes read as no advice', () {
    expect(residualSuggestionText('check_polar_alignment'), isNull);
    expect(residualSuggestionText('possible_cone_error'), isNull);
    expect(residualSuggestionText('possible_flexure'), isNull);
    expect(residualSuggestionText(null), isNull);
    expect(
      residualSuggestionText(residualCodeLinearSolveDistortion),
      isNotNull,
    );
  });
}
