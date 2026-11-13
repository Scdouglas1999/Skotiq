import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Variable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart' as db;
import '../models/sequence/sequence_run_status.dart';
import '../database/daos/equipment_profiles_dao.dart';
import '../database/daos/sequence_checkpoints_dao.dart';
import '../database/daos/sequences_dao.dart';
import '../database/daos/sessions_dao.dart';
import '../database/daos/targets_dao.dart';
import '../backend/skotiq_backend.dart';
import '../models/equipment/equipment_models.dart';
import '../providers/backend_provider.dart';
import '../providers/database_provider.dart';
import '../providers/profiles_provider.dart';
import '../providers/session_provider.dart' show sequenceCheckpointsDaoProvider;
import '../utils/json_validation.dart';
import '../models/backend/backend_types.dart';
import 'logging_service.dart';
part 'quick_start_service/quick_start_models.dart';
part 'quick_start_service/quick_start_providers.dart';

/// Service for capturing and restoring session state for quick resumption.
///
/// This service provides functionality to:
/// - Capture current equipment state as a snapshot
/// - Save snapshots to session records
/// - Retrieve quick start context from recent sessions
/// - Determine if quick start is available
class QuickStartService {
  final SessionsDao sessionsDao;
  final EquipmentProfilesDao profilesDao;
  final TargetsDao targetsDao;
  final SequencesDao sequencesDao;
  final SequenceCheckpointsDao checkpointsDao;
  final Future<String?> Function(int profileId)? resolveProfileName;

  QuickStartService({
    required this.sessionsDao,
    required this.profilesDao,
    required this.targetsDao,
    required this.sequencesDao,
    required this.checkpointsDao,
    this.resolveProfileName,
  });

  Future<String?> _profileNameForSession(int? profileId) async {
    if (profileId == null) {
      return null;
    }
    if (resolveProfileName != null) {
      return resolveProfileName!(profileId);
    }
    final profile = await profilesDao.getProfileById(profileId);
    return profile?.name;
  }

  /// The Continue Session prompt's context: the newest run, when it can be
  /// continued (see [continueSessionCandidate]); null otherwise.
  Future<QuickStartContext?> getQuickStartContext() async {
    final session = continueSessionCandidate(
      await sessionsDao.getRecentSessions(limit: 10),
      now: DateTime.now(),
    );
    if (session == null) {
      Log.info(
        'QuickStartService: the newest run is not one to continue',
        source: 'QuickStartService',
      );
      return null;
    }
    Log.info(
      'QuickStartService: offering session ${session.id} '
      '(${session.status}) from ${session.startTime}',
      source: 'QuickStartService',
    );
    return _buildQuickStartContext(session);
  }

  Future<QuickStartContext> _buildQuickStartContext(
    db.ImagingSession session,
  ) async {
    // Try to get extended session data (sequenceId, equipmentSnapshot) from raw SQL
    // since these fields may not be in the generated model yet
    final extendedData = await _getExtendedSessionData(session.id);
    final sequenceId = extendedData['sequenceId'] as int?;
    final equipmentSnapshotJson = extendedData['equipmentSnapshot'] as String?;

    final profileNameFuture = _profileNameForSession(session.profileId);

    final targetFuture = session.targetId != null
        ? targetsDao.getTargetById(session.targetId!)
        : Future<db.DbTarget?>.value(null);

    final sequenceFuture = sequenceId != null
        ? sequencesDao.getSequenceById(sequenceId)
        : Future<db.DbSequence?>.value(null);

    final checkpointFuture = sequenceId != null
        ? checkpointsDao.getCheckpoint(sequenceId)
        : Future<db.SequenceCheckpoint?>.value(null);

    // Wait for all futures to complete
    final results = await Future.wait<Object?>([
      profileNameFuture,
      targetFuture,
      sequenceFuture,
      checkpointFuture,
    ]);

    final profileName = results[0] as String?;
    final target = results[1] as db.DbTarget?;
    final sequence = results[2] as db.DbSequence?;
    final checkpoint = results[3] as db.SequenceCheckpoint?;

    EquipmentSnapshot? equipmentSnapshot;
    if (equipmentSnapshotJson != null && equipmentSnapshotJson.isNotEmpty) {
      try {
        equipmentSnapshot = EquipmentSnapshot.fromJsonString(
          equipmentSnapshotJson,
        );
      } catch (e) {
        Log.warning(
          'QuickStartService: Failed to parse equipment snapshot: $e',
          source: 'QuickStartService',
          error: e,
        );
      }
    }

    // The frames this session took. The stored checkpoint is the sequence's
    // and can belong to an earlier run of it, so it only supplies the plan's
    // total. The session's own exposure count is frames taken, not planned:
    // as a total it made every run read as finished.
    final completedFrames = session.successfulExposures;
    final plannedFrames = checkpoint == null ? 0 : checkpoint.totalFrames;
    final totalFrames = plannedFrames >= completedFrames ? plannedFrames : 0;

    final totalIntegrationHours = session.totalIntegrationSecs / 3600.0;

    return QuickStartContext(
      sessionId: session.id,
      sessionName: session.name,
      profileId: session.profileId,
      profileName: profileName,
      targetId: session.targetId,
      targetName: target?.name,
      targetRa: target?.ra,
      targetDec: target?.dec,
      sequenceId: sequenceId,
      sequenceName: sequence?.name,
      completedFrames: completedFrames,
      totalFrames: totalFrames,
      lastSessionDate: session.endTime ?? session.startTime,
      equipmentSnapshot: equipmentSnapshot,
      totalIntegrationHours: totalIntegrationHours,
      stoppedByOperator: isOperatorStoppedSessionStatus(session.status),
    );
  }

