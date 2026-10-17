// A First Light detection has no apparent magnitude.
//
// The difference-image pipeline measures `delta_mag` — a brightness CHANGE
// against the atlas template — and there is no photometric zero point behind
// it (`photometric_transforms` is empty for these rows and the table has no
// apparent-magnitude column at all). `TransientAlert.magnitude` on the other
// hand is consumed everywhere as an apparent magnitude:
//
//   * `TransientCard` buckets it NAKED EYE (<=6) / BINOCULAR (<=10) /
//     SMALL SCOPE (<=14) and prints 'mag N.N';
//   * `TransientAlertService.filterAlerts` drops anything fainter than
//     `magnitudeThreshold`;
//   * `TransientAlertService.shouldNotify` auto-queues anything at or under
//     `autoQueueMagnitude`;
//   * `addAlertToTargets` copies it into the target library.
//
// Because a difference-image delta larger than ~6 mag is essentially
// impossible, feeding the delta into that field announced every self-discovery
// as a naked-eye or binocular object — "you have found a magnitude 2.4
// supernova", brighter than the brightest in recorded history.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

TransientDetectionRow _detection({
  double? deltaMag,
  String kind = 'newSource',
  String? catalogMatch,
}) {
  return TransientDetectionRow(
    id: 1,
    sessionId: 1,
    capturedImageId: 42,
    tileId: 1234,
    detectedAt: DateTime.utc(2026, 7, 30, 2, 15),
    raDeg: 202.4694,
    decDeg: 47.1953,
    residualFlux: 18400.0,
    deltaMag: deltaMag,
    snr: 18.4,
    fwhm: 2.41,
    eccentricity: 0.12,
    positionAngleDeg: 0.0,
    kind: kind,
    catalogMatch: catalogMatch,
    confidence: 0.82,
    reviewed: true,
    dismissed: false,
  );
}

void main() {
  group('transientAlertFromDetection', () {
    test('never reports a delta magnitude as an apparent magnitude', () {
      // The reproduced row: delta_mag -2.35 was rendered as 'mag 2.4 NAKED EYE'.
      final alert = transientAlertFromDetection(_detection(deltaMag: -2.35));

      expect(
        alert.magnitude,
        isNull,
        reason:
            'A First Light detection has no apparent magnitude; any non-null '
            'value here is bucketed NAKED EYE / BINOCULAR by the alert card '
            'and auto-queued by shouldNotify.',
      );
      expect(alert.peakMagnitude, isNull);
    });

    test('a delta this large would be announced as naked-eye if kept', () {
      // Guards the specific arithmetic that made the defect so loud: |−2.35| is
      // 2.4, and the card's brightest bucket is magnitude <= 6.0. If a future
      // change reintroduces magnitude = deltaMag.abs(), this asserts the exact
      // consequence rather than just the field being non-null.
      final alert = transientAlertFromDetection(_detection(deltaMag: -2.35));
      const nakedEyeCutoff = 6.0;
      expect(
        alert.magnitude == null || alert.magnitude! > nakedEyeCutoff,
        isTrue,
        reason:
            'alert.magnitude=${alert.magnitude} falls in the NAKED EYE bucket',
      );
    });

    test('surfaces the brightness change in the classification line', () {
      final brighter = transientAlertFromDetection(_detection(deltaMag: -2.35));
      expect(brighter.classification, contains('Δ2.35 mag brighter'));
      expect(brighter.classification, contains('Unconfirmed'));
      // The word "mag" must never appear as a bare apparent magnitude.
      expect(brighter.classification, isNot(contains('mag 2.4')));

      final fainter = transientAlertFromDetection(_detection(deltaMag: 1.2));
      expect(fainter.classification, contains('Δ1.20 mag fainter'));
    });

    test('a detection with no measured delta keeps a plain classification', () {
      final alert = transientAlertFromDetection(_detection(deltaMag: null));
      expect(alert.magnitude, isNull);
      expect(alert.classification, 'Unconfirmed — possible new transient');
      expect(alert.classification, isNot(contains('Δ')));
    });

    test('the notes say plainly that the delta is not a magnitude', () {
      final alert = transientAlertFromDetection(_detection(deltaMag: -2.35));
      expect(alert.notes, contains('brightness change'));
      expect(alert.notes, contains('not an apparent magnitude'));
    });

    test(
      'a catalog-matched brightening keeps its name and gains the delta',
      () {
        final alert = transientAlertFromDetection(
          _detection(
            deltaMag: -0.8,
            kind: 'pointBrightening',
            catalogMatch: 'SS Cyg',
          ),
        );
        expect(alert.name, 'SS Cyg');
        expect(alert.magnitude, isNull);
        expect(alert.classification, contains('Brightening of SS Cyg'));
        expect(alert.classification, contains('Δ0.80 mag brighter'));
      },
    );
  });
}
