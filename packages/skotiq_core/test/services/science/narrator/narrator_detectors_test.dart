import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/services/science/narrator/narrator_context.dart';
import 'package:skotiq_core/src/services/science/narrator/narrator_detectors.dart';
import 'package:skotiq_core/src/services/science/narrator/narrator_engine.dart';
import 'package:skotiq_core/src/services/science/narrator/detectors/discovery_detectors.dart';
import 'package:skotiq_core/src/services/science/narrator/detectors/milestone_detectors.dart';
import 'package:skotiq_core/src/services/science/narrator/detectors/conditions_detectors.dart';
import 'package:skotiq_core/src/services/science/narrator/detectors/equipment_detectors.dart';
import 'package:skotiq_core/src/services/science/narrator/detectors/quality_detectors.dart';

/// Fixed clock base for deterministic trend/cooldown maths.
final _t0 = DateTime.utc(2026, 6, 11, 22, 0, 0);

DateTime _at(Duration d) => _t0.add(d);

// ── Row / model builders ────────────────────────────────────────────────────

FramePhotometricCalibrationRow _calib({
  required int id,
  required DateTime timestamp,
  bool isCalibrated = true,
  double? zeroPoint,
  double? limitingMag5Sigma,
}) {
  return FramePhotometricCalibrationRow(
    id: id,
    isCalibrated: isCalibrated,
    matchedStarCount: 40,
    calibrationRms: 0.03,
    catalogSource: 'auto',
    solverId: 'test',
    timestamp: timestamp,
    zeroPoint: zeroPoint,
    limitingMag5Sigma: limitingMag5Sigma,
  );
}

ScienceFrameQualityMetricsRow _frameQuality({
  required int id,
  required DateTime timestamp,
  double highClip = 0.0,
  double lowClip = 0.0,
  double gradientX = 0.0,
  double gradientY = 0.0,
}) {
  return ScienceFrameQualityMetricsRow(
    id: id,
    timestamp: timestamp,
    median: 0,
    mean: 0,
    stdDev: 0,
    mad: 0,
    background: 0,
    noise: 0,
    snr: 20,
    dynamicRangeP1P99: 0,
    lowClipPercent: lowClip,
    highClipPercent: highClip,
    uniformityCv: 0,
    gradientX: gradientX,
    gradientY: gradientY,
    processingTier: 'live',
    processingMs: 0,
  );
}

LightCurvePoint _lc({
  required Duration at,
  required double mag,
  double uncertainty = 0.01,
}) {
  return LightCurvePoint(
    timestamp: _at(at),
    flux: 1000,
    differentialMagnitude: mag,
    snr: 100,
    uncertainty: uncertainty,
  );
}

TransparencyTrendPoint _tp({required Duration at, required double pct}) {
  return TransparencyTrendPoint(
    timestamp: _at(at),
    transparencyPercent: pct,
    extinctionCoefficient: 0.2,
  );
}

NarratorImageStats _stats({
  required Duration at,
  double? hfr,
  double? fwhm,
  int? starCount,
  double? temp,
}) {
  return NarratorImageStats(
    timestamp: _at(at),
    hfr: hfr,
    fwhm: fwhm,
    starCount: starCount,
    focuserTempC: temp,
  );
}

NarratorSkySample _sky({
  required Duration at,
  required double aduPerSecond,
  String? filter,
}) {
  return NarratorSkySample(
    timestamp: _at(at),
    aduPerSecond: aduPerSecond,
    filter: filter,
  );
}

