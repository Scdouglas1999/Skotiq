import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' show FrameWcs;
import 'package:skotiq_core/src/services/darkroom_autopilot/dawn_master_resolver.dart';
import 'package:skotiq_core/src/services/darkroom_autopilot/dawn_photometry.dart';
import 'package:skotiq_core/src/services/frame_header.dart';

const _master = DawnMaster(
  masterId: 1,
  targetId: null,
  name: 'M34',
  filter: null,
  masterFitsPath: '/masters/m34.xisf',
  channels: 3,
  width: 1914,
  height: 1074,
  frameCount: 10,
  totalIntegrationSeconds: 600,
);

void main() {
  test('a master solved only in its file is placed on the sky by the '
      'astrometry its header states', () async {
    // The native reader states a PC-form or SIP header as CD terms; this one
    // is referenced off the frame centre, as a cropped master is.
    final header = FrameHeader(
      {'NAXIS1': 1914, 'NAXIS2': 1074},
      astrometry: FrameWcs(
        crval1: 40.53,
        crval2: 42.76,
        crpix1: 100.5,
        crpix2: 50.5,
        cd11: -2.7e-4,
        cd12: 0,
        cd21: 0,
        cd22: 2.7e-4,
        aOrder: 0,
        bOrder: 0,
        aCoeffs: Float64List(0),
        bCoeffs: Float64List(0),
        apOrder: 0,
        bpOrder: 0,
        apCoeffs: Float64List(0),
        bpCoeffs: Float64List(0),
      ),
    );
    final searched = <CelestialCoordinate>[];
    final resolver = DawnPhotometryResolver(
      coneSearch: (centre, radius, {maxMagnitude}) async {
        searched.add(centre);
        return [
          Star(
            id: 'HD 16728',
            name: 'HD 16728',
            coordinates: CelestialCoordinate(ra: 40.5 / 15, dec: 42.7),
            magnitude: 9.1,
            colorIndex: 0.4,
          ),
        ];
      },
      readHeader: (path) async {
        expect(path, _master.masterFitsPath);
        return header;
      },
    );

    final photometry = await resolver.resolve(master: _master, wcs: null);

    expect(photometry.hasStars, isTrue, reason: photometry.unavailableReason);
    // The frame centre lies (956.5 - 99.5, 536.5 - 49.5) pixels from the
    // reference pixel; with CD1_1 < 0 and CD2_2 > 0 that is west and north of
    // the reference point, 0.23 and 0.13 degrees.
    final centre = searched.single;
    expect(centre.ra * 15, closeTo(40.53 - 0.2314 / 0.7337, 2e-3));
    expect(centre.dec, closeTo(42.76 + 0.1315, 2e-3));
  });

  test('a master whose header states no astrometry says so', () async {
    final resolver = DawnPhotometryResolver(
      coneSearch: (centre, radius, {maxMagnitude}) async => const [],
      readHeader: (_) async => FrameHeader({'NAXIS1': 1914, 'NAXIS2': 1074}),
    );
    final photometry = await resolver.resolve(master: _master, wcs: null);
    expect(photometry.hasStars, isFalse);
    expect(photometry.unavailableReason, contains('no solved astrometry'));
  });
}