  /// Get extended session data that may not be in the generated model yet.
  /// Returns a map with 'sequenceId' and 'equipmentSnapshot' if available.
  Future<Map<String, dynamic>> _getExtendedSessionData(int sessionId) async {
    try {
      final database = sessionsDao.attachedDatabase;
      // Try to select the extended columns - they may not exist yet
      final result = await database
          .customSelect(
            'SELECT sequence_id, equipment_snapshot FROM imaging_sessions WHERE id = ?',
            variables: [Variable<int>(sessionId)],
          )
          .getSingleOrNull();

      if (result == null) {
        return {};
      }

      return {
        'sequenceId': result.data['sequence_id'] as int?,
        'equipmentSnapshot': result.data['equipment_snapshot'] as String?,
      };
    } catch (e) {
      // Columns may not exist yet - this is fine, return empty
      Log.warning(
        'QuickStartService: Extended columns not available: $e',
        source: 'QuickStartService',
        error: e,
      );
      return {};
    }
  }

  /// Capture current equipment state as a snapshot.
  ///
  /// This method extracts relevant settings from the current device states
  /// and creates an EquipmentSnapshot that can be saved with a session.
  EquipmentSnapshot captureEquipmentSnapshot({
    required CameraStateSnapshot cameraState,
    required FilterWheelState filterWheelState,
    required FocuserState focuserState,
    double? exposureTime,
  }) {
    // Parse binning from camera state (format: "NxM" or just "N")
    int? binX;
    int? binY;
    if (cameraState.binning != null && cameraState.binning!.isNotEmpty) {
      final binningParts = cameraState.binning!.split('x');
      if (binningParts.length == 2) {
        binX = int.tryParse(binningParts[0]);
        binY = int.tryParse(binningParts[1]);
      } else if (binningParts.length == 1) {
        // Assume symmetric binning if only one value
        final bin = int.tryParse(binningParts[0]);
        binX = bin;
        binY = bin;
      }
    }

    return EquipmentSnapshot(
      // The set-point is only a setting in use while the cooler runs; a run
      // at ambient has no temperature to restore.
      coolerTargetTemp: cameraState.isCooling ? cameraState.targetTemp : null,
      cameraGain: cameraState.gain,
      cameraOffset: cameraState.offset,
      cameraBinX: binX,
      cameraBinY: binY,
      filterPosition: filterWheelState.currentPosition,
      filterName: filterWheelState.currentFilterName,
      focuserPosition: focuserState.position,
      exposureTime: exposureTime,
      capturedAt: DateTime.now(),
    );
  }

