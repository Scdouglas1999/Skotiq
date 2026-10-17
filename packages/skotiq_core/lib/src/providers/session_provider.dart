import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:equatable/equatable.dart';

import 'clock_provider.dart';
import 'database_provider.dart';
import 'equipment/camera_state_provider.dart';
import 'equipment/filter_wheel_state_provider.dart';
import 'equipment/focuser_state_provider.dart';
import 'imaging_provider.dart' show exposureSettingsProvider;
import '../services/imaging_records_repository.dart';
import '../services/quick_start_service.dart' show quickStartServiceProvider;
import '../services/session_service.dart';
import '../services/logging_service.dart';
import '../database/daos/sequence_checkpoints_dao.dart';

// Session state model

/// Current imaging session state
/// Tracks the active imaging session with all relevant details
class SessionState extends Equatable {
  /// Whether a session is currently active
  final bool isActive;

  /// Session start time (Unix timestamp ms)
  final DateTime? startTime;

  /// Current target being imaged
  final String? targetName;
  final double? targetRa;
  final double? targetDec;

  /// Exposure tracking
  final int totalExposures;
  final int completedExposures;
  final int failedExposures;

  /// Frames that captured successfully but were rejected by quality grading.
  /// These are NOT failures (the exposure completed) and they do NOT count
  /// toward [totalIntegrationSecs] — rejected sky time is wasted, not progress.
  final int rejectedExposures;

  /// Accepted integration time. Only frames that passed quality grading
  /// (or were recorded without a reject signal) contribute here, so the
  /// multi-night project integration budget never counts auto-rejected
  /// subs as completed sky time.
  final double totalIntegrationSecs;

  /// Current state flags
  final String? currentFilter;
  final bool isGuiding;
  final bool isCapturing;
  final bool isDithering;
  final bool isAutofocusing;

  /// Session quality metrics (running averages)
  final double? avgHfr;
  final double? avgGuidingRmsRa;
  final double? avgGuidingRmsDec;

  /// Database session ID (for persisting statistics)
  final int? dbSessionId;

  const SessionState({
    this.isActive = false,
    this.startTime,
    this.targetName,
    this.targetRa,
    this.targetDec,
    this.totalExposures = 0,
    this.completedExposures = 0,
    this.failedExposures = 0,
    this.rejectedExposures = 0,
    this.totalIntegrationSecs = 0.0,
    this.currentFilter,
    this.isGuiding = false,
    this.isCapturing = false,
    this.isDithering = false,
    this.isAutofocusing = false,
    this.avgHfr,
    this.avgGuidingRmsRa,
    this.avgGuidingRmsDec,
    this.dbSessionId,
  });

  SessionState copyWith({
    bool? isActive,
    DateTime? startTime,
    String? targetName,
    double? targetRa,
    double? targetDec,
    int? totalExposures,
    int? completedExposures,
    int? failedExposures,
    int? rejectedExposures,
    double? totalIntegrationSecs,
    String? currentFilter,
    bool? isGuiding,
    bool? isCapturing,
    bool? isDithering,
    bool? isAutofocusing,
    double? avgHfr,
    double? avgGuidingRmsRa,
    double? avgGuidingRmsDec,
    int? dbSessionId,
  }) {
    return SessionState(
      isActive: isActive ?? this.isActive,
      startTime: startTime ?? this.startTime,
      targetName: targetName ?? this.targetName,
      targetRa: targetRa ?? this.targetRa,
      targetDec: targetDec ?? this.targetDec,
      totalExposures: totalExposures ?? this.totalExposures,
      completedExposures: completedExposures ?? this.completedExposures,
      failedExposures: failedExposures ?? this.failedExposures,
      rejectedExposures: rejectedExposures ?? this.rejectedExposures,
      totalIntegrationSecs: totalIntegrationSecs ?? this.totalIntegrationSecs,
      currentFilter: currentFilter ?? this.currentFilter,
      isGuiding: isGuiding ?? this.isGuiding,
      isCapturing: isCapturing ?? this.isCapturing,
      isDithering: isDithering ?? this.isDithering,
      isAutofocusing: isAutofocusing ?? this.isAutofocusing,
      avgHfr: avgHfr ?? this.avgHfr,
      avgGuidingRmsRa: avgGuidingRmsRa ?? this.avgGuidingRmsRa,
      avgGuidingRmsDec: avgGuidingRmsDec ?? this.avgGuidingRmsDec,
      dbSessionId: dbSessionId ?? this.dbSessionId,
    );
  }

