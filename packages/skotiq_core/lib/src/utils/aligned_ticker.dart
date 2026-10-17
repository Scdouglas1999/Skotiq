import 'dart:async';

/// How long from [now] until the next multiple of [period] measured from the
/// epoch — i.e. the next instant on the shared wall-clock boundary.
///
/// Returns a full [period] when [now] is already exactly on a boundary, so a
/// caller never schedules a zero-delay timer and spins.
Duration delayToNextBoundary(Duration period, {DateTime? now}) {
  final periodUs = period.inMicroseconds;
  if (periodUs <= 0) {
    return Duration.zero;
  }
  final nowUs = (now ?? DateTime.now()).toUtc().microsecondsSinceEpoch;
  final remainder = nowUs % periodUs;
  return Duration(microseconds: periodUs - remainder);
}

/// A repeating tick that always lands on the wall-clock boundary of its period,
/// no matter when it was started.
///
/// ## Why the phase matters more than the rate
///
/// A once-a-second clock sounds free, and one of them nearly is. The cost is
/// not the rate, it is the *phase*: Flutter schedules a frame whenever anything
/// marks itself dirty, and the Linux embedder submits a **full-window** frame
/// for each one regardless of how little actually changed (see the note on
/// `_TimeDisplay` in the shell status bar). Two 1 Hz clocks started 400 ms
/// apart therefore cost two full-window frames a second, three cost three —
/// the idle frame rate of the app is the number of independently-phased
/// clocks in the tree, not the rate any one of them runs at.
///
/// Skotiq had three, all legitimately wanting one tick a second: the
/// status-bar wall clock, the planetarium's observation clock, and the
/// planetarium's wall clock. Each armed a `Timer.periodic` at whatever instant
/// its owner happened to be first built, so the dashboard rendered itself
/// two to three times a second while sitting still.
///
/// Aligning every clock to the same absolute reference — the epoch-second
/// boundary — makes the ticks land in the same event-loop turn, so Flutter
/// coalesces them into one frame. Nothing about the rate or the values changes;
/// a clock that displays seconds also becomes *more* correct, because it now
/// changes its digit on the second rather than up to 999 ms after it.
///
/// Self-rescheduling rather than [Timer.periodic] so a delayed tick re-aligns
/// on the next one instead of carrying the lag forever.
class AlignedTicker {
  /// Starts ticking immediately; the first tick lands on the next boundary.
  ///
  /// [now] exists so a test can drive the alignment off a virtual clock —
  /// `fakeAsync` moves timers but not [DateTime.now], and the whole property
  /// worth testing is *which instant* the ticks land on.
  AlignedTicker(this.period, this._onTick, {DateTime Function()? now})
    : _now = now ?? DateTime.now {
    _schedule();
  }

  /// The cadence, and the boundary the ticks are aligned to.
  final Duration period;

  final void Function() _onTick;
  final DateTime Function() _now;

  Timer? _timer;
  bool _cancelled = false;

  /// Whether ticks are still being delivered.
  bool get isActive => !_cancelled;

  void _schedule() {
    if (_cancelled) {
      return;
    }
    _timer = Timer(delayToNextBoundary(period, now: _now()), () {
      if (_cancelled) {
        return;
      }
      _onTick();
      _schedule();
    });
  }

  /// Stops the ticker. Safe to call more than once.
  void cancel() {
    _cancelled = true;
    _timer?.cancel();
    _timer = null;
  }
}
