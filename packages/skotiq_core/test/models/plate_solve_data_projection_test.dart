import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/annotation_data.dart';
import 'package:skotiq_core/src/services/wcs/wcs_sip_codec.dart';

// Annotation labels and click-to-identify on the rig's NGC 891 frame (a
// Newtonian, so mirrored parity), against astropy's all_world2pix on ASTAP's
// own .wcs. Before the fix HIP 11185 was labeled 29.5' from the star, PGC 9150
// (off the frame) was labeled inside it, and NGC 898 was dropped.
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
  final solve = PlateSolveData(
    ra: (f['crval1'] as num).toDouble(),
    dec: (f['crval2'] as num).toDouble(),
    pixelScale: 0.788,
    rotation: -21.37,
    fieldWidth: width * 0.788 / 3600,
    fieldHeight: height * 0.788 / 3600,
    imageWidth: width,
    imageHeight: height,
    cd1_1: cd[0],
    cd1_2: cd[1],
    cd2_1: cd[2],
    cd2_2: cd[3],
    sip: encodeSolvedSip(
      aOrder: f['aOrder'] as int,
      bOrder: f['bOrder'] as int,
      aCoeffs: doubles(f['a']),
      bCoeffs: doubles(f['b']),
      apOrder: f['apOrder'] as int,
      bpOrder: f['bpOrder'] as int,
      apCoeffs: doubles(f['ap']),
      bpCoeffs: doubles(f['bp']),
    ),
  );
  Map<String, dynamic> object(String name) => (f['objects'] as List)
      .cast<Map<String, dynamic>>()
      .firstWhere((o) => o['name'] == name);

  test('HIP 11185 and NGC 898 are labeled on their true pixels', () {
    for (final name in ['HIP 11185', 'NGC 898', 'NGC 891']) {
      final o = object(name);
      final p = solve.skyToPixel(
        (o['ra'] as num).toDouble(),
        (o['dec'] as num).toDouble(),
      );
      expect(p, isNotNull, reason: name);
      expect(p!.x, closeTo((o['x'] as num).toDouble(), 0.5), reason: name);
      expect(p.y, closeTo((o['y'] as num).toDouble(), 0.5), reason: name);
    }
  });

  test('PGC 9150, just off the frame, gets no label', () {
    final o = object('PGC 9150');
    expect(
      solve.skyToPixel(
        (o['ra'] as num).toDouble(),
        (o['dec'] as num).toDouble(),
      ),
      isNull,
    );
    final unclamped = solve.skyToPixelUnclamped(
      (o['ra'] as num).toDouble(),
      (o['dec'] as num).toDouble(),
    )!;
    expect(unclamped.y, closeTo((o['y'] as num).toDouble(), 0.5));
  });

  test('a click anywhere on the frame resolves to the star under it', () {
    var worst = 0.0;
    for (final g in (f['gaia'] as List).map(doubles)) {
      final sky = solve.pixelToSky(g[3], g[4]);
      final dRa = (sky.ra - g[0]) * math.cos(g[1] * math.pi / 180);
      final sep = math.sqrt(dRa * dRa + math.pow(sky.dec - g[1], 2)) * 3600;
      worst = math.max(worst, sep);
    }
    // The click-to-identify search radius is 30".
    expect(worst, lessThan(0.3));
  });

  test('without a CD matrix the scalar fallback keeps sky parity', () {
    final noCd = solve.copyWith(cd1_1: null, cd1_2: null, cd2_1: null);
    expect(noCd.toSolvedWcs().hasCdMatrix, isFalse);
    expect(noCd.toSolvedWcs().isMirrored, isFalse);
    expect(solve.toSolvedWcs().isMirrored, isTrue);
  });
}