  /// Session duration
  Duration? get duration {
    if (startTime == null) return null;
    return DateTime.now().difference(startTime!);
  }

  /// Calculate success rate
  double get successRate {
    if (completedExposures + failedExposures == 0) return 1.0;
    return completedExposures / (completedExposures + failedExposures);
  }

  @override
  List<Object?> get props => [
    isActive,
    startTime,
    targetName,
    targetRa,
    targetDec,
    totalExposures,
    completedExposures,
    failedExposures,
    rejectedExposures,
    totalIntegrationSecs,
    currentFilter,
    isGuiding,
    isCapturing,
    isDithering,
    isAutofocusing,
    avgHfr,
    avgGuidingRmsRa,
    avgGuidingRmsDec,
    dbSessionId,
  ];
}

// Session state notifier

/// Notifier for managing session state
class SessionStateNotifier extends StateNotifier<SessionState> {
  final Ref _ref;
  int _autofocusCount = 0;

  SessionStateNotifier(this._ref) : super(const SessionState());

  /// Start a new imaging session.
  ///
  /// [profileId] and [sequenceId] are persisted on the imaging_sessions row.
  Future<void> startSession({
    String? targetName,
    double? targetRa,
    double? targetDec,
    int? targetId,
    int? profileId,
    int? sequenceId,
  }) async {
    // Use SessionService to create and manage the session
    final sessionService = _ref.read(sessionServiceProvider);
    final dbId = await sessionService.startSession(
      name: targetName,
      targetId: targetId,
      profileId: profileId,
      sequenceId: sequenceId,
    );
    if (dbId <= 0) {
      throw StateError('SessionService returned invalid session id: $dbId');
    }

    await _recordEquipmentSnapshot(dbId);

    _autofocusCount = 0;

    state = SessionState(
      isActive: true,
      startTime: DateTime.now(),
      targetName: targetName,
      targetRa: targetRa,
      targetDec: targetDec,
      dbSessionId: dbId,
    );
  }

  /// Stamp the equipment this session is starting with onto its
  /// `imaging_sessions` row.
  ///
  /// `equipment_snapshot` is what the Continue Session dialog's "Load Previous
  /// Setup" re-applies (read by [QuickStartService._buildQuickStartContext],
  /// restored by `QuickStartChecker`): a NULL column silently restores no
  /// cooler setpoint, no gain/offset and no filter or focuser position.
  ///
  /// Taken at start rather than at end: a night that ends in a crash is
  /// precisely the night the handoff dialog exists for, and an end-of-session
  /// snapshot would be read off equipment that may already be disconnected.
  ///
  /// Snapshot persistence is non-fatal: a session that really did start must
  /// not fail because its restore metadata could not be stored.
  Future<void> _recordEquipmentSnapshot(int sessionId) async {
    try {
      final exposure = _ref.read(exposureSettingsProvider);
      final live = _ref
          .read(quickStartServiceProvider)
          .captureEquipmentSnapshot(
            cameraState: _ref.read(cameraStateProvider),
            filterWheelState: _ref.read(filterWheelStateProvider),
            focuserState: _ref.read(focuserStateProvider),
            exposureTime: exposure.exposureTime,
          );
      // What the camera reports wins; the configured capture settings fill in
      // for a driver that does not read gain/offset/binning back (many do not),
      // because those are still the values this session is exposing with.
      final snapshot = live.copyWith(
        cameraGain: live.cameraGain ?? exposure.gain,
        cameraOffset: live.cameraOffset ?? exposure.offset,
        cameraBinX: live.cameraBinX ?? exposure.binningX,
        cameraBinY: live.cameraBinY ?? exposure.binningY,
      );
      await _ref
          .read(imagingRecordsRepositoryProvider)
          .updateEquipmentSnapshot(sessionId, snapshot.toJsonString());
    } catch (e) {
      _ref
          .read(loggingServiceProvider)
          .warning(
            'Could not record the equipment snapshot for session $sessionId: '
            '$e — Continue Session will not be able to restore its camera '
            'settings',
            source: 'SessionState',
          );
    }
  }

  /// End the current session
  Future<void> endSession({String status = 'completed'}) async {
    if (!state.isActive || state.dbSessionId == null) return;

    // Use SessionService to finalize the session with latest stats
    final sessionService = _ref.read(sessionServiceProvider);

    // Update session service with final statistics before ending
    await _updateSessionServiceStats();

    await sessionService.endSession(status: status);

    _autofocusCount = 0;
    state = const SessionState();
  }

