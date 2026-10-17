import 'dart:async';

import '../database/daos/sequence_checkpoints_dao.dart';
import '../database/session_orphan_sweep.dart';
import 'imaging_records_repository.dart';
import 'logging_service.dart';

/// Configuration for session checkpointing
class SessionCheckpointConfig {
  /// Re-persist the current statistics on this interval even when no frame has
  /// arrived.
  ///
  /// Every progress update already writes the row, so this timer is not what
  /// keeps the counters current — it is the retry. A checkpoint write that
  /// throws is logged and swallowed (see `_drainCheckpointRequests`), so
  /// without a periodic pass a transient database error would leave the row
  /// stale until the next frame.
  final Duration checkpointTimeInterval;

  /// Whether automatic checkpointing is enabled
  final bool enabled;

  const SessionCheckpointConfig({
    this.checkpointTimeInterval = const Duration(minutes: 5),
    this.enabled = true,
  });

  SessionCheckpointConfig copyWith({
    Duration? checkpointTimeInterval,
    bool? enabled,
  }) {
    return SessionCheckpointConfig(
      checkpointTimeInterval:
          checkpointTimeInterval ?? this.checkpointTimeInterval,
      enabled: enabled ?? this.enabled,
    );
  }
}

/// Statistics tracked during a session for checkpointing
class SessionStats {
  final int completedExposures;
  final int failedExposures;
  final double totalIntegrationSecs;
  final double? avgHfr;
  final double? avgGuidingRms;
  final int autofocusCount;
  final int? lastImageId;
  final DateTime lastUpdated;

  const SessionStats({
    this.completedExposures = 0,
    this.failedExposures = 0,
    this.totalIntegrationSecs = 0.0,
    this.avgHfr,
    this.avgGuidingRms,
    this.autofocusCount = 0,
    this.lastImageId,
    required this.lastUpdated,
  });

  SessionStats copyWith({
    int? completedExposures,
    int? failedExposures,
    double? totalIntegrationSecs,
    double? avgHfr,
    double? avgGuidingRms,
    int? autofocusCount,
    int? lastImageId,
    DateTime? lastUpdated,
  }) {
    return SessionStats(
      completedExposures: completedExposures ?? this.completedExposures,
      failedExposures: failedExposures ?? this.failedExposures,
      totalIntegrationSecs: totalIntegrationSecs ?? this.totalIntegrationSecs,
      avgHfr: avgHfr ?? this.avgHfr,
      avgGuidingRms: avgGuidingRms ?? this.avgGuidingRms,
      autofocusCount: autofocusCount ?? this.autofocusCount,
      lastImageId: lastImageId ?? this.lastImageId,
      lastUpdated: lastUpdated ?? this.lastUpdated,
    );
  }

  /// Calculate success rate
  double get successRate {
    final total = completedExposures + failedExposures;
    if (total == 0) return 1.0;
    return completedExposures / total;
  }
}

/// Result of a session recovery operation
class SessionRecoveryInfo {
  final int sessionId;
  final String? sessionName;
  final int? targetId;
  final String? targetName;
  final DateTime startTime;
  final SessionStats stats;

  const SessionRecoveryInfo({
    required this.sessionId,
    this.sessionName,
    this.targetId,
    this.targetName,
    required this.startTime,
    required this.stats,
  });

  Duration get duration => DateTime.now().difference(startTime);
}

/// Service for managing imaging session lifecycle with persistence and recovery
class SessionService {
  final ImagingRecordsRepository _records;
  final SequenceCheckpointsDao?
  checkpointsDao; // Optional, for sequence integration
  final LoggingService _logger;

  SessionCheckpointConfig _config = const SessionCheckpointConfig();
  Timer? _checkpointTimer;

  // Current session tracking
  int? _currentSessionId;
  SessionStats? _currentStats;
  Future<void>? _checkpointDrain;
  bool _checkpointRequested = false;
  Future<int>? _startInFlight;
  Future<void>? _endInFlight;
  int _sessionGeneration = 0;
  bool _disposed = false;

  // Status tracking
  final _statusController = StreamController<String>.broadcast();

