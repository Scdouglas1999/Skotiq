import 'package:drift/drift.dart' show DriftSqlType;
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

ScienceFrameQualityMetricsRow _fq({
  double highClipPercent = 0.1,
  double lowClipPercent = 0.1,
  double uniformityCv = 0.05,
  double snr = 30,
}) {
  return ScienceFrameQualityMetricsRow(
    id: 1,
    capturedImageId: null,
    sessionId: null,
    timestamp: DateTime.now(),
    median: 0,
    mean: 0,
    stdDev: 0,
    mad: 0,
    background: 0,
    noise: 0,
    snr: snr,
    dynamicRangeP1P99: 0,
    lowClipPercent: lowClipPercent,
    highClipPercent: highClipPercent,
    uniformityCv: uniformityCv,
    gradientX: 0,
    gradientY: 0,
    processingTier: 'live',
    processingMs: 12,
  );
}

FramePhotometricCalibrationRow _cal({
  bool isCalibrated = true,
  double zeroPoint = 25.0,
  int matched = 30,
  double rms = 0.05,
}) {
  return FramePhotometricCalibrationRow(
    bandIsStandard: false,
    id: 1,
    capturedImageId: null,
    sessionId: null,
    isCalibrated: isCalibrated,
    zeroPoint: zeroPoint,
    limitingMag3Sigma: null,
    limitingMag5Sigma: null,
    matchedStarCount: matched,
    calibrationRms: rms,
    catalogSource: 'apass',
    solverId: 'astap',
    timestamp: DateTime.now(),
  );
}

TransparencySampleRow _trans({double pct = 95}) {
  return TransparencySampleRow(
    extinctionMeasured: false,
    id: 1,
    capturedImageId: null,
    sessionId: null,
    transparencyPercent: pct,
    extinctionCoefficient: 0.2,
    qualityBucket: pct >= 90 ? 'Clear' : 'Thin Cloud',
    confidence: 0.9,
    timestamp: DateTime.now(),
  );
}

void main() {
  const engine = ScienceInsightsEngine();

  test('drift row factories produce valid models', () {
    expect(_fq().snr, 30);
    expect(_cal().matchedStarCount, 30);
    expect(_trans(pct: 80).qualityBucket, 'Thin Cloud');
    // Touch the type so the drift import is meaningfully exercised.
    expect(DriftSqlType.bool, isNotNull);
  });

  test('no inputs yields zero insights', () {
    final result = engine.evaluate(const ScienceInsightsInputs());
    expect(result, isEmpty);
  });

  test('surfaces a failed stage as an error insight', () {
    final result = engine.evaluate(
      ScienceInsightsInputs(
        lastFailure: ScienceStageResult(
          stage: ScienceStage.plateSolve,
          outcome: ScienceStageOutcome.failed,
          timestamp: DateTime.now(),
          note: 'no WCS available',
        ),
      ),
    );
    expect(result, isNotEmpty);
    expect(result.first.severity, ScienceInsightSeverity.error);
    expect(result.first.headline, contains('Plate solve'));
    expect(result.first.body, contains('no WCS'));
  });

  test('warns when no frames have plate-solved', () {
    final result = engine.evaluate(
      const ScienceInsightsInputs(processedFrameCount: 5, solvedFrameCount: 0),
    );
    expect(result.any((i) => i.id == 'solve.none'), isTrue);
  });

  test('warns when solve rate is under 50%', () {
    final result = engine.evaluate(
      const ScienceInsightsInputs(processedFrameCount: 10, solvedFrameCount: 3),
    );
    expect(result.any((i) => i.id == 'solve.low_rate'), isTrue);
  });

  test('reports transparency warm-up remainder once a session is going', () {
    final result = engine.evaluate(
      const ScienceInsightsInputs(
        processedFrameCount: 2,
        calibratedFrameCount: 2,
      ),
    );
    final warmup = result.firstWhere((i) => i.id == 'transparency.warming_up');
    expect(warmup.headline, contains('3 more'));
  });

  test('stays quiet on a fresh install (no captures yet)', () {
    final result = engine.evaluate(const ScienceInsightsInputs());
    expect(result, isEmpty);
  });

  test('flags high clipping with concrete action', () {
    final result = engine.evaluate(
      ScienceInsightsInputs(latestFrameQuality: _fq(highClipPercent: 2.0)),
    );
    expect(result.any((i) => i.id == 'frame.high_clip'), isTrue);
  });

  test('flags transparency below 75%', () {
    final result = engine.evaluate(
      ScienceInsightsInputs(latestTransparency: _trans(pct: 60)),
    );
    expect(result.any((i) => i.id == 'transparency.below_threshold'), isTrue);
  });

  test('flags few-match calibration', () {
    final result = engine.evaluate(
      ScienceInsightsInputs(latestCalibration: _cal(matched: 5)),
    );
    expect(result.any((i) => i.id == 'calibration.few_matches'), isTrue);
  });

  test('errors sort before warnings sort before info', () {
    final result = engine.evaluate(
      ScienceInsightsInputs(
        lastFailure: ScienceStageResult(
          stage: ScienceStage.calibration,
          outcome: ScienceStageOutcome.failed,
          timestamp: DateTime.now(),
          note: 'boom',
        ),
        processedFrameCount: 10,
        solvedFrameCount: 3,
        latestFrameQuality: _fq(highClipPercent: 2.0, snr: 1.5),
      ),
    );
    expect(result.first.severity, ScienceInsightSeverity.error);
    final firstWarning = result.indexWhere(
      (i) => i.severity == ScienceInsightSeverity.warning,
    );
    final firstInfo = result.indexWhere(
      (i) => i.severity == ScienceInsightSeverity.info,
    );
    expect(firstWarning < firstInfo || firstInfo == -1, isTrue);
  });

  group('read-noise advice', () {
    // The rig's darkest NGC 891 subs (B, 120 s): robust sky noise about
    // 169 ADU at a measured gain of 0.123 e-/ADU and 2.0 e- read noise.
    test('a dark-sky sub that is sky-limited gets no "longer subs" advice', () {
      final ratio = skyToReadNoiseRatio(
        noiseAdu: 169,
        gainEPerAdu: 0.123,
        readNoiseE: 2.0,
      )!;
      expect(ratio, greaterThan(kSkyLimitedNoiseRatio));
      final result = engine.evaluate(
        ScienceInsightsInputs(
          processedFrameCount: 1,
          latestFrameQuality: _fq(snr: ratio),
        ),
      );
      expect(
        result.map((i) => i.id),
        isNot(contains('frame.read_noise_limited')),
      );
    });

    test('a read-noise-limited sub is told how much read noise costs', () {
      final result = engine.evaluate(
        ScienceInsightsInputs(
          processedFrameCount: 1,
          latestFrameQuality: _fq(snr: 1.0),
        ),
      );
      final insight = result.firstWhere(
        (i) => i.id == 'frame.read_noise_limited',
      );
      expect(insight.body, contains('1.0x the read noise'));
      expect(insight.body, contains('41%'));
    });

    test('no advice when gain or read noise is unknown (stored as 0)', () {
      final result = engine.evaluate(
        ScienceInsightsInputs(
          processedFrameCount: 1,
          latestFrameQuality: _fq(snr: 0),
        ),
      );
      expect(
        result.map((i) => i.id),
        isNot(contains('frame.read_noise_limited')),
      );
    });
  });
}