void main() {
  group('NarratorEvidence codec', () {
    test('sparkline round-trips', () {
      final e = NarratorEvidence.sparkline(
        points: [1.0, 2.0, 3.5],
        unit: '%',
        direction: 'up',
      );
      final back = NarratorEvidence.fromJsonString(e.toJsonString());
      expect(back, isNotNull);
      expect(back!.kind, NarratorEvidenceKind.sparkline);
      expect(back.points, [1.0, 2.0, 3.5]);
      expect(back.unit, '%');
      expect(back.highlightLast, isTrue);
      expect(back.direction, 'up');
    });

    test('delta round-trips and infers direction', () {
      final e = NarratorEvidence.delta(from: 18.6, to: 19.2, unit: 'mag');
      expect(e.direction, 'up');
      final back = NarratorEvidence.fromJson(e.toJson())!;
      expect(back.kind, NarratorEvidenceKind.delta);
      expect(back.from, 18.6);
      expect(back.to, 19.2);
    });

    test('vector round-trips', () {
      final e = NarratorEvidence.vector(
        directionDeg: 45,
        magnitude: 0.3,
        label: 'NE corner',
      );
      final back = NarratorEvidence.fromJson(e.toJson())!;
      expect(back.kind, NarratorEvidenceKind.vector);
      expect(back.directionDeg, 45);
      expect(back.magnitude, 0.3);
      expect(back.label, 'NE corner');
    });

    test('scalar round-trips', () {
      final e = NarratorEvidence.scalar(
        value: 1.8,
        unit: '"',
        context: 'session best',
      );
      final back = NarratorEvidence.fromJson(e.toJson())!;
      expect(back.kind, NarratorEvidenceKind.scalar);
      expect(back.value, 1.8);
      expect(back.context, 'session best');
    });

    test('malformed payloads decode to null, never throw', () {
      expect(NarratorEvidence.fromJsonString('{"kind":"delta"}'), isNull);
      expect(NarratorEvidence.fromJsonString('{"kind":"bogus"}'), isNull);
      expect(NarratorEvidence.fromJsonString('not json'), isNull);
      expect(NarratorEvidence.fromJsonString(null), isNull);
      expect(
        NarratorEvidence.fromJsonString('{"kind":"sparkline","points":["x"]}'),
        isNull,
      );
    });
  });

  group('LightCurveEventDetector hysteresis', () {
    test('fires once on a sustained fade, then closes on recovery', () {
      final d = LightCurveEventDetector();
      // 10 baseline points at mag 15.00 (sigma 0.01) + 3 faded points well
      // beyond 3 sigma (mag 15.10).
      final points = <LightCurvePoint>[];
      for (var i = 0; i < 10; i++) {
        points.add(_lc(at: Duration(minutes: i), mag: 15.0));
      }
      for (var i = 0; i < 3; i++) {
        points.add(_lc(at: Duration(minutes: 10 + i), mag: 15.10));
      }
      final fired = d.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 12)),
          lightCurve: points,
        ),
      );
      expect(fired, hasLength(1));
      expect(fired.single.eventType, 'discovery.lightcurve_event');
      expect(fired.single.severity, NarratorSeverity.celebrate);
      expect(fired.single.pinned, isTrue);
      expect(fired.single.headline, contains('faded'));

      // While still faded, it must not re-fire (open state).
      final again = d.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 13)),
          lightCurve: points,
        ),
      );
      expect(again, isEmpty);

      // Recovery within 1 sigma closes with a calmer info event.
      final recovered = List<LightCurvePoint>.from(points)
        ..add(_lc(at: const Duration(minutes: 14), mag: 15.0));
      final close = d.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 14)),
          lightCurve: recovered,
        ),
      );
      expect(close, hasLength(1));
      expect(close.single.severity, NarratorSeverity.info);
      expect(close.single.headline, contains('baseline'));
    });

    test('does not fire on noise within threshold', () {
      final d = LightCurveEventDetector();
      final points = <LightCurvePoint>[];
      for (var i = 0; i < 13; i++) {
        points.add(
          _lc(
            at: Duration(minutes: i),
            mag: 15.0 + (i.isEven ? 0.005 : -0.005),
          ),
        );
      }
      final fired = d.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 12)),
          lightCurve: points,
        ),
      );
      expect(fired, isEmpty);
    });

    test('non-finite magnitude tail is ignored (no false brightening)', () {
      final d = LightCurveEventDetector();
      // 12 clean baseline points at mag 15.0, then a tail of junk (NaN) points.
      // Without the defensive finite-filter these would look like a giant
      // excursion; the detector must ignore them and stay quiet.
      final points = <LightCurvePoint>[];
      for (var i = 0; i < 12; i++) {
        points.add(_lc(at: Duration(minutes: i), mag: 15.0));
      }
      for (var i = 0; i < 3; i++) {
        points.add(
          _lc(
            at: Duration(minutes: 12 + i),
            mag: double.nan,
          ),
        );
      }
      final fired = d.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 15)),
          lightCurve: points,
        ),
      );
      expect(fired, isEmpty);
    });
  });

  group('TransparencyTrendDetector', () {
    test('fires once on a sustained drop and re-arms on recovery', () {
      final d = TransparencyTrendDetector();
      // 35 min window, dropping from 90% to 70% (20 points down → > 8 threshold).
      final pts = <TransparencyTrendPoint>[];
      for (var i = 0; i <= 35; i += 5) {
        pts.add(
          _tp(
            at: Duration(minutes: i),
            pct: 90.0 - (i / 35.0) * 20.0,
          ),
        );
      }
      final fired = d.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 35)),
          transparency: pts,
        ),
      );
      expect(fired, hasLength(1));
      expect(fired.single.severity, NarratorSeverity.warning);
      expect(fired.single.headline, contains('dropping'));

      // Open: no re-fire on the same window.
      expect(
        d.evaluate(
          NarratorContext(
            now: _at(const Duration(minutes: 36)),
            transparency: pts,
          ),
        ),
        isEmpty,
      );
    });

    test('improving trend is success severity', () {
      final d = TransparencyTrendDetector();
      final pts = <TransparencyTrendPoint>[];
      for (var i = 0; i <= 35; i += 5) {
        pts.add(
          _tp(
            at: Duration(minutes: i),
            pct: 70.0 + (i / 35.0) * 20.0,
          ),
        );
      }
      final fired = d.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 35)),
          transparency: pts,
        ),
      );
      expect(fired, hasLength(1));
      expect(fired.single.severity, NarratorSeverity.success);
      expect(fired.single.headline, contains('improving'));
    });
  });

  group('CloudsVsFocusDetector disambiguation', () {
    List<NarratorImageStats> healthyStars() {
      final stats = <NarratorImageStats>[];
      for (var i = 0; i < 10; i++) {
        stats.add(_stats(at: Duration(minutes: i), starCount: 100, hfr: 2.0));
      }
      return stats;
    }

    test('clouds branch: count collapses with transparency dropping', () {
      final d = CloudsVsFocusDetector();
      final stats = healthyStars()
        ..add(_stats(at: const Duration(minutes: 10), starCount: 40, hfr: 2.0));
      // transparency dropping fast.
      final pts = [
        _tp(at: const Duration(minutes: 6), pct: 90),
        _tp(at: const Duration(minutes: 8), pct: 80),
        _tp(at: const Duration(minutes: 10), pct: 60),
      ];
      final fired = d.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 10)),
          imageStats: stats,
          transparency: pts,
        ),
      );
      expect(fired, hasLength(1));
      expect(fired.single.headline, contains('clouds, not focus'));
    });

    test('focus branch: count collapses, transparency stable, HFR rose', () {
      final d = CloudsVsFocusDetector();
      final stats = <NarratorImageStats>[];
      for (var i = 0; i < 10; i++) {
        stats.add(_stats(at: Duration(minutes: i), starCount: 100, hfr: 2.0));
      }
      stats.add(
        _stats(at: const Duration(minutes: 10), starCount: 40, hfr: 3.0),
      );
      // transparency flat.
      final pts = [
        _tp(at: const Duration(minutes: 6), pct: 85),
        _tp(at: const Duration(minutes: 8), pct: 85),
        _tp(at: const Duration(minutes: 10), pct: 85),
      ];
      final fired = d.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 10)),
          imageStats: stats,
          transparency: pts,
        ),
      );
      expect(fired, hasLength(1));
      expect(fired.single.headline, contains('focus drift, not clouds'));
    });
  });

  group('FocusDriftDetector', () {
    test('fires once HFR sustained above baseline for the window', () {
      final d = FocusDriftDetector();
      // baseline 2.0; rolling HFR ~2.3 (15% up). Need >=10% rise sustained 15 min.
      final stats = <NarratorImageStats>[];
      for (var i = 0; i < 8; i++) {
        stats.add(
          _stats(
            at: Duration(minutes: i * 3),
            hfr: 2.3,
            temp: 5.0 - i * 0.5,
          ),
        );
      }
      // First eval establishes _aboveSince at now.
      final first = d.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 0)),
          imageStats: stats,
          autofocusHfrBaseline: 2.0,
        ),
      );
      expect(first, isEmpty); // not sustained yet

      final later = d.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 16)),
          imageStats: stats,
          autofocusHfrBaseline: 2.0,
        ),
      );
      expect(later, hasLength(1));
      expect(later.single.eventType, 'equipment.focus_drift');
      expect(later.single.headline, contains('focus drift'));
      // Temperature fell ~3.5C → mention it.
      expect(later.single.headline, contains('temperature'));
    });
  });

  group('LimitingMagDetector', () {
    test('announces first calibration, then a new depth record', () {
      final d = LimitingMagDetector();
      final first = d.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 1)),
          calibrations: [
            _calib(
              id: 1,
              timestamp: _at(const Duration(minutes: 1)),
              limitingMag5Sigma: 19.0,
            ),
          ],
        ),
      );
      expect(first, hasLength(1));
      expect(first.single.headline, contains('magnitude 19.0'));
      expect(first.single.dedupeKey, 'milestone.limiting_mag.first');

      // Small improvement (<0.2) → no event.
      final small = d.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 2)),
          calibrations: [
            _calib(
              id: 2,
              timestamp: _at(const Duration(minutes: 2)),
              limitingMag5Sigma: 19.1,
            ),
          ],
        ),
      );
      expect(small, isEmpty);

      // Beat by >=0.2 → record.
      final record = d.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 3)),
          calibrations: [
            _calib(
              id: 3,
              timestamp: _at(const Duration(minutes: 3)),
              limitingMag5Sigma: 19.3,
            ),
          ],
        ),
      );
      expect(record, hasLength(1));
      expect(record.single.headline, contains('depth record'));
    });
  });

  group('CalibrationLockedDetector', () {
    test('locks once ZP std over last 10 is tight, fires once', () {
      final d = CalibrationLockedDetector();
      final calibs = <FramePhotometricCalibrationRow>[];
      for (var i = 0; i < 12; i++) {
        calibs.add(
          _calib(
            id: i,
            timestamp: _at(Duration(minutes: i)),
            zeroPoint: 25.0 + (i.isEven ? 0.01 : -0.01),
          ),
        );
      }
      final ctx = NarratorContext(
        now: _at(const Duration(minutes: 12)),
        calibrations: calibs,
      );
      final fired = d.evaluate(ctx);
      expect(fired, hasLength(1));
      expect(fired.single.eventType, 'milestone.calibration_locked');
      // Fires exactly once.
      expect(d.evaluate(ctx), isEmpty);
    });

    test('does not lock when ZP scatter is large', () {
      final d = CalibrationLockedDetector();
      final calibs = <FramePhotometricCalibrationRow>[];
      for (var i = 0; i < 12; i++) {
        calibs.add(
          _calib(
            id: i,
            timestamp: _at(Duration(minutes: i)),
            zeroPoint: 25.0 + (i.isEven ? 0.3 : -0.3),
          ),
        );
      }
      final fired = d.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 12)),
          calibrations: calibs,
        ),
      );
      expect(fired, isEmpty);
    });
  });

  group('RejectBurstDetector', () {
    NarratorGradeEvent reject(int id, String reason) => NarratorGradeEvent(
      capturedImageId: id,
      timestamp: _at(Duration(minutes: id)),
      rejected: true,
      reason: reason,
    );

    test(
      'fires once on 3 consecutive rejects and names the dominant cause',
      () {
        final d = RejectBurstDetector();
        final events = [
          reject(1, 'Auto-grade: HFR 3.40 > 3.20'),
          reject(2, 'Auto-grade: HFR 3.50 > 3.20'),
          reject(3, 'Auto-grade: HFR 3.60 > 3.20'),
        ];
        final ctx = NarratorContext(
          now: _at(const Duration(minutes: 3)),
          gradeEvents: events,
        );
        final fired = d.evaluate(ctx);
        expect(fired, hasLength(1));
        expect(fired.single.eventType, 'quality.reject_burst');
        expect(fired.single.headline, contains('HFR limit'));
        // Open — no re-fire.
        expect(d.evaluate(ctx), isEmpty);
      },
    );

    test('re-arms after an accepted frame', () {
      final d = RejectBurstDetector();
      final events = [reject(1, 'HFR'), reject(2, 'HFR'), reject(3, 'HFR')];
      d.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 3)),
          gradeEvents: events,
        ),
      );
      final withAccept = List<NarratorGradeEvent>.from(events)
        ..add(
          NarratorGradeEvent(
            capturedImageId: 4,
            timestamp: _at(const Duration(minutes: 4)),
            rejected: false,
          ),
        );
      // accepted resets; no event.
      expect(
        d.evaluate(
          NarratorContext(
            now: _at(const Duration(minutes: 4)),
            gradeEvents: withAccept,
          ),
        ),
        isEmpty,
      );
    });
  });

  group('MovingObjectDetector', () {
    test('fires for high-confidence candidate, deduped per id', () {
      final d = MovingObjectDetector();
      final c = MovingObjectCandidate(
        timestamp: _at(const Duration(minutes: 1)),
        candidateId: 'cand-1',
        confidence: 0.8,
        motionArcsecPerMinute: 2.1,
      );
      final ctx = NarratorContext(
        now: _at(const Duration(minutes: 1)),
        movingObjects: [c],
      );
      final fired = d.evaluate(ctx);
      expect(fired, hasLength(1));
      expect(fired.single.pinned, isTrue);
      expect(fired.single.dedupeKey, 'discovery.moving_object:cand-1');
    });

    test('ignores low-confidence candidates', () {
      final d = MovingObjectDetector();
      final c = MovingObjectCandidate(
        timestamp: _at(const Duration(minutes: 1)),
        candidateId: 'cand-2',
        confidence: 0.5,
        motionArcsecPerMinute: 2.1,
      );
      expect(
        d.evaluate(
          NarratorContext(
            now: _at(const Duration(minutes: 1)),
            movingObjects: [c],
          ),
        ),
        isEmpty,
      );
    });
  });

  group('SkyDarknessDetector (filter-aware, relative)', () {
    test('genuine same-filter darkening fires once, reports relative mag', () {
      final d = SkyDarknessDetector();
      // Same filter L; background rate falls from ~10 to ~5 ADU/s → darker.
      // Δmag = 2.5*log10(10/5) ≈ 0.75 mag (≥ 0.3).
      final samples = <NarratorSkySample>[
        _sky(at: const Duration(minutes: 0), aduPerSecond: 10.0, filter: 'L'),
        _sky(at: const Duration(minutes: 2), aduPerSecond: 10.2, filter: 'L'),
        _sky(at: const Duration(minutes: 4), aduPerSecond: 9.8, filter: 'L'),
        _sky(at: const Duration(minutes: 6), aduPerSecond: 5.1, filter: 'L'),
        _sky(at: const Duration(minutes: 8), aduPerSecond: 5.0, filter: 'L'),
        _sky(at: const Duration(minutes: 10), aduPerSecond: 4.9, filter: 'L'),
      ];
      final fired = d.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 10)),
          skySamples: samples,
        ),
      );
      expect(fired, hasLength(1));
      expect(fired.single.eventType, 'conditions.sky_darkness');
      expect(fired.single.severity, NarratorSeverity.success);
      expect(fired.single.headline, contains('Sky darkened'));
      // Relative change only — no absolute SQM claim.
      expect(fired.single.headline, isNot(contains('mag/arcsec')));
      expect(fired.single.headline, contains('mag'));
      // Once per direction.
      expect(
        d.evaluate(
          NarratorContext(
            now: _at(const Duration(minutes: 11)),
            skySamples: samples,
          ),
        ),
        isEmpty,
      );
    });

    test('an L→Ha filter change (background dropping 20×) does NOT fire', () {
      final d = SkyDarknessDetector();
      // L frames at ~100 ADU/s, then Ha frames at ~5 ADU/s — a 20× drop that is
      // purely the filter change, not the sky. Neither filter shows a real
      // trend, so the detector must stay quiet.
      final samples = <NarratorSkySample>[
        _sky(at: const Duration(minutes: 0), aduPerSecond: 100.0, filter: 'L'),
        _sky(at: const Duration(minutes: 2), aduPerSecond: 101.0, filter: 'L'),
        _sky(at: const Duration(minutes: 4), aduPerSecond: 99.0, filter: 'L'),
        _sky(at: const Duration(minutes: 6), aduPerSecond: 5.0, filter: 'Ha'),
        _sky(at: const Duration(minutes: 8), aduPerSecond: 5.1, filter: 'Ha'),
        _sky(at: const Duration(minutes: 10), aduPerSecond: 4.9, filter: 'Ha'),
      ];
      final fired = d.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 10)),
          skySamples: samples,
        ),
      );
      expect(fired, isEmpty);
    });

    test('brightening (rate rising) in one filter fires a warning', () {
      final d = SkyDarknessDetector();
      final samples = <NarratorSkySample>[
        _sky(at: const Duration(minutes: 0), aduPerSecond: 5.0, filter: 'L'),
        _sky(at: const Duration(minutes: 2), aduPerSecond: 5.1, filter: 'L'),
        _sky(at: const Duration(minutes: 4), aduPerSecond: 4.9, filter: 'L'),
        _sky(at: const Duration(minutes: 6), aduPerSecond: 10.0, filter: 'L'),
        _sky(at: const Duration(minutes: 8), aduPerSecond: 10.2, filter: 'L'),
        _sky(at: const Duration(minutes: 10), aduPerSecond: 9.8, filter: 'L'),
      ];
      final fired = d.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 10)),
          skySamples: samples,
        ),
      );
      expect(fired, hasLength(1));
      expect(fired.single.severity, NarratorSeverity.warning);
      expect(fired.single.headline, contains('Sky brightened'));
    });
  });

  group('ExcellentTransparencyDetector', () {
    test('a 25-min all-high trailing run fires once', () {
      final d = ExcellentTransparencyDetector();
      final pts = <TransparencyTrendPoint>[
        for (var i = 0; i <= 25; i += 5)
          _tp(at: Duration(minutes: i), pct: 95.0),
      ];
      final fired = d.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 25)),
          transparency: pts,
        ),
      );
      expect(fired, hasLength(1));
      expect(fired.single.eventType, 'conditions.excellent');
      expect(fired.single.severity, NarratorSeverity.success);
      // Once per session.
      expect(
        d.evaluate(
          NarratorContext(
            now: _at(const Duration(minutes: 30)),
            transparency: pts,
          ),
        ),
        isEmpty,
      );
    });

    test('a 10-min all-high run does not fire (too short)', () {
      final d = ExcellentTransparencyDetector();
      final pts = <TransparencyTrendPoint>[
        for (var i = 0; i <= 10; i += 5)
          _tp(at: Duration(minutes: i), pct: 95.0),
      ];
      expect(
        d.evaluate(
          NarratorContext(
            now: _at(const Duration(minutes: 10)),
            transparency: pts,
          ),
        ),
        isEmpty,
      );
    });

    test('only the trailing high run counts; an early dip is excluded', () {
      final d = ExcellentTransparencyDetector();
      // Low at minute 0, then a sustained 25-min high run to minute 30.
      final pts = <TransparencyTrendPoint>[
        _tp(at: const Duration(minutes: 0), pct: 60.0),
        for (var i = 5; i <= 30; i += 5)
          _tp(at: Duration(minutes: i), pct: 95.0),
      ];
      final fired = d.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 30)),
          transparency: pts,
        ),
      );
      expect(fired, hasLength(1));
    });
  });

  group('compassBearingForGradient mapping', () {
    test('maps math gradient vectors to compass bearings the UI expects', () {
      // +x / right → 90°.
      expect(compassBearingForGradient(1.0, 0.0), closeTo(90.0, 1e-6));
      // +y / screen-down → 180°.
      expect(compassBearingForGradient(0.0, 1.0), closeTo(180.0, 1e-6));
      // -y / screen-up → 0°.
      expect(compassBearingForGradient(0.0, -1.0), closeTo(0.0, 1e-6));
      // -x / left → 270°.
      expect(compassBearingForGradient(-1.0, 0.0), closeTo(270.0, 1e-6));
    });
  });

  group('Graceful degradation', () {
    test('empty context fires nothing across the full catalog', () {
      final engine = buildDefaultNarratorEngine();
      final fired = engine.evaluate(NarratorContext(now: _t0));
      expect(fired, isEmpty);
    });
  });

  group('NarratorEngine dedupe + cooldown', () {
    test('dedupeKey is only accepted once per session', () {
      final engine = buildDefaultNarratorEngine();
      final c = MovingObjectCandidate(
        timestamp: _t0,
        candidateId: 'dupe',
        confidence: 0.9,
        motionArcsecPerMinute: 1.0,
      );
      final ctx = NarratorContext(now: _t0, movingObjects: [c]);
      expect(engine.evaluate(ctx), hasLength(1));
      // Same candidate again → deduped to zero.
      expect(
        engine.evaluate(
          NarratorContext(
            now: _t0.add(const Duration(minutes: 5)),
            movingObjects: [c],
          ),
        ),
        isEmpty,
      );
    });

    test(
      'relaunch: a second engine seeded with engine #1 keys does not re-fire',
      () {
        // Engine #1 fires a transparency-drop event for an ongoing episode.
        List<TransparencyTrendPoint> droppingWindow() {
          final pts = <TransparencyTrendPoint>[];
          for (var i = 0; i <= 35; i += 5) {
            pts.add(
              _tp(
                at: Duration(minutes: i),
                pct: 90.0 - (i / 35.0) * 20.0,
              ),
            );
          }
          return pts;
        }

        final engine1 = buildDefaultNarratorEngine();
        final pts = droppingWindow();
        final fired1 = engine1.evaluate(
          NarratorContext(
            now: _at(const Duration(minutes: 35)),
            transparency: pts,
          ),
        );
        expect(fired1, hasLength(1));
        final key = fired1.single.dedupeKey;

        // App relaunches mid-episode: a fresh engine is built (in-memory state
        // empty), then seeded from the DB with engine #1's persisted keys. The
        // same ongoing context must NOT re-fire the same card.
        final engine2 = buildDefaultNarratorEngine();
        engine2.seedDedupeKeys([key]);
        final fired2 = engine2.evaluate(
          NarratorContext(
            now: _at(const Duration(minutes: 36)),
            transparency: pts,
          ),
        );
        expect(
          fired2,
          isEmpty,
          reason: 'seeded dedupe key suppresses the ongoing episode.',
        );
      },
    );

    test('per-eventType cooldown suppresses a re-fire inside the window', () {
      // best_seeing has a 30-min cooldown in the default map. Use a custom
      // single-detector engine so we control the inputs precisely.
      final engine = NarratorEngine(
        detectors: [BestSeeingDetector()],
        cooldowns: const {'milestone.best_seeing': Duration(minutes: 30)},
      );

      List<NarratorImageStats> seeingSeries(double latestFwhm, Duration at) {
        final stats = <NarratorImageStats>[];
        for (var i = 0; i < 25; i++) {
          stats.add(_stats(at: Duration(minutes: i), fwhm: 3.0));
        }
        stats.add(_stats(at: at, fwhm: latestFwhm));
        return stats;
      }

      // First best — 1.8" is in the best 5%.
      final first = engine.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 25)),
          imageStats: seeingSeries(1.8, const Duration(minutes: 25)),
        ),
      );
      expect(first, hasLength(1));

      // A new, even better best 5 min later would normally fire, but the
      // 30-min cooldown on the eventType suppresses it.
      final tooSoon = engine.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 30)),
          imageStats: seeingSeries(1.5, const Duration(minutes: 30)),
        ),
      );
      expect(tooSoon, isEmpty);

      // After the cooldown elapses, a new best fires again.
      final later = engine.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 60)),
          imageStats: seeingSeries(1.4, const Duration(minutes: 60)),
        ),
      );
      expect(later, hasLength(1));
    });
  });

  group('GradientDetector', () {
    test('fires once after 5 consecutive over-threshold frames', () {
      final d = GradientDetector();
      final fq = <ScienceFrameQualityMetricsRow>[];
      for (var i = 0; i < 5; i++) {
        fq.add(
          _frameQuality(
            id: i,
            timestamp: _at(Duration(minutes: i)),
            gradientX: -0.3, // left-edge gradient, magnitude 0.3 > 0.15
          ),
        );
      }
      final ctx = NarratorContext(
        now: _at(const Duration(minutes: 5)),
        frameQuality: fq,
      );
      final fired = d.evaluate(ctx);
      expect(fired, hasLength(1));
      expect(fired.single.eventType, 'equipment.gradient');
      expect(fired.single.headline, contains('left-edge'));
      // Open — no re-fire.
      expect(d.evaluate(ctx), isEmpty);
    });

    test('does not fire when only some frames are over threshold', () {
      final d = GradientDetector();
      final fq = <ScienceFrameQualityMetricsRow>[];
      for (var i = 0; i < 5; i++) {
        fq.add(
          _frameQuality(
            id: i,
            timestamp: _at(Duration(minutes: i)),
            gradientX: i == 4 ? 0.3 : 0.0,
          ),
        );
      }
      expect(
        d.evaluate(
          NarratorContext(
            now: _at(const Duration(minutes: 5)),
            frameQuality: fq,
          ),
        ),
        isEmpty,
      );
    });
  });

  group('ClippingDetector', () {
    test('fires once on 5 consecutive high-clip frames', () {
      final d = ClippingDetector();
      final fq = <ScienceFrameQualityMetricsRow>[];
      for (var i = 0; i < 5; i++) {
        fq.add(
          _frameQuality(
            id: i,
            timestamp: _at(Duration(minutes: i)),
            highClip: 2.0,
          ),
        );
      }
      final ctx = NarratorContext(
        now: _at(const Duration(minutes: 5)),
        frameQuality: fq,
      );
      final fired = d.evaluate(ctx);
      expect(fired, hasLength(1));
      expect(fired.single.eventType, 'quality.clipping');
      expect(fired.single.severity, NarratorSeverity.warning);
      expect(d.evaluate(ctx), isEmpty);
    });
  });

  group('TiltDetector', () {
    OpticalTrainDiagnostics diag(double score, {String dir = 'NE'}) {
      return OpticalTrainDiagnostics(
        tiltScore: score,
        collimationScore: 5.0,
        dominantTiltDirection: dir,
        issues: const [],
      );
    }

    NarratorContext ctx(double score, {String dir = 'NE'}) => NarratorContext(
      now: _t0,
      diagnostics: diag(score, dir: dir),
    );

    test('below the warn band fires nothing', () {
      final d = TiltDetector();
      expect(d.evaluate(ctx(17.9)), isEmpty);
    });

    test('warn band edge fires a warning naming the direction', () {
      final d = TiltDetector();
      final fired = d.evaluate(ctx(18.0, dir: 'NE'));
      expect(fired, hasLength(1));
      expect(fired.single.eventType, 'equipment.tilt');
      expect(fired.single.severity, NarratorSeverity.warning);
      expect(fired.single.headline, contains('NE corner'));
      expect(fired.single.dedupeKey, 'equipment.tilt:warn');
      // Once per band: no re-fire in the warn band.
      expect(d.evaluate(ctx(20.0)), isEmpty);
    });

    test('critical band edge fires critical and subsumes the warn band', () {
      final d = TiltDetector();
      final fired = d.evaluate(ctx(30.0, dir: 'SW'));
      expect(fired, hasLength(1));
      expect(fired.single.severity, NarratorSeverity.critical);
      expect(fired.single.headline, contains('SW corner'));
      expect(fired.single.dedupeKey, 'equipment.tilt:critical');
      // A subsequent warn-level reading does not re-fire (warn subsumed).
      expect(d.evaluate(ctx(20.0)), isEmpty);
    });

    test('escalates warn → critical across crossings', () {
      final d = TiltDetector();
      final warn = d.evaluate(ctx(18.0));
      expect(warn.single.severity, NarratorSeverity.warning);
      final crit = d.evaluate(ctx(30.0));
      expect(crit.single.severity, NarratorSeverity.critical);
    });

    test('headline reports the tilt score, not a fabricated % softer', () {
      final d = TiltDetector();
      final fired = d.evaluate(ctx(32.0, dir: 'NE'));
      expect(fired.single.headline, contains('tilt score 32'));
      expect(fired.single.headline, contains('(critical)'));
      // Tilt score is not a percentage: no "% softer" phrasing.
      expect(fired.single.headline, isNot(contains('% softer')));
      expect(fired.single.body, isNot(contains('%')));
    });
  });

  group('SolveDropDetector', () {
    List<bool> solves({required int trueCount, required int falseCount}) {
      return [
        for (var i = 0; i < trueCount; i++) true,
        for (var i = 0; i < falseCount; i++) false,
      ];
    }

    test('healthy → collapse transition fires once', () {
      final d = SolveDropDetector();
      // First a healthy window (≥80% solved over 10).
      final healthy = d.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 1)),
          solveHistory: solves(trueCount: 10, falseCount: 0),
        ),
      );
      expect(healthy, isEmpty);

      // Then a collapsed window (<50% over the last 10).
      final collapsed = d.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 2)),
          solveHistory: [
            ...solves(trueCount: 10, falseCount: 0),
            ...solves(trueCount: 3, falseCount: 7),
          ],
        ),
      );
      expect(collapsed, hasLength(1));
      expect(collapsed.single.eventType, 'quality.solve_drop');
      expect(collapsed.single.severity, NarratorSeverity.warning);

      // Open — no immediate re-fire while still collapsed.
      expect(
        d.evaluate(
          NarratorContext(
            now: _at(const Duration(minutes: 3)),
            solveHistory: [
              ...solves(trueCount: 10, falseCount: 0),
              ...solves(trueCount: 3, falseCount: 7),
            ],
          ),
        ),
        isEmpty,
      );
    });

    test('never-healthy collapse never fires', () {
      final d = SolveDropDetector();
      // Starts below the healthy threshold and stays low — no prior healthy
      // state, so the "drop from healthy" condition is never met.
      final fired = d.evaluate(
        NarratorContext(
          now: _at(const Duration(minutes: 1)),
          solveHistory: solves(trueCount: 3, falseCount: 7),
        ),
      );
      expect(fired, isEmpty);
      // Even on a second low window it must stay quiet.
      expect(
        d.evaluate(
          NarratorContext(
            now: _at(const Duration(minutes: 2)),
            solveHistory: solves(trueCount: 2, falseCount: 8),
          ),
        ),
        isEmpty,
      );
    });
  });
}