  /// Abort the current session
  Future<void> abortSession() async {
    await endSession(status: 'aborted');
  }

  /// Recover a previously interrupted session
  Future<void> recoverSession(SessionRecoveryInfo recoveryInfo) async {
    if (recoveryInfo.sessionId <= 0) {
      throw StateError(
        'Cannot recover session with invalid id ${recoveryInfo.sessionId}',
      );
    }
    final sessionService = _ref.read(sessionServiceProvider);
    await sessionService.recoverSession(recoveryInfo.sessionId);

    state = SessionState(
      isActive: true,
      startTime: recoveryInfo.startTime,
      targetName: recoveryInfo.targetName,
      dbSessionId: recoveryInfo.sessionId,
      completedExposures: recoveryInfo.stats.completedExposures,
      failedExposures: recoveryInfo.stats.failedExposures,
      totalIntegrationSecs: recoveryInfo.stats.totalIntegrationSecs,
      avgHfr: recoveryInfo.stats.avgHfr,
      avgGuidingRmsDec: recoveryInfo.stats.avgGuidingRms,
    );

    _autofocusCount = recoveryInfo.stats.autofocusCount;
  }

  /// Set the current target
  void setTarget({required String name, double? ra, double? dec}) {
    state = state.copyWith(targetName: name, targetRa: ra, targetDec: dec);
  }

  /// Record a completed exposure.
  ///
  /// [accepted] reflects whether the frame passed quality grading. An accepted
  /// frame advances the integration budget ([totalIntegrationSecs]) that the
  /// multi-night project tracker sums; a rejected frame does NOT — its sky
  /// time is wasted, not progress, so it is tallied in [rejectedExposures]
  /// instead. The exposure still completed either way, so [completedExposures]
  /// increments in both cases (the capture itself succeeded).
  ///
  /// HFR is averaged only over accepted frames so the session's quality
  /// metric is not skewed by subs we have already thrown away. That rule is
  /// the app-wide definition of `avgHfr`, not a local choice: [SessionState.avgHfr] is
  /// checkpointed onto `imaging_sessions.avg_hfr`, and `/api/sessions`,
  /// `/api/sessions/<id>`, `/api/sessions/<id>/stats` and the session export
  /// all ship that one column. A night whose every light was rejected has no
  /// accepted sample, so `avgHfr` is null everywhere — the endpoint that used
  /// to recompute its own mean over the rejected rows made that one night
  /// report null on three surfaces and 2.46 on the fourth. The all-lights mean
  /// is a different question and travels under its own name
  /// (`avgHfrAllLights`).
  void recordExposureComplete({
    required double exposureTime,
    double? hfr,
    bool accepted = true,
  }) {
    if (!accepted) {
      // Wasted sky time: count the capture, but keep it out of the integration
      // budget and out of the running HFR average.
      state = state.copyWith(
        completedExposures: state.completedExposures + 1,
        rejectedExposures: state.rejectedExposures + 1,
      );
      _updateSessionServiceStats();
      return;
    }

    // Update running average HFR over accepted frames only.
    double? newAvgHfr = state.avgHfr;
    if (hfr != null) {
      if (state.avgHfr == null) {
        newAvgHfr = hfr;
      } else {
        // Simple running average over the accepted frames seen so far.
        final count = state.completedExposures - state.rejectedExposures;
        newAvgHfr = (state.avgHfr! * count + hfr) / (count + 1);
      }
    }

    state = state.copyWith(
      completedExposures: state.completedExposures + 1,
      totalIntegrationSecs: state.totalIntegrationSecs + exposureTime,
      avgHfr: newAvgHfr,
    );

    // Update session service (triggers checkpoint if needed)
    _updateSessionServiceStats();
  }

  /// Record a failed exposure
  void recordExposureFailed() {
    state = state.copyWith(failedExposures: state.failedExposures + 1);

    // Update session service (triggers checkpoint if needed)
    _updateSessionServiceStats();
  }

  /// Increment autofocus count
  void incrementAutofocusCount() {
    _autofocusCount++;
    _updateSessionServiceStats();
  }

  /// Update target coordinates when the sequencer switches targets mid-sequence
  void updateTargetCoordinates({required double ra, required double dec}) {
    state = state.copyWith(targetRa: ra, targetDec: dec);
  }

