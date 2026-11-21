import 'dart:async';

/// Ends an accepted desktop quit.
///
/// Order is the one that leaves a readable database: flush placement, hand
/// Darkroom work off, close the database, then exit. The window is not
/// destroyed. A second call while the first is still running does nothing.
/// If the hand-off or the close throws, the process stays up.
abstract final class AcceptedDesktopQuit {
  static bool _running = false;

  /// Tests share one process, so a quit that already exited has to be
  /// forgotten before the next one.
  static void resetForTest() => _running = false;

  static Future<void> run({
    required Future<void> Function() flushPlacement,
    required Future<void> Function() handOffDarkroomWork,
    required Future<void> Function() closeDatabase,
    required void Function(int code) exitProcess,
  }) async {
    if (_running) return;
    _running = true;
    try {
      await flushPlacement();
      await handOffDarkroomWork();
      await closeDatabase();
    } catch (error) {
      _running = false;
      rethrow;
    }
    exitProcess(0);
  }
}