  final DateTime Function() _now;

  /// [nowProvider] lets the desktop wiring supply the user's chosen
  /// [Clock] so session start/end timestamps reflect the operator's
  /// timezone. Defaults to [DateTime.now] for tests and for hosts that
  /// have not configured a TZ override
  SessionService({
    required ImagingRecordsRepository records,
    this.checkpointsDao,
    required LoggingService logger,
    DateTime Function()? nowProvider,
  }) : _records = records,
       _logger = logger,
       _now = nowProvider ?? DateTime.now;

  /// Stream of status updates
  Stream<String> get statusStream => _statusController.stream;

  /// Current session ID (null if no active session)
  int? get currentSessionId => _currentSessionId;

  /// Whether a session is currently active
  bool get hasActiveSession => _currentSessionId != null;

  /// Current session statistics
  SessionStats? get currentStats => _currentStats;

  /// Start a new imaging session
  /// Returns the session ID
  Future<int> startSession({
    String? name,
    int? targetId,
    int? profileId,
    int? sequenceId,
  }) {
    if (_disposed) {
      return Future<int>.error(
        StateError('Cannot start a session after SessionService disposal.'),
      );
    }
    final activeStart = _startInFlight;
    if (activeStart != null) return activeStart;
    if (_endInFlight != null) {
      return Future<int>.error(
        StateError('Cannot start a session while the previous one is ending.'),
      );
    }
    if (_currentSessionId != null) {
      return Future<int>.error(
        Exception(
          'Session already active. End current session before starting a new one.',
        ),
      );
    }

    late final Future<int> operation;
    operation =
        _startSessionOnce(
          name: name,
          targetId: targetId,
          profileId: profileId,
          sequenceId: sequenceId,
        ).whenComplete(() {
          if (identical(_startInFlight, operation)) {
            _startInFlight = null;
          }
        });
    _startInFlight = operation;
    return operation;
  }

  Future<int> _startSessionOnce({
    String? name,
    int? targetId,
    int? profileId,
    int? sequenceId,
  }) async {
    _logger.debug('Starting new session...', source: 'SessionService');
    _logger.debug('  Name: $name', source: 'SessionService');
    _logger.debug('  Target ID: $targetId', source: 'SessionService');
    _logger.debug('  Profile ID: $profileId', source: 'SessionService');
    _logger.debug('  Sequence ID: $sequenceId', source: 'SessionService');

    // Resolve a stranded session BEFORE opening tonight's, so the insert below
    // cannot be refused.
    //
    // `SessionsDao.startSession` throws `ActiveImagingSessionException` while
    // any row is `active`, and both start paths — the executor's
    // `_startSessionRow` and the headless `load -> start` pre-flight — treat
    // that throw as "this run has no session row". The run then captures a full
    // night whose frames all carry `session_id` NULL, and the session-end hooks
    // that key on the session id never fire: no integration, no masters, no
    // Darkroom pass, and `GET /api/sessions/active` still answering with the
    // dead run's counters.
    //
    // This service owns the only live session in the process and holds its id
    // in `_currentSessionId` for the session's whole life; the guard above has
    // already returned when that id is set. So reaching here with an `active`
    // row on disk means the row belongs to nothing — a process that died before
    // the boot sweep could see it, or a run in THIS process that failed after
    // opening its session and could not finalize it. Either way it is closed
    // the way the boot sweep closes one, not silently overwritten.
    await _resolveStrandedSessions();

    // Create database session record with 'active' status
    final sessionId = await _records.startSession(
      name: name,
      profileId: profileId,
      targetId: targetId,
      sequenceId: sequenceId,
    );
    if (_disposed) {
      try {
        await _records.endSession(sessionId, status: 'aborted');
      } catch (error) {
        _logger.error(
          'Could not abort session $sessionId after SessionService was '
          'disposed during startup: $error',
          source: 'SessionService',
        );
      }
      throw StateError('SessionService was disposed while starting a session.');
    }

    // Initialize tracking
    _sessionGeneration++;
    _currentSessionId = sessionId;
    _currentStats = SessionStats(lastUpdated: _now());

    // Start checkpoint timer if enabled
    if (_config.enabled) {
      _startCheckpointTimer();
    }

    _emitStatus('Session started: ID $sessionId');
    _logger.info(
      'Session started with ID: $sessionId',
      source: 'SessionService',
    );

    return sessionId;
  }