  /// Update the expected total exposures
  void setTotalExposures(int total) {
    state = state.copyWith(totalExposures: total);
  }

  /// Set capturing state
  void setCapturing(bool isCapturing) {
    state = state.copyWith(isCapturing: isCapturing);
  }

  /// Set guiding state with optional RMS values
  void setGuiding(bool isGuiding, {double? rmsRa, double? rmsDec}) {
    state = state.copyWith(
      isGuiding: isGuiding,
      avgGuidingRmsRa: rmsRa ?? state.avgGuidingRmsRa,
      avgGuidingRmsDec: rmsDec ?? state.avgGuidingRmsDec,
    );
  }

  /// Set dithering state
  void setDithering(bool isDithering) {
    state = state.copyWith(isDithering: isDithering);
  }

  /// Set autofocusing state
  void setAutofocusing(bool isAutofocusing) {
    state = state.copyWith(isAutofocusing: isAutofocusing);
  }

  /// Set current filter
  void setFilter(String? filter) {
    state = state.copyWith(currentFilter: filter);
  }

  /// Update guiding RMS values
  void updateGuidingRms(double rmsRa, double rmsDec) {
    state = state.copyWith(avgGuidingRmsRa: rmsRa, avgGuidingRmsDec: rmsDec);
  }

  /// Helper to update session service with current stats
  Future<void> _updateSessionServiceStats() async {
    final snapshot = state;
    if (!snapshot.isActive || snapshot.dbSessionId == null) return;

    final sessionService = _ref.read(sessionServiceProvider);

    // Calculate combined guiding RMS (RMS of both axes)
    double? combinedGuidingRms;
    if (snapshot.avgGuidingRmsRa != null && snapshot.avgGuidingRmsDec != null) {
      combinedGuidingRms = math.sqrt(
        snapshot.avgGuidingRmsRa! * snapshot.avgGuidingRmsRa! +
            snapshot.avgGuidingRmsDec! * snapshot.avgGuidingRmsDec!,
      );
    }

    final stats = SessionStats(
      completedExposures: snapshot.completedExposures,
      failedExposures: snapshot.failedExposures,
      totalIntegrationSecs: snapshot.totalIntegrationSecs,
      avgHfr: snapshot.avgHfr,
      avgGuidingRms: combinedGuidingRms,
      autofocusCount: _autofocusCount,
      lastUpdated: DateTime.now(),
    );

    await sessionService.updateSessionProgress(stats);
  }
}

// Providers

/// DAO provider for sequence checkpoints (optional, for sequence integration)
final sequenceCheckpointsDaoProvider = Provider<SequenceCheckpointsDao>((ref) {
  return SequenceCheckpointsDao(ref.watch(databaseProvider));
});

/// SessionService provider
final sessionServiceProvider = Provider<SessionService>((ref) {
  // Why: inject the active clock so session-start/end timestamps stamped
  // by SessionService honor the user's TZ override
  final clock = ref.watch(clockProvider);
  final service = SessionService(
    records: ref.watch(imagingRecordsRepositoryProvider),
    checkpointsDao: ref.watch(sequenceCheckpointsDaoProvider),
    logger: ref.watch(loggingServiceProvider),
    nowProvider: clock.now,
  );

  ref.onDispose(() => service.dispose());

  return service;
});

/// Session state provider for tracking active imaging sessions
final sessionStateProvider =
    StateNotifierProvider<SessionStateNotifier, SessionState>((ref) {
      return SessionStateNotifier(ref);
    });

/// Provider for session progress (0.0 - 1.0)
final sessionProgressProvider = Provider<double>((ref) {
  final session = ref.watch(sessionStateProvider);
  if (session.totalExposures == 0) return 0.0;
  return session.completedExposures / session.totalExposures;
});

/// Provider for session duration as a formatted string
final sessionDurationProvider = Provider<String>((ref) {
  final session = ref.watch(sessionStateProvider);
  final duration = session.duration;
  if (duration == null) return '--:--:--';

  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);

  return '${hours.toString().padLeft(2, '0')}:'
      '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
});

/// Provider for incomplete sessions that can be recovered
final incompleteSessionsProvider = FutureProvider<List<SessionRecoveryInfo>>((
  ref,
) async {
  final sessionService = ref.watch(sessionServiceProvider);
  return await sessionService.findIncompleteSessionsForRecovery();
});
