import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/wcs/gnomonic_projection.dart';

// A real rig frame (NGC 891, 4656 x 3520, a Newtonian, so mirrored parity)
// solved by ASTAP with SIP. The truth pixels come from astropy's
// all_world2pix on the same .wcs, and the detections are Skotiq's own star
// detector on the frame, so the projection is checked against both an
// independent WCS implementation and the stars actually on the image.
Map<String, dynamic> _fixture() =>
    jsonDecode(
          File('test/fixtures/wcs/ngc891_l0001_solve.json').readAsStringSync(),
        )
        as Map<String, dynamic>;

List<double> _doubles(Object? list) => [
  for (final v in list! as List) (v as num).toDouble(),
];

SolvedWcs _wcs(Map<String, dynamic> f, {bool sip = true}) {
  final cd = _doubles(f['cd']);
  return SolvedWcs(
    raHours: (f['crval1'] as num).toDouble() / 15.0,
    decDegrees: (f['crval2'] as num).toDouble(),
    rotationDeg: SolvedWcs.rotationFromCd(
      cd1_1: cd[0],
      cd1_2: cd[1],
      cd2_1: cd[2],
      cd2_2: cd[3],
    ),
    pixelScaleArcsec: 0.788,
    imageWidth: f['imageWidth'] as int,
    imageHeight: f['imageHeight'] as int,
    cd1_1: cd[0],
    cd1_2: cd[1],
    cd2_1: cd[2],
    cd2_2: cd[3],
    aOrder: sip ? f['aOrder'] as int : 0,
    bOrder: sip ? f['bOrder'] as int : 0,
    aCoeffs: sip ? _doubles(f['a']) : const [],
    bCoeffs: sip ? _doubles(f['b']) : const [],
    apOrder: sip ? f['apOrder'] as int : 0,
    bpOrder: sip ? f['bpOrder'] as int : 0,
    apCoeffs: sip ? _doubles(f['ap']) : const [],
    bpCoeffs: sip ? _doubles(f['bp']) : const [],
  );
}

double _median(List<double> v) {
  final s = [...v]..sort();
  return s[s.length ~/ 2];
}

void main() {
  final f = _fixture();
  final gaia = [for (final g in f['gaia'] as List) _doubles(g)];
  final detections = [for (final d in f['detections'] as List) _doubles(d)];

  double nearestDetection(PixelPoint p) {
    var best = double.infinity;
    for (final d in detections) {
      final r = math.sqrt(math.pow(d[0] - p.x, 2) + math.pow(d[1] - p.y, 2));
      if (r < best) best = r;
    }
    return best;
  }

  test('the ASTAP CRPIX is the 0-based image centre the projection uses', () {
    final w = f['imageWidth'] as int;
    final h = f['imageHeight'] as int;
    expect((f['crpix1'] as num) - 1, (w - 1) / 2);
    expect((f['crpix2'] as num) - 1, (h - 1) / 2);
  });

  test('with SIP, Gaia stars land where astropy and the detector put them', () {
    final projection = GnomonicProjection(_wcs(f));
    final toTruth = <double>[];
    final toDetection = <double>[];
    for (final g in gaia) {
      final p = projection.worldToPixel(raDegrees: g[0], decDegrees: g[1])!;
      expect(p.onImage, isTrue);
      toTruth.add(
        math.sqrt(
          math.pow(p.pixel.x - g[3], 2) + math.pow(p.pixel.y - g[4], 2),
        ),
      );
      toDetection.add(nearestDetection(p.pixel));
    }
    // AP/BP is a fitted inverse; astropy iterates the forward terms.
    expect(toTruth.reduce(math.max), lessThan(0.15));
    // Saturated and blended stars have no detection of their own.
    final matched = toDetection.where((d) => d < 1.5).length;
    expect(matched, greaterThanOrEqualTo((gaia.length * 0.9).floor()));
    expect(_median(toDetection), lessThan(0.4));
  });

  test('without SIP the linear solve still finds every bright star', () {
    final projection = GnomonicProjection(_wcs(f, sip: false));
    final toDetection = [
      for (final g in gaia)
        nearestDetection(
          projection.worldToPixel(raDegrees: g[0], decDegrees: g[1])!.pixel,
        ),
    ];
    // The corrector's distortion reaches 7 px and more in the corners, so a
    // few corner stars fall outside the catalog matcher's 9 px radius.
    expect(
      toDetection.where((d) => d < 9).length,
      greaterThanOrEqualTo((gaia.length * 0.9).floor()),
    );
    expect(_median(toDetection), lessThan(3.0));
  });

  test('pixelToWorld inverts worldToPixel on the real solve', () {
    final projection = GnomonicProjection(_wcs(f));
    for (final g in gaia.take(40)) {
      final sky = projection.pixelToWorld(x: g[3], y: g[4]);
      final dRa = (sky.raDegrees - g[0]) * math.cos(g[1] * math.pi / 180);
      final dDec = sky.decDegrees - g[1];
      expect(math.sqrt(dRa * dRa + dDec * dDec) * 3600, lessThan(0.05));
    }
  });

  test('named objects land on their true pixels', () {
    final projection = GnomonicProjection(_wcs(f));
    for (final o in (f['objects'] as List).cast<Map<String, dynamic>>()) {
      final p = projection.worldToPixel(
        raDegrees: (o['ra'] as num).toDouble(),
        decDegrees: (o['dec'] as num).toDouble(),
      )!;
      expect(
        p.pixel.x,
        closeTo((o['x'] as num).toDouble(), 0.2),
        reason: '${o['name']}',
      );
      expect(
        p.pixel.y,
        closeTo((o['y'] as num).toDouble(), 0.2),
        reason: '${o['name']}',
      );
    }
  });

  test('a scalar rotation with the frame parity rebuilds the same mapping', () {
    final full = _wcs(f, sip: false);
    final scalar = SolvedWcs(
      raHours: full.raHours,
      decDegrees: full.decDegrees,
      rotationDeg: full.rotationDeg,
      pixelScaleArcsec: 0.78797,
      imageWidth: full.imageWidth,
      imageHeight: full.imageHeight,
      mirrored: true,
    );
    final a = GnomonicProjection(full);
    final b = GnomonicProjection(scalar);
    for (final g in gaia.take(40)) {
      final pa = a.worldToPixel(raDegrees: g[0], decDegrees: g[1])!.pixel;
      final pb = b.worldToPixel(raDegrees: g[0], decDegrees: g[1])!.pixel;
      expect(pb.x, closeTo(pa.x, 1.5));
      expect(pb.y, closeTo(pa.y, 1.5));
    }
  });

  test('the compass axes follow the matrix, parity included', () {
    final axes = GnomonicProjection(_wcs(f, sip: false)).skyAxesOnImage;
    // Mirrored frame: east is counterclockwise of north in buffer
    // coordinates (y down), so the cross product north x east is negative.
    expect(axes.northX * axes.eastY - axes.northY * axes.eastX, lessThan(0));
    // A standard-parity frame flips that sign.
    final standard = GnomonicProjection(
      const SolvedWcs(
        raHours: 3,
        decDegrees: 40,
        rotationDeg: -21.37,
        pixelScaleArcsec: 0.788,
        imageWidth: 4656,
        imageHeight: 3520,
      ),
    ).skyAxesOnImage;
    expect(
      standard.northX * standard.eastY - standard.northY * standard.eastX,
      greaterThan(0),
    );
  });
}
