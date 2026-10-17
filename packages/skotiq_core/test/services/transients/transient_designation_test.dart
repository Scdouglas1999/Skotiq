// A self-discovered transient must carry a designation someone else can read.
//
// Live finding: the alert popover announced an object at RA 10.6847 deg,
// Dec +41.2687 deg as "NS J0.71+41.3" — RA in DECIMAL HOURS to two places and
// the declination in decimal degrees. That is not the IAU JHHMMSS.s+DDMMSS.s
// form the TNS / AAVSO / MPC expect for the very reports this feature exists to
// file, and it is coarse enough that two objects 40 arcminutes apart in RA
// share one name.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

TransientDetectionRow _at(double raDeg, double decDeg) {
  return TransientDetectionRow(
    id: 1,
    sessionId: 1,
    capturedImageId: 42,
    tileId: 1234,
    detectedAt: DateTime.utc(2026, 7, 30, 2, 15),
    raDeg: raDeg,
    decDeg: decDeg,
    residualFlux: 18400.0,
    deltaMag: -2.35,
    snr: 18.4,
    fwhm: 2.41,
    eccentricity: 0.12,
    positionAngleDeg: 0.0,
    kind: 'newSource',
    catalogMatch: null,
    confidence: 0.82,
    reviewed: false,
    dismissed: false,
  );
}

void main() {
  group('provisional designation', () {
    test('is IAU sexagesimal form, not decimal hours', () {
      // The reported row. 10.6847 deg = 0h 42m 44.33s; 41.2687 deg = +41d 16' 07.3".
      final alert = transientAlertFromDetection(_at(10.6847, 41.2687));

      expect(alert.name, 'NS J004244.33+411607.3');
    });

    test('keeps the sign of a southern declination', () {
      final alert = transientAlertFromDetection(_at(202.4694, -47.1953));

      expect(alert.name, 'NS J132952.66-471143.1');
    });

    test('a sub-arcsecond declination still gets its full field width', () {
      final alert = transientAlertFromDetection(_at(0.0, -0.5));

      expect(alert.name, 'NS J000000.00-003000.0');
    });

    test('rounding at the printed precision carries instead of showing 60', () {
      final alert = transientAlertFromDetection(_at(14.99999999, 59.999999));

      expect(alert.name, 'NS J010000.00+600000.0');
    });

    test('two objects half a degree apart get different designations', () {
      final a = transientAlertFromDetection(_at(10.6847, 41.2687));
      final b = transientAlertFromDetection(_at(11.1847, 41.2687));

      expect(a.name, isNot(b.name));
    });
  });
}
