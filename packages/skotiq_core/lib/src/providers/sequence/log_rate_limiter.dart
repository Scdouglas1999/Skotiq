/// Keeps one repetitive diagnostic from consuming the whole log.
///
/// `SequenceExecutor._handleSequencerEvent` traces EVERY backend event at debug
/// level ("Received event: type=…, category=…"). At roughly five lines a second
/// that fills `LoggingService`'s 1000-entry in-memory ring — the ring
/// Settings ▸ Advanced ▸ Logs and `/api/logs/recent` read — in about three
/// minutes. Unlimited, an autopilot night leaves the viewer showing nothing but
/// `SequenceExecutor` DBG rows with no other producer in its source dropdown,
/// and any diagnostic worth reading (the scheduler's reconcile line included)
/// is gone before the operator looks.
///
/// The trace is worth keeping — when an event goes missing it is the only
/// evidence Dart ever saw it — so it is rate-limited rather than deleted.
///
/// Two properties make that safe:
///   * the limit is PER KEY, so a chatty event type cannot hide a rare one
///     (an operator Stop in the middle of an InstructionProgress flood still
///     logs immediately), and
///   * nothing is dropped silently: the next admitted line for a key reports
///     how many copies were suppressed behind it.
library;

class LogRateLimiter {
  LogRateLimiter({required this.window, DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  /// One line per key per window.
  final Duration window;
  final DateTime Function() _now;

  final Map<String, _KeyState> _keys = {};

  /// Keys whose window closed longer ago than this are forgotten, so a long
  /// unattended night cannot grow the map without bound.
  static const Duration _retention = Duration(minutes: 5);

  /// Number of keys currently tracked (test/diagnostic surface).
  int get trackedKeys => _keys.length;

  /// Returns the line to log for [key], or `null` when this one is suppressed.
  ///
  /// The returned string is [message], possibly with a suffix naming the
  /// suppressed count — the caller logs exactly what comes back.
  String? admit(String key, String message) {
    final now = _now();
    _prune(now);
    final state = _keys[key];
    if (state == null) {
      _keys[key] = _KeyState(lastAdmitted: now);
      return message;
    }
    if (now.difference(state.lastAdmitted) < window) {
      state.suppressed++;
      return null;
    }
    final suppressed = state.suppressed;
    state
      ..lastAdmitted = now
      ..suppressed = 0;
    if (suppressed == 0) return message;
    return '$message (+$suppressed suppressed in the last '
        '${window.inSeconds}s)';
  }

  void _prune(DateTime now) {
    _keys.removeWhere(
      (_, state) => now.difference(state.lastAdmitted) > _retention,
    );
  }
}

class _KeyState {
  _KeyState({required this.lastAdmitted});
  DateTime lastAdmitted;
  int suppressed = 0;
}
