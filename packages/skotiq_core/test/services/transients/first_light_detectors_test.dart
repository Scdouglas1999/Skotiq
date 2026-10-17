import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/services/science/narrator/narrator_context.dart';
import 'package:skotiq_core/src/services/science/narrator/narrator_detectors.dart';
import 'package:skotiq_core/src/services/science/narrator/detectors/first_light_detectors.dart';

final _t0 = DateTime.utc(2026, 6, 20, 22, 0, 0);

TransientCandidate _candidate({
  TransientKind kind = TransientKind.newSource,
  String? catalogMatch,
  double? deltaMag,
  double snr = 12.0,
  double eccentricity = 0.1,
  double confidence = 0.8,
  double ra = 123.4567,
  double dec = 25.4321,
  int tileId = 42,
  double positionAngleDeg = 0.0,
}) {
  return TransientCandidate(
    ra: ra,
    dec: dec,
    tileId: tileId,
    tileX: 512.0,
    tileY: 600.0,
    residualFlux: 1000.0,
    deltaMag: deltaMag,
    snr: snr,
    fwhm: 2.1,
    eccentricity: eccentricity,
    positionAngleDeg: positionAngleDeg,
    kind: kind,
    catalogMatch: catalogMatch,
    confidence: confidence,
  );
}

NarratorContext _ctx(List<TransientCandidate> candidates) {
  return NarratorContext(
    now: _t0,
    sessionId: 1,
    capturedImageId: 99,
    transientCandidates: candidates,
  );
}

void main() {
  group('TransientDiscoveryDetector (first_light.transient)', () {
    test('fires celebrate + pinned for a clean unnamed point source', () {
      final detector = TransientDiscoveryDetector();
      final out = detector.evaluate(_ctx([_candidate()]));
      expect(out, hasLength(1));
      final e = out.single;
      expect(e.eventType, 'first_light.transient');
      expect(e.severity, NarratorSeverity.celebrate);
      expect(e.pinned, isTrue);
      expect(e.category, NarratorCategory.discovery);
      expect(e.capturedImageId, 99);
    });

    test('does not fire when the source is catalog-matched', () {
      final detector = TransientDiscoveryDetector();
      final out = detector.evaluate(
        _ctx([_candidate(catalogMatch: 'Star V=14.0')]),
      );
      expect(out, isEmpty);
    });

    test('does not fire below the SNR floor', () {
      final detector = TransientDiscoveryDetector();
      final out = detector.evaluate(_ctx([_candidate(snr: 4.0)]));
      expect(out, isEmpty);
    });

    test('does not fire for an elongated (non-PSF) residual', () {
      final detector = TransientDiscoveryDetector();
      final out = detector.evaluate(_ctx([_candidate(eccentricity: 0.8)]));
      expect(out, isEmpty);
    });

    test('dedupes per sky position', () {
      final detector = TransientDiscoveryDetector();
      final a = detector.evaluate(_ctx([_candidate()])).single;
      final b = detector.evaluate(_ctx([_candidate()])).single;
      expect(a.dedupeKey, b.dedupeKey);
    });
  });

  group('BrighteningDetector (first_light.brightening)', () {
    test('fires for a deltaMag below -0.3', () {
      final detector = BrighteningDetector();
      final out = detector.evaluate(
        _ctx([
          _candidate(
            kind: TransientKind.pointBrightening,
            catalogMatch: 'Star V=13.2',
            deltaMag: -0.6,
          ),
        ]),
      );
      expect(out, hasLength(1));
      expect(out.single.eventType, 'first_light.brightening');
      expect(out.single.severity, NarratorSeverity.celebrate);
      expect(out.single.evidence?.kind, NarratorEvidenceKind.delta);
    });

    test('does not fire for a faint brightening within the threshold', () {
      final detector = BrighteningDetector();
      final out = detector.evaluate(
        _ctx([
          _candidate(kind: TransientKind.pointBrightening, deltaMag: -0.1),
        ]),
      );
      expect(out, isEmpty);
    });

    test('does not fire for a null deltaMag (new source)', () {
      final detector = BrighteningDetector();
      final out = detector.evaluate(_ctx([_candidate()]));
      expect(out, isEmpty);
    });
  });

  group('MoverDetector (first_light.mover)', () {
    test('fires success for a moving streak with a vector evidence', () {
      final detector = MoverDetector();
      final out = detector.evaluate(
        _ctx([_candidate(kind: TransientKind.movingStreak, eccentricity: 0.9)]),
      );
      expect(out, hasLength(1));
      expect(out.single.eventType, 'first_light.mover');
      expect(out.single.severity, NarratorSeverity.success);
      expect(out.single.evidence?.kind, NarratorEvidenceKind.vector);
    });

    test('uses the measured positionAngleDeg as the vector bearing (not a '
        'fabricated tile-pixel angle)', () {
      final detector = MoverDetector();
      final out = detector.evaluate(
        _ctx([
          _candidate(
            kind: TransientKind.movingStreak,
            eccentricity: 0.9,
            positionAngleDeg: 47.5,
          ),
        ]),
      );
      final e = out.single.evidence!;
      expect(e.kind, NarratorEvidenceKind.vector);
      // The direction is the real major-axis position angle, not a function
      // of the tile coordinates.
      expect(e.directionDeg, closeTo(47.5, 1e-9));
      expect(e.magnitude, closeTo(0.9, 1e-9));
    });

    test(
      'omits the direction vector for a near-round streak (no fake arrow)',
      () {
        final detector = MoverDetector();
        final out = detector.evaluate(
          _ctx([
            _candidate(
              kind: TransientKind.movingStreak,
              eccentricity: 0.2,
              positionAngleDeg: 47.5,
            ),
          ]),
        );
        expect(out, hasLength(1));
        final e = out.single.evidence!;
        expect(e.kind, NarratorEvidenceKind.scalar);
        expect(e.directionDeg, isNull);
        expect(e.value, closeTo(0.2, 1e-9));
      },
    );

    test('does not fire for a non-streak residual', () {
      final detector = MoverDetector();
      final out = detector.evaluate(_ctx([_candidate()]));
      expect(out, isEmpty);
    });
  });

  group('engine registration', () {
    test('default engine includes the three First Light detectors', () {
      final engine = buildDefaultNarratorEngine();
      final out = engine.evaluate(
        _ctx([
          _candidate(),
          _candidate(
            kind: TransientKind.pointBrightening,
            catalogMatch: 'Star V=12.0',
            deltaMag: -0.9,
            ra: 200.0,
            dec: -10.0,
            tileId: 7,
          ),
          _candidate(
            kind: TransientKind.movingStreak,
            eccentricity: 0.85,
            ra: 88.0,
            dec: 40.0,
            tileId: 9,
          ),
        ]),
      );
      final types = out.map((e) => e.eventType).toSet();
      expect(types, contains('first_light.transient'));
      expect(types, contains('first_light.brightening'));
      expect(types, contains('first_light.mover'));
    });

    test('first_light.transient + first_light.mover carry a cooldown', () {
      expect(
        defaultNarratorCooldowns.containsKey('first_light.transient'),
        isTrue,
      );
      expect(defaultNarratorCooldowns.containsKey('first_light.mover'), isTrue);
    });
  });
}