  /// Close any `imaging_sessions` row still `active` before this service opens
  /// its own.
  ///
  /// The liveness claim this makes is the one only this service can make: it
  /// holds the id of the session it owns in `_currentSessionId` for that
  /// session's whole life, and `startSession` has already returned by the time
  /// this runs when that id is set. An `active` row reaching here therefore has
  /// nothing driving it.
  ///
  /// The close is the boot sweep's, shared statement and all, so a night closed
  /// here and a night closed at open read identically in History: status
  /// `interrupted`, `end_time` back-dated to its last frame, and a note saying
  /// what ended it.
  ///
  /// A failure here is NOT swallowed. The whole point is that the insert
  /// below must not be refused, and a caller told the session opened when it
  /// did not is exactly the shape that stranded a night's frames in the first
  /// place; the start path's own error handling decides what to do with it.
  Future<void> _resolveStrandedSessions() async {
    final closed = await _records.closeOrphanedSessions(
      cause: kInterruptedByNewSequenceCause,
    );
    if (closed.isEmpty) return;
    _logger.warning(
      'Closed ${closed.length} imaging session'
      '${closed.length == 1 ? '' : 's'} left open with nothing driving '
      '${closed.length == 1 ? 'it' : 'them'} (id'
      '${closed.length == 1 ? '' : 's'} ${closed.join(', ')}); '
      "${closed.length == 1 ? 'it is' : 'they are'} recorded as "
      "'$kInterruptedSessionStatus' so this run can open its own session",
      source: 'SessionService',
    );
  }

  /// Update session progress with new statistics, persisting them immediately.
  ///
  /// [stats] is complete on arrival — the caller folds the frame in before
  /// calling — so the session row advances frame by frame, and every reader of
  /// `imaging_sessions` sees what the night has actually earned.
  ///
  /// It used to persist only after five images (or five minutes), and the row
  /// is what `GET /api/sessions/active` serves. So a healthy run published
  /// `successfulExposures: 0` and `totalIntegrationSecs: 0.0` beside the live
  /// accepted/rejected pair the same endpoint counts off `captured_images`:
  /// the dashboard's session card read "Frames returned 0" next to "4
  /// accepted" for the first four frames of every night, then trailed by up to
  /// four frames for the rest of it. The counters are cheap — one single-row
  /// UPDATE per frame, beside the `captured_images` INSERT the same frame
  /// already performs — and a threshold bought nothing worth a card that
  /// contradicts itself.
  Future<void> updateSessionProgress(SessionStats stats) async {
    if (_currentSessionId == null) {
      _logger.debug('No active session to update', source: 'SessionService');
      return;
    }

    _currentStats = stats;

    if (_config.enabled) {
      // Request the write; do not wait for it. This runs once per captured
      // frame, and on a remote rig the write is an HTTP round trip — awaiting
      // it here puts the network between the camera and the next exposure.
      // The counters still advance per frame without the wait: the drain
      // coalesces every request into one in-flight write that always persists
      // the LATEST stats, and its failures are logged rather than thrown
      // (`_drainCheckpointRequests`). `checkpoint()` and `endSession()` are
      // the callers that genuinely need a fresh snapshot, and they await.
      unawaited(_performCheckpoint());
    }
  }

  /// Manually trigger a checkpoint save
  Future<void> checkpoint() async {
    if (_currentSessionId == null || _currentStats == null) {
      _logger.debug(
        'No active session to checkpoint',
        source: 'SessionService',
      );
      return;
    }

    await _performCheckpoint();
  }