  /// Save an equipment snapshot to a session record.
  ///
  /// The snapshot is serialized to JSON and stored in the session's
  /// equipmentSnapshot field.
  Future<void> saveEquipmentSnapshot(
    int sessionId,
    EquipmentSnapshot snapshot,
  ) async {
    Log.info(
      'QuickStartService: Saving equipment snapshot for session $sessionId',
      source: 'QuickStartService',
    );

    try {
      final session = await sessionsDao.getSessionById(sessionId);
      if (session == null) {
        throw Exception('Session $sessionId not found');
      }

      final snapshotJson = snapshot.toJsonString();
      await sessionsDao.updateEquipmentSnapshot(sessionId, snapshotJson);
    } catch (e, stackTrace) {
      Log.error(
        'QuickStartService: Error saving equipment snapshot: $e',
        source: 'QuickStartService',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Whether the Continue Session prompt has a run to offer.
  Future<bool> isQuickStartAvailable() async =>
      continueSessionCandidate(
        await sessionsDao.getRecentSessions(limit: 10),
        now: DateTime.now(),
      ) !=
      null;

  /// Get multiple quick start contexts for displaying a list of resumable sessions.
  ///
  /// Returns up to [limit] sessions that are suitable for quick start,
  /// ordered by recency.
  Future<List<QuickStartContext>> getQuickStartContexts({int limit = 5}) async {
    Log.info(
      'QuickStartService: Getting quick start contexts (limit: $limit)...',
      source: 'QuickStartService',
    );
    final contexts = <QuickStartContext>[];

    // Get the sessions a previous process left unfinished first
    final interruptedSessions = await sessionsDao.getInterruptedSessions();
    for (final session in interruptedSessions) {
      if (contexts.length >= limit) break;
      contexts.add(await _buildQuickStartContext(session));
    }

    // If we need more, get recent completed sessions
    if (contexts.length < limit) {
      final recentSessions = await sessionsDao.getRecentSessions(
        limit: limit * 2, // Fetch extra to filter
      );

      for (final session in recentSessions) {
        if (contexts.length >= limit) break;

        // Skip if already included (from active sessions)
        if (contexts.any((c) => c.sessionId == session.id)) continue;

        // Skip if session is too old or has no progress
        final sessionAge = DateTime.now().difference(session.startTime);
        final hasProgress =
            session.successfulExposures > 0 || session.totalIntegrationSecs > 0;

        if (session.status == 'completed' &&
            sessionAge.inDays <= 7 &&
            hasProgress) {
          contexts.add(await _buildQuickStartContext(session));
        }
      }
    }

    Log.info(
      'QuickStartService: Found ${contexts.length} quick start contexts',
      source: 'QuickStartService',
    );
    return contexts;
  }
}

/// Whether a session with this status can be continued: one the app died
/// under, or one the operator stopped keeping its resume point.
bool isContinuableSessionStatus(String status) =>
    switch (SequenceRunStatus.tryParse(status)) {
      SequenceRunStatus.interrupted ||
      SequenceRunStatus.stoppedResumable => true,
      _ => false,
    };

/// Whether a session with this status was stopped by the operator with its
/// resume point kept.
bool isOperatorStoppedSessionStatus(String status) =>
    SequenceRunStatus.tryParse(status) == SequenceRunStatus.stoppedResumable;

/// How long a run stays on offer after it ended.
const Duration kContinueSessionMaxAge = Duration(days: 7);

/// How long a run that captured nothing stays on offer: the night it ran.
const Duration kContinueEmptySessionMaxAge = Duration(hours: 18);

/// The run the Continue Session prompt offers, from [sessionsNewestFirst].
///
/// Only the newest run: a later run supersedes every earlier one, so an
/// interrupted test run from days ago is never offered over last night's,
/// and nothing is offered while a run is in progress. It is offered when it can be continued (interrupted, or stopped
/// with its resume point kept) and ended within [kContinueSessionMaxAge]
/// ([kContinueEmptySessionMaxAge] when it captured nothing); a run that
/// finished or whose resume point was discarded is not. The rig offered "Rig test NGC 7331 · 5 days ago · No
/// progress yet" over the run stopped with its checkpoint the night before.
db.ImagingSession? continueSessionCandidate(
  List<db.ImagingSession> sessionsNewestFirst, {
  required DateTime now,
}) {
  db.ImagingSession? latest;
  for (final session in sessionsNewestFirst) {
    if (latest == null || session.startTime.isAfter(latest.startTime)) {
      latest = session;
    }
  }
  // A run in progress supersedes every earlier one, and is not a run to
  // continue.
  if (latest == null || latest.status == 'active') return null;
  if (!isContinuableSessionStatus(latest.status)) return null;
  final endedAt = latest.endTime ?? latest.startTime;
  if (now.difference(endedAt) > kContinueSessionMaxAge) return null;
  // A run that captured nothing has only its setup to offer, which is worth
  // it the same night and stale after that.
  final captured =
      latest.successfulExposures > 0 || latest.totalIntegrationSecs > 0;
  if (!captured && now.difference(endedAt) > kContinueEmptySessionMaxAge) {
    return null;
  }
  return latest;
}
