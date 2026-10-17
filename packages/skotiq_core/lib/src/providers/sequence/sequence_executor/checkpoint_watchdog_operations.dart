part of '../sequence_executor.dart';

extension _SequenceExecutorCheckpointWatchdogOperations on SequenceExecutor {
  void _startCheckpointTimer() {
    _checkpointTimer?.cancel();
    _checkpointTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (_ref.read(sequenceExecutionStateProvider) ==
          SequenceExecutionState.running) {
        // Serialise saves: skip this tick if the previous save is still
        // running so two writers never race the same checkpoint file.
        if (_checkpointSaveInFlight) return;
        _checkpointSaveInFlight = true;
        try {
          final backend = _backend;
          await backend.saveCheckpoint();
        } catch (e) {
          // Checkpoint write failure must not interrupt the running sequence;
          // the next tick will retry.
          _logger.warning(
            'Failed to save checkpoint: $e',
            source: 'SequenceExecutor',
          );
        } finally {
          _checkpointSaveInFlight = false;
        }
      }
    });
  }

  /// Start the disk-space watchdog for the duration of this run.
  ///
  /// Watches the capture directory and:
  ///  - logs a warning event when free space drops below the configured
  ///    warning threshold (default 10 GB);
  ///  - pauses the running sequence when free space drops below the configured
  ///    abort threshold (default 2 GB), so the in-flight frame finishes
  ///    cleanly rather than the OS killing the writer mid-stream.
  ///
  /// Skipped silently when no capture path is configured — the pre-flight
  /// dialog already warns about that and there's nothing useful to monitor.
  void _startDiskSpaceWatchdog() {
    _diskWatchdogSubscription?.cancel();
    _diskWatchdogSubscription = null;

    final settings = _ref.read(appSettingsProvider).valueOrNull;
    final capturePath = settings?.imageOutputPath ?? '';
    if (capturePath.isEmpty) {
      _logger.warning(
        'Disk-space watchdog not started: no capture path configured',
        source: 'SequenceExecutor',
      );
      return;
    }

    final guard = _ref.read(diskSpaceGuardProvider);
    guard.start(capturePath: capturePath);
    _diskWatchdogSubscription = guard.events.listen((event) async {
      _logger.warning(
        '[disk-watchdog] ${event.message}',
        source: 'SequenceExecutor',
      );
      if (event.severity == DiskSpaceSeverity.blocking) {
        // Critical: an unattended low-disk condition will NOT self-recover —
        // the writer is about to run out of space and the operator is asleep.
        // Merely pausing leaves the mount tracking the sky all night with a
        // dead session, which is unsafe (it can drive into the ground / a
        // pier collision past the meridian). Route through the shared
        // SafeRigService so we pause (preserving the checkpoint — pause, not
        // stop), PARK the mount, and raise a CRITICAL notification. SafeRig
        // fails loud: it throws on partial failure and we log it, but the
        // watchdog keeps running.
        try {
          await _ref
              .read(safeRigServiceProvider)
              .safeTheRig(
                reason: 'Disk space critically low: ${event.message}',
                park: true,
              );
        } catch (e, stack) {
          _logger.error(
            'Failed to safe the rig on disk-space abort: $e\n$stack',
            source: 'SequenceExecutor',
          );
        }
      }
    });
  }

  /// Tear down the per-run timers + transient run state in ONE place so the
  /// terminal event handlers (`SequenceCompleted` / `SequenceStopped` /
  /// `SequenceFailed`) and `stop()` stay in lockstep. A partial teardown that
  /// cancels `_progressTimer` alone leaves `_checkpointTimer` running and
  /// `_startTime` / `_isPaused` stale, which mis-seeds the next run.
  void _resetRunTimers() {
    _progressTimer?.cancel();
    _progressTimer = null;
    _checkpointTimer?.cancel();
    _checkpointTimer = null;
    _startTime = null;
    _isPaused = false;
  }

  void _stopDiskSpaceWatchdog() {
    _diskWatchdogSubscription?.cancel();
    _diskWatchdogSubscription = null;
    try {
      _ref.read(diskSpaceGuardProvider).stop();
    } catch (_) {
      // Disposed provider — ignore.
    }
  }
}