  /// End the current session with finalization.
  ///
  /// Transactional: the durable writes run FIRST and the in-memory session
  /// identity / stats / checkpoint timer are cleared ONLY after they all
  /// succeed. If any write throws we rethrow WITHOUT clearing, so the session
  /// stays active and the caller (e.g. SequenceExecutor's `cleanupFailed`
  /// retry, or a later `endSession`) can re-run this and actually finalize the
  /// row. Clearing identity unconditionally (in a `finally`, say) would leave
  /// the DB row stuck `active` forever, because the early return above then
  /// makes every retry a no-op.
  Future<void> endSession({String status = 'completed'}) {
    if (_disposed) {
      return Future<void>.error(
        StateError('Cannot end a session after SessionService disposal.'),
      );
    }
    final activeEnd = _endInFlight;
    if (activeEnd != null) return activeEnd;

    late final Future<void> operation;
    operation = _endSessionOnce(status: status).whenComplete(() {
      if (identical(_endInFlight, operation)) {
        _endInFlight = null;
      }
    });
    _endInFlight = operation;
    return operation;
  }

  Future<void> _endSessionOnce({required String status}) async {
    // A Stop/Abort tap can race a slow host-side Start. Wait for the admitted
    // start to establish its durable id, then finalize that exact session;
    // returning early here would leave a session running with no visible owner.
    final pendingStart = _startInFlight;
    if (pendingStart != null) await pendingStart;

    final sessionId = _currentSessionId;
    if (sessionId == null) {
      _logger.debug('No active session to end', source: 'SessionService');
      return;
    }

    _logger.info(
      'Ending session $sessionId with status: $status',
      source: 'SessionService',
    );

    // Calculate final statistics
    final stats = _currentStats ?? SessionStats(lastUpdated: _now());

    try {
      // Perform final checkpoint to save latest stats (self-guarded; never
      // throws — its own failure is logged, not propagated).
      if (_currentStats != null) {
        await _performCheckpoint();
      }

      // Update session with final statistics and status
      await _records.updateSessionStats(
        sessionId,
        totalExposures: stats.completedExposures + stats.failedExposures,
        successfulExposures: stats.completedExposures,
        failedExposures: stats.failedExposures,
        totalIntegrationSecs: stats.totalIntegrationSecs,
        avgHfr: stats.avgHfr,
        avgGuidingRms: stats.avgGuidingRms,
        autofocusCount: stats.autofocusCount,
      );

      // Set end time and status
      await _records.endSession(sessionId, status: status);
    } catch (e) {
      _logger.error(
        'Error ending session $sessionId (retaining the active session so it '
        'can be retried): $e',
        source: 'SessionService',
      );
      // Do NOT clear identity/stats/timer — retain everything so a retry can
      // actually finalize the row.
      rethrow;
    }

    // Durable finalization succeeded — now it is safe to clear.
    _stopCheckpointTimer();
    _sessionGeneration++;
    _currentSessionId = null;
    _currentStats = null;

    _emitStatus('Session ended: $sessionId ($status)');
    _logger.info('Session finalized', source: 'SessionService');
    _logger.debug(
      '  Completed: ${stats.completedExposures}',
      source: 'SessionService',
    );
    _logger.debug(
      '  Failed: ${stats.failedExposures}',
      source: 'SessionService',
    );
    _logger.debug(
      '  Integration: ${stats.totalIntegrationSecs}s',
      source: 'SessionService',
    );
    _logger.debug(
      '  Success rate: ${(stats.successRate * 100).toStringAsFixed(1)}%',
      source: 'SessionService',
    );
  }

  /// Abort the current session (marks as 'aborted' status)
  Future<void> abortSession() async {
    await endSession(status: 'aborted');
  }

  /// Mark session as error state
  Future<void> errorSession(String errorMessage) async {
    if (_currentSessionId != null && _currentStats != null) {
      // Optionally store error message in notes
      final currentSession = await _records.getSessionById(_currentSessionId!);
      if (currentSession != null) {
        final notes = currentSession.notes ?? '';
        final errorNotes = notes.isEmpty
            ? errorMessage
            : '$notes\n\nError: $errorMessage';
        await _records.updateSessionNotes(_currentSessionId!, errorNotes);
      }
    }
    await endSession(status: 'error');
  }

