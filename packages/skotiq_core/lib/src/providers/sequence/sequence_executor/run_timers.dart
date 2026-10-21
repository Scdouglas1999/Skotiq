import 'dart:async';

import '../../../services/disk_space_guard.dart';
import '../../../services/logging_service.dart';

/// The periodic work a run owns: the 1 s elapsed-time ticker, the 30 s
/// checkpoint saver and the disk-space watchdog. Started once per run and
/// stopped by finalization (or [dispose]) in one place, so a partial teardown
/// cannot leave one of them running into the next run.
class RunTimers {
  RunTimers({
    required bool Function() isPaused,
    required void Function(double elapsedSecs) onElapsed,
    required bool Function() isRunning,
    required Future<void> Function() saveCheckpoint,
    required String Function() capturePath,
    required DiskSpaceGuardService Function() diskGuard,
    required Future<void> Function(String reason) safeTheRig,
    required LoggingService Function() logger,
  }) : _isPaused = isPaused,
       _onElapsed = onElapsed,
       _isRunning = isRunning,
       _saveCheckpoint = saveCheckpoint,
       _capturePath = capturePath,
       _diskGuard = diskGuard,
       _safeTheRig = safeTheRig,
       _logger = logger;

  final bool Function() _isPaused;
  final void Function(double elapsedSecs) _onElapsed;
  final bool Function() _isRunning;
  final Future<void> Function() _saveCheckpoint;
  final String Function() _capturePath;
  final DiskSpaceGuardService Function() _diskGuard;
  final Future<void> Function(String reason) _safeTheRig;
  final LoggingService Function() _logger;

  Timer? _progressTimer;
  DateTime? _startTime;
  Timer? _checkpointTimer;
  StreamSubscription<DiskSpaceWatchdogEvent>? _diskWatchdog;

  /// A slow save can outlive the 30 s cadence; a tick that finds one still
  /// running skips, so two writers never race the same checkpoint file.
  bool _checkpointSaveInFlight = false;

  void start() {
    _startTime = DateTime.now();
    _progressTimer?.cancel();
    _progressTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final startTime = _startTime;
      if (_isPaused() || startTime == null) return;
      _onElapsed(DateTime.now().difference(startTime).inSeconds.toDouble());
    });
    _startCheckpointTimer();
    _startDiskWatchdog();
  }

  /// Cancel the ticker and the checkpoint saver.
  void stopTimers() {
    _progressTimer?.cancel();
    _progressTimer = null;
    _checkpointTimer?.cancel();
    _checkpointTimer = null;
    _startTime = null;
  }

  void stopDiskWatchdog() {
    _diskWatchdog?.cancel();
    _diskWatchdog = null;
    try {
      _diskGuard().stop();
    } catch (_) {
      // The guard's provider is already disposed.
    }
  }

  void dispose() {
    stopTimers();
    stopDiskWatchdog();
  }

  void _startCheckpointTimer() {
    _checkpointTimer?.cancel();
    _checkpointTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (!_isRunning() || _checkpointSaveInFlight) return;
      _checkpointSaveInFlight = true;
      try {
        await _saveCheckpoint();
      } catch (e) {
        // A failed save must not interrupt the run; the next tick retries.
        _logger().warning(
          'Failed to save checkpoint: $e',
          source: 'SequenceExecutor',
        );
      } finally {
        _checkpointSaveInFlight = false;
      }
    });
  }

  /// Watch the capture directory: below the warning threshold log a warning;
  /// below the abort threshold pause, park and raise a critical notification
  /// through SafeRig, because an unattended low-disk run will not recover and
  /// a merely paused mount keeps tracking toward the pier. Skipped when no
  /// capture path is configured (preflight already warns about that).
  void _startDiskWatchdog() {
    _diskWatchdog?.cancel();
    _diskWatchdog = null;

    final capturePath = _capturePath();
    if (capturePath.isEmpty) {
      _logger().warning(
        'Disk-space watchdog not started: no capture path configured',
        source: 'SequenceExecutor',
      );
      return;
    }

    final guard = _diskGuard();
    guard.start(capturePath: capturePath);
    _diskWatchdog = guard.events.listen((event) async {
      _logger().warning(
        '[disk-watchdog] ${event.message}',
        source: 'SequenceExecutor',
      );
      if (event.severity != DiskSpaceSeverity.blocking) return;
      try {
        await _safeTheRig('Disk space critically low: ${event.message}');
      } catch (e, stack) {
        // SafeRig throws on partial failure; the watchdog keeps running.
        _logger().error(
          'Failed to safe the rig on disk-space abort: $e\n$stack',
          source: 'SequenceExecutor',
        );
      }
    });
  }
}
