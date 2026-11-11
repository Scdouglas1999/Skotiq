import 'dart:async';

/// How much longer than its base interval a background poll waits on this
/// device.
///
/// The phone app slows its polls of the host while its battery is low, while
/// battery saver is on and while it is on cellular data; every other process
/// leaves the pace at 1. Polls read it each time they schedule their next
/// fetch, so a change applies from the next wait on.
abstract final class PollPace {
  static int _multiplier = 1;

  /// The factor applied to every paced interval. At least 1.
  static int get multiplier => _multiplier;

  static set multiplier(int value) {
    if (value < 1) {
      throw ArgumentError.value(value, 'multiplier', 'must be at least 1');
    }
    _multiplier = value;
  }

  /// [base] at the current pace.
  static Duration stretch(Duration base) => base * _multiplier;
}

/// A repeating timer that waits [PollPace.stretch] of [base] before each
/// [onTick], so a change of pace applies from the next tick.
Timer pacedPeriodicTimer(Duration base, void Function() onTick) =>
    _PacedTimer(base, onTick);

final class _PacedTimer implements Timer {
  _PacedTimer(this._base, this._onTick) {
    _schedule();
  }

  final Duration _base;
  final void Function() _onTick;
  late Timer _next;
  int _tick = 0;
  bool _cancelled = false;

  void _schedule() {
    _next = Timer(PollPace.stretch(_base), () {
      _tick++;
      try {
        _onTick();
      } finally {
        // Like Timer.periodic, a tick that throws does not end the timer.
        if (!_cancelled) _schedule();
      }
    });
  }

  @override
  void cancel() {
    _cancelled = true;
    _next.cancel();
  }

  @override
  bool get isActive => !_cancelled;

  @override
  int get tick => _tick;
}