  /// Check for incomplete sessions (crashed/interrupted sessions)
  /// Returns list of sessions that can be recovered
  Future<List<SessionRecoveryInfo>> findIncompleteSessionsForRecovery() async {
    _logger.debug(
      'Checking for incomplete sessions...',
      source: 'SessionService',
    );

    try {
      final allSessions = await _records.getAllSessions();

      // Nights a process left unfinished read `interrupted`, not `active`: the
      // boot sweep closes an abandoned row at open so it cannot detach the
      // nights that follow, and stamps that status on the way. `active` is now
      // only ever a session a live executor is driving, and offering to recover
      // a run that is still going would be offering to recover from nothing.
      final incompleteSessions = allSessions
          .where((s) => s.status == kInterruptedSessionStatus)
          .toList();

      if (incompleteSessions.isEmpty) {
        _logger.debug('No incomplete sessions found', source: 'SessionService');
        return [];
      }

      _logger.info(
        'Found ${incompleteSessions.length} incomplete '
        'session${incompleteSessions.length == 1 ? '' : 's'}',
        source: 'SessionService',
      );

      // Convert to recovery info
      final recoveryInfoList = <SessionRecoveryInfo>[];
      for (final session in incompleteSessions) {
        final stats = SessionStats(
          completedExposures: session.successfulExposures,
          failedExposures: session.failedExposures,
          totalIntegrationSecs: session.totalIntegrationSecs,
          avgHfr: session.avgHfr,
          avgGuidingRms: session.avgGuidingRms,
          autofocusCount: session.autofocusCount,
          lastUpdated: session.startTime, // Use start time as fallback
        );

        recoveryInfoList.add(
          SessionRecoveryInfo(
            sessionId: session.id,
            sessionName: session.name,
            targetId: session.targetId,
            startTime: session.startTime,
            stats: stats,
          ),
        );
      }

      return recoveryInfoList;
    } catch (e, stackTrace) {
      _logger.error(
        'Error finding incomplete sessions: $e\n$stackTrace',
        source: 'SessionService',
      );
      // A failed recovery scan is not equivalent to "no interrupted
      // sessions". Propagate the failure so startup can warn the operator and
      // offer a retry instead of silently moving on to Quick Start.
      rethrow;
    }
  }

  /// Resume an interrupted session
  Future<void> recoverSession(int sessionId) async {
    if (_currentSessionId != null) {
      throw Exception('Cannot recover session while another session is active');
    }

    _logger.info('Recovering session $sessionId...', source: 'SessionService');

    // Verify the session exists and is one a process left unfinished.
    final session = await _records.getSessionById(sessionId);
    if (session == null) {
      throw Exception('Session $sessionId not found');
    }

    if (session.status != kInterruptedSessionStatus) {
      throw Exception(
        'Session $sessionId was not left interrupted, so there is nothing to '
        'resume (status: ${session.status})',
      );
    }

    // Re-open the row BEFORE taking ownership of it. The sweep stamped it
    // `interrupted` with an `end_time` at its last frame; a session that is
    // about to take frames again must not keep saying it ended.
    await _records.reopenSession(sessionId);

    // Restore session state
    _sessionGeneration++;
    _currentSessionId = sessionId;
    _currentStats = SessionStats(
      completedExposures: session.successfulExposures,
      failedExposures: session.failedExposures,
      totalIntegrationSecs: session.totalIntegrationSecs,
      avgHfr: session.avgHfr,
      avgGuidingRms: session.avgGuidingRms,
      autofocusCount: session.autofocusCount,
      lastUpdated: _now(),
    );

    // Start checkpoint timer
    if (_config.enabled) {
      _startCheckpointTimer();
    }

    _emitStatus('Session recovered: $sessionId');
    _logger.info(
      'Session $sessionId recovered successfully',
      source: 'SessionService',
    );
    _logger.debug(
      '  Exposures completed: ${session.successfulExposures}',
      source: 'SessionService',
    );
    _logger.debug(
      '  Integration time: ${session.totalIntegrationSecs}s',
      source: 'SessionService',
    );
  }

  /// Mark a session as aborted (for recovery dialog when user chooses not to resume)
  Future<void> markSessionAborted(int sessionId) async {
    _logger.info(
      'Marking session $sessionId as aborted',
      source: 'SessionService',
    );
    await _records.abortSession(sessionId);
  }

