import 'dart:collection';

/// Number of recent per-frame durations retained for the smoothed ETA.
/// Older samples are evicted FIFO. Larger window = smoother but slower to
/// react to genuine cadence changes (e.g. switching from 60s subs to 600s).
const int kEtaWindowSize = 10;

/// Exponential moving average weight applied to the most recent frame.
/// `0.0` would freeze on the first sample; `1.0` would always use the most
/// recent. `0.3` is the balance that absorbs transient outliers (downloads,
/// occasional dither stalls) while still tracking real shifts in cadence.
const double kEtaEmaAlpha = 0.3;

/// Smoothed per-frame cadence, and the run ETA projected from it.
///
/// Fed one sample per completed frame — the event's real exposure duration plus
/// the fixed per-frame download overhead — and keeps an exponential moving
/// average over a bounded window of them.
///
/// It deliberately does NOT synthesise samples from wall-clock elapsed deltas:
/// that folds AF / dither / slew / flip gaps into the per-frame estimate and
/// yanks the ETA around. Wall-clock elapsed is surfaced separately for the
/// elapsed display.
class EtaSmoother {
  /// Sliding window of recent per-frame durations (seconds). Bounded to
  /// [kEtaWindowSize]; older samples are dropped FIFO when full.
  final Queue<double> _samples = Queue<double>();

  double? _smoothedSecsPerFrame;

  /// Smoothed average secs-per-frame, or `null` until at least one positive
  /// sample has been recorded.
  double? get smoothedSecsPerFrame => _smoothedSecsPerFrame;

  /// Number of samples currently in the window.
  int get sampleCount => _samples.length;

  /// Fold one completed frame's duration into the EMA.
  ///
  /// Non-positive and non-finite samples are ignored: several frames can
  /// complete inside a single timer tick, and a zero-or-negative duration is
  /// not a cadence.
  void recordFrame(double secsForFrame) {
    if (!secsForFrame.isFinite || secsForFrame <= 0) return;
    _samples.addLast(secsForFrame);
    if (_samples.length > kEtaWindowSize) {
      _samples.removeFirst();
    }
    final prior = _smoothedSecsPerFrame;
    if (prior == null) {
      // First sample bootstraps the EMA so we don't bias toward zero.
      _smoothedSecsPerFrame = secsForFrame;
    } else {
      _smoothedSecsPerFrame =
          (kEtaEmaAlpha * secsForFrame) + ((1.0 - kEtaEmaAlpha) * prior);
    }
  }

  /// Drop every sample. Called when a run starts or resumes from a checkpoint,
  /// so the smoother does not carry a previous run's exposure cadence.
  void reset() {
    _samples.clear();
    _smoothedSecsPerFrame = null;
  }

  /// Seconds remaining, projected as EMA-secs-per-frame × frames-left.
  ///
  /// Returns `null` when no frames have completed yet, so the UI can show `--`
  /// rather than a number it has no basis for.
  double? remainingSeconds({
    required int completedFrames,
    required int totalFrames,
  }) {
    if (completedFrames <= 0 || totalFrames <= 0) return null;
    final remainingFrames = totalFrames - completedFrames;
    if (remainingFrames <= 0) return 0.0;
    final smoothed = _smoothedSecsPerFrame;
    if (smoothed == null) return null;
    return smoothed * remainingFrames;
  }
}
