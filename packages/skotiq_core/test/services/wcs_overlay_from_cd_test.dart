import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/wcs/gnomonic_projection.dart';
import 'package:skotiq_core/src/services/wcs_overlay.dart';

// Darkroom masters reach the annotation overlay and the colour calibrator
// through WcsOverlay. The rig's masters are Newtonian (mirrored), and the old
// inversion forced cdelt1 negative and read the rotation off the wrong
// column, which put HIP 11185 3,200 px from its star on NGC 891.
void main() {
  final f =
      jsonDecode(
            File(
              'test/fixtures/wcs/ngc891_l0001_solve.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final cd = [for (final v in f['cd'] as List) (v as num).toDouble()];
  final hip = (f['objects'] as List).cast<Map<String, dynamic>>().firstWhere(
    (o) => o['name'] == 'HIP 11185',
  );

  test('a mirrored master puts HIP 11185 on its star', () {
    final wcs = WcsOverlay.fromCd(
      crpix1: (f['crpix1'] as num).toDouble(),
      crpix2: (f['crpix2'] as num).toDouble(),
      crval1: (f['crval1'] as num).toDouble(),
      crval2: (f['crval2'] as num).toDouble(),
      cd1_1: cd[0],
      cd1_2: cd[1],
      cd2_1: cd[2],
      cd2_2: cd[3],
    );
    expect(wcs.cdelt1, greaterThan(0), reason: 'mirrored parity');
    final (x, y) = wcs.celestialToPixel(
      (hip['ra'] as num).toDouble(),
      (hip['dec'] as num).toDouble(),
    );
    // FITS 1-based pixels; the overlay's linear sky offsets cost a few
    // pixels half a degree off axis.
    expect(x, closeTo((hip['x'] as num) + 1, 10));
    expect(y, closeTo((hip['y'] as num) + 1, 10));
  });

  test('a sky-parity matrix keeps its rotation sense', () {
    final cdN = SolvedWcs.cdFromRotation(
      pixelScaleArcsec: 1.2,
      rotationDeg: 35,
    );
    final wcs = WcsOverlay.fromCd(
      crpix1: 1024.5,
      crpix2: 768.5,
      crval1: 150,
      crval2: 20,
      cd1_1: cdN.cd1_1,
      cd1_2: cdN.cd1_2,
      cd2_1: cdN.cd2_1,
      cd2_2: cdN.cd2_2,
    );
    expect(wcs.cdelt1, lessThan(0));
    final projection = GnomonicProjection(
      const SolvedWcs(
        raHours: 10,
        decDegrees: 20,
        rotationDeg: 35,
        pixelScaleArcsec: 1.2,
        imageWidth: 2048,
        imageHeight: 1536,
      ),
    );
    for (final (dx, dy) in [(400.0, 0.0), (0.0, 300.0), (-500.0, 250.0)]) {
      final sky = projection.pixelToWorld(x: 1023.5 + dx, y: 767.5 + dy);
      final (x, y) = wcs.celestialToPixel(sky.raDegrees, sky.decDegrees);
      expect(x, closeTo(1024.5 + dx, 1.0));
      expect(y, closeTo(768.5 + dy, 1.0));
    }
  });
}