  /// Update checkpoint configuration
  void updateConfig(SessionCheckpointConfig config) {
    final wasEnabled = _config.enabled;
    final previousInterval = _config.checkpointTimeInterval;
    _config = config;

    if (_config.enabled && !wasEnabled && _currentSessionId != null) {
      // Checkpointing was just enabled, start timer
      _startCheckpointTimer();
    } else if (!_config.enabled && wasEnabled) {
      // Checkpointing was just disabled, stop timer
      _stopCheckpointTimer();
    } else if (_config.enabled &&
        _config.checkpointTimeInterval != previousInterval) {
      // Interval changed, restart timer
      _stopCheckpointTimer();
      _startCheckpointTimer();
    }

    _logger.debug('Configuration updated', source: 'SessionService');
  }

  /// Get current configuration
  SessionCheckpointConfig get config => _config;

  // Private helper methods

  void _startCheckpointTimer() {
    _stopCheckpointTimer(); // Ensure no duplicate timers
    _checkpointTimer = Timer.periodic(_config.checkpointTimeInterval, (_) {
      if (_currentSessionId != null && _currentStats != null) {
        unawaited(_performCheckpoint());
      }
    });
    _logger.debug(
      'Checkpoint timer started (interval: ${_config.checkpointTimeInterval.inMinutes} min)',
      source: 'SessionService',
    );
  }

  void _stopCheckpointTimer() {
    _checkpointTimer?.cancel();
    _checkpointTimer = null;
  }

  Future<void> _performCheckpoint() {
    if (_disposed || _currentSessionId == null || _currentStats == null) {
      return Future<void>.value();
    }

    // Coalesce every trigger that arrives during a slow write into one
    // follow-up pass. This keeps the database single-writer while ensuring an
    // end-session request waits for a fresh snapshot rather than merely
    // waiting for an older checkpoint that happened to be in flight.
    _checkpointRequested = true;
    final active = _checkpointDrain;
    if (active != null) return active;

    late final Future<void> operation;
    operation = _drainCheckpointRequests().whenComplete(() {
      if (identical(_checkpointDrain, operation)) {
        _checkpointDrain = null;
      }
    });
    _checkpointDrain = operation;
    return operation;
  }

  Future<void> _drainCheckpointRequests() async {
    while (_checkpointRequested && !_disposed) {
      _checkpointRequested = false;
      final sessionId = _currentSessionId;
      final stats = _currentStats;
      final generation = _sessionGeneration;
      if (sessionId == null || stats == null) return;

      _logger.debug(
        'Performing checkpoint for session $sessionId...',
        source: 'SessionService',
      );

      try {
        await _records.updateSessionStats(
          sessionId,
          totalExposures: stats.completedExposures + stats.failedExposures,
          successfulExposures: stats.completedExposures,
          failedExposures: stats.failedExposures,
          totalIntegrationSecs: stats.totalIntegrationSecs,
          avgHfr: stats.avgHfr,
          avgGuidingRms: stats.avgGuidingRms,
          autofocusCount: stats.autofocusCount,
        );

        if (_disposed ||
            generation != _sessionGeneration ||
            _currentSessionId != sessionId) {
          continue;
        }

        _emitStatus('Checkpoint saved');
        _logger.debug(
          'Checkpoint saved successfully',
          source: 'SessionService',
        );
      } catch (e) {
        _logger.error(
          'Error performing checkpoint: $e',
          source: 'SessionService',
        );
        if (!_disposed &&
            generation == _sessionGeneration &&
            _currentSessionId == sessionId) {
          _emitStatus('Checkpoint failed: $e');
        }
      }
    }
  }

  void _emitStatus(String message) {
    if (!_disposed && !_statusController.isClosed) {
      _statusController.add(message);
    }
  }

  /// Dispose of resources
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _sessionGeneration++;
    _checkpointRequested = false;
    _stopCheckpointTimer();
    _statusController.close();
    _logger.debug('Disposed', source: 'SessionService');
  }
}
