import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_core/src/providers/sequence/sequence_executor/eta_smoothing.dart';

// Tests [EtaSmoother] — the ETA cadence smoother the run's progress timer
// projects from — and the published tuning constants.
//
// The EMA bootstraps to the first sample and then reads
// `ema = alpha*sample + (1-alpha)*priorEma`. The window cap bounds memory; it
// does not truncate the EMA, which is already smoothed.

void main() {
  double emaOf(Iterable<double> samples) {
    final smoother = EtaSmoother();
    for (final s in samples) {
      smoother.recordFrame(s);
    }
    return smoother.smoothedSecsPerFrame ?? 0.0;
  }

  group('ETA smoothing constants', () {
    test('window size is 10', () {
      expect(kEtaWindowSize, 10);
    });

    test('EMA alpha is 0.3 (balance between responsiveness and stability)', () {
      expect(kEtaEmaAlpha, closeTo(0.3, 1e-9));
    });
  });

  group('EtaSmoother EMA', () {
    test('no samples means no cadence', () {
      expect(EtaSmoother().smoothedSecsPerFrame, isNull);
    });

    test('first sample bootstraps the EMA', () {
      expect(emaOf([60.0]), closeTo(60.0, 1e-9));
    });

    test('outlier sample is absorbed, not amplified', () {
      // Baseline 60s subs, one 600s outlier.
      // ema after [60]: 60
      // ema after [60, 600]: 0.3*600 + 0.7*60 = 180 + 42 = 222
      // ema after [60, 600, 60]: 0.3*60 + 0.7*222 = 18 + 155.4 = 173.4
      // ema after [60, 600, 60, 60]: 0.3*60 + 0.7*173.4 = 18 + 121.38 = 139.38
      // Naive average would be (60+600+60+60)/4 = 195
      // EMA gives 139.38 — heavier weight on more-recent normal samples.
      final ema = emaOf([60.0, 600.0, 60.0, 60.0]);
      expect(
        ema,
        lessThan(195.0),
        reason: 'EMA should be lower than a naive average',
      );
      expect(ema, closeTo(139.38, 0.1));
    });

    test('non-positive and non-finite samples are skipped', () {
      final ema = emaOf([60.0, 0.0, -1.0, double.nan, 60.0]);
      expect(ema, closeTo(60.0, 1e-9));
    });

    test('the window bounds memory without truncating the EMA', () {
      final smoother = EtaSmoother();
      for (var i = 0; i < kEtaWindowSize + 5; i++) {
        smoother.recordFrame(100.0);
      }
      expect(smoother.sampleCount, kEtaWindowSize);
      expect(smoother.smoothedSecsPerFrame, closeTo(100.0, 1e-9));
    });

    test('reset drops every sample so a new run starts clean', () {
      final smoother = EtaSmoother()..recordFrame(600.0);
      smoother.reset();
      expect(smoother.smoothedSecsPerFrame, isNull);
      expect(smoother.sampleCount, 0);

      smoother.recordFrame(60.0);
      expect(smoother.smoothedSecsPerFrame, closeTo(60.0, 1e-9));
    });
  });

  group('EtaSmoother projection', () {
    test('no completed frames means no ETA', () {
      final smoother = EtaSmoother()..recordFrame(60.0);
      expect(
        smoother.remainingSeconds(completedFrames: 0, totalFrames: 10),
        isNull,
      );
    });

    test('no cadence yet means no ETA', () {
      expect(
        EtaSmoother().remainingSeconds(completedFrames: 3, totalFrames: 10),
        isNull,
      );
    });

    test('an unknown denominator means no ETA', () {
      final smoother = EtaSmoother()..recordFrame(60.0);
      expect(
        smoother.remainingSeconds(completedFrames: 3, totalFrames: 0),
        isNull,
      );
    });

    test('projects EMA seconds across the frames left', () {
      final smoother = EtaSmoother()..recordFrame(60.0);
      expect(
        smoother.remainingSeconds(completedFrames: 4, totalFrames: 10),
        closeTo(360.0, 1e-9),
      );
    });

    test('a finished run has zero remaining', () {
      final smoother = EtaSmoother()..recordFrame(60.0);
      expect(
        smoother.remainingSeconds(completedFrames: 10, totalFrames: 10),
        0.0,
      );
    });
  });
}
