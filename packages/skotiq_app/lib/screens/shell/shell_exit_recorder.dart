import 'dart:async';

/// Where the shell announces that THIS quit was the operator's decision.
///
/// The desktop entry point keeps a last-gasp session record so a launch can
/// tell the previous session ended with no shutdown path at all. That record is
/// only trustworthy if a normal quit says so on the way out; otherwise every
/// ordinary close looks like a crash.
///
/// The entry point registers a recorder; the shell calls it as soon as a close
/// is accepted, before anything that ends the process.
///
/// The callback MUST be synchronous — where no [ShellExit.registerEnd] step is
/// installed, `windowManager.destroy()` follows it, and a write that needs
/// another turn of the event loop is a write that never happens.
typedef ShellExitRecorder = void Function(String reason);

/// Process-wide registry for [ShellExitRecorder]. Single-slot on purpose:
/// there is one process and one shutdown record.
abstract final class ShellExit {
  static ShellExitRecorder? _recorder;

  static void register(ShellExitRecorder recorder) => _recorder = recorder;

  static void unregister(ShellExitRecorder recorder) {
    if (identical(_recorder, recorder)) _recorder = null;
  }

  /// Record an operator-initiated quit. Safe to call when nothing is
  /// registered.
  static void recordClean(String reason) => _recorder?.call(reason);

  static Future<void> Function()? _spawnRelaunch;
  static Completer<bool>? _pendingRelaunch;

  /// Install what starts the next process when a relaunch is accepted. The
  /// desktop entry point registers it; nothing else does.
  static void registerRelaunch(Future<void> Function() spawn) =>
      _spawnRelaunch = spawn;

  /// Mark the coming window close as a restart. The returned future completes
  /// true once the close was accepted and the next process started, false
  /// when the operator cancelled the close.
  static Future<bool> requestRelaunch() {
    final pending = _pendingRelaunch;
    if (pending != null && !pending.isCompleted) return pending.future;
    final completer = Completer<bool>();
    _pendingRelaunch = completer;
    return completer.future;
  }

  /// The close was declined: no restart.
  static void cancelPendingRelaunch() {
    final pending = _pendingRelaunch;
    _pendingRelaunch = null;
    if (pending != null && !pending.isCompleted) pending.complete(false);
  }

  static Future<void> Function()? _endProcess;

  /// Install how this process ends once a close is accepted, in place of the
  /// window teardown. The desktop entry point registers it where that teardown
  /// is not safe to rely on.
  /// Null puts the window teardown back.
  static void registerEnd(Future<void> Function()? end) => _endProcess = end;

  /// The end step [registerEnd] installed, or null to destroy the window.
  static Future<void> Function()? get endProcess => _endProcess;

  /// The close was accepted: start the next process, if one was requested.
  /// Runs before the process ends.
  static Future<void> runPendingRelaunch() async {
    final pending = _pendingRelaunch;
    _pendingRelaunch = null;
    if (pending == null || pending.isCompleted) return;
    final spawn = _spawnRelaunch;
    if (spawn == null) {
      pending.complete(false);
      return;
    }
    var spawned = false;
    try {
      await spawn();
      spawned = true;
    } finally {
      // A failed spawn still answers the waiter before the error propagates.
      pending.complete(spawned);
    }
  }
}
