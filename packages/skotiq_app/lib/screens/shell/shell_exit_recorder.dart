/// Where the shell announces that THIS quit was the operator's decision.
///
/// The desktop entry point keeps a last-gasp session record so a launch can
/// tell the previous session ended with no shutdown path at all. That record is
/// only trustworthy if a normal quit says so on the way out; otherwise every
/// ordinary close looks like a crash.
///
/// The entry point registers a recorder; the shell calls it immediately before
/// destroying the window.
///
/// The callback MUST be synchronous — `windowManager.destroy()` follows it, and
/// a write that needs another turn of the event loop is a write that never
/// happens.
typedef ShellExitRecorder = void Function(String reason);

/// Process-wide registry for [ShellExitRecorder]. Single-slot on purpose:
/// there is one process and one shutdown record.
abstract final class ShellExit {
  static ShellExitRecorder? _recorder;

  /// Install the recorder. Replaces any previous one.
  static void register(ShellExitRecorder recorder) => _recorder = recorder;

  /// Remove [recorder] if it is the one currently installed.
  static void unregister(ShellExitRecorder recorder) {
    if (identical(_recorder, recorder)) _recorder = null;
  }

  /// True when an entry point is listening (mobile/web never register).
  static bool get hasRecorder => _recorder != null;

  /// Record an operator-initiated quit. Safe to call when nothing is
  /// registered.
  static void recordClean(String reason) => _recorder?.call(reason);
}
