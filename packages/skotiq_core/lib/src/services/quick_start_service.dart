import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:drift/drift.dart' show Variable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart' as db;
import '../database/daos/equipment_profiles_dao.dart';
import '../database/daos/sequence_checkpoints_dao.dart';
import '../database/daos/sequences_dao.dart';
import '../database/daos/sessions_dao.dart';
import '../database/daos/targets_dao.dart';
import '../backend/skotiq_backend.dart';
import '../models/equipment/equipment_models.dart';
import '../backend/network_backend.dart';
import '../providers/backend_provider.dart';
import '../providers/database_provider.dart';
import '../providers/profiles_provider.dart';
import '../providers/session_provider.dart' show sequenceCheckpointsDaoProvider;
import '../utils/json_validation.dart';
part 'quick_start_service/quick_start_models.dart';
part 'quick_start_service/quick_start_providers.dart';

// QuickStartService - Service for quick session resumption

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

  /// Get the quick start context from the most recent recoverable session.
  ///
  /// This method retrieves the most recent session that has:
  /// - A status of 'interrupted', or 'completed' within 7 days
  /// - Preference given to interrupted sessions with progress
  ///
  /// Returns null if no suitable session is found.
  Future<QuickStartContext?> getQuickStartContext() async {
    developer.log(
      'QuickStartService: Getting quick start context...',
      name: 'QuickStartService',
      level: 800,
    );

    // First, check for sessions a previous process left unfinished — the case
    // this dialog exists for. Read from `interrupted` rather than `active`
    // since the boot sweep started closing abandoned rows: `active` now means
    // a run in progress, which is not something to hand off from.
    final interruptedSessions = await sessionsDao.getInterruptedSessions();
    if (interruptedSessions.isNotEmpty) {
      // Return the most recent interrupted session
      final session = interruptedSessions.first;
      developer.log(
        'QuickStartService: Found interrupted session ${session.id} from ${session.startTime}',
        name: 'QuickStartService',
        level: 800,
      );
      return _buildQuickStartContext(session);
    }

    // If no interrupted sessions, look for recent completed sessions
    final recentSessions = await sessionsDao.getRecentSessions(limit: 10);

    // Filter to sessions within the last 7 days that have meaningful progress
    final candidateSessions = recentSessions.where((session) {
      final sessionAge = DateTime.now().difference(session.startTime);
      final hasProgress =
          session.successfulExposures > 0 || session.totalIntegrationSecs > 0;
      return session.status == 'completed' &&
          sessionAge.inDays <= 7 &&
          hasProgress;
    }).toList();

    if (candidateSessions.isEmpty) {
      developer.log(
        'QuickStartService: No suitable sessions found for quick start',
        name: 'QuickStartService',
        level: 800,
      );
      return null;
    }

    // Return the most recent completed session with progress
    final session = candidateSessions.first;
    developer.log(
      'QuickStartService: Found recent session ${session.id} from ${session.startTime}',
      name: 'QuickStartService',
      level: 800,
    );
    return _buildQuickStartContext(session);
  }

  /// Build a QuickStartContext from a session record.
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
        : Future<db.Target?>.value(null);

    final sequenceFuture = sequenceId != null
        ? sequencesDao.getSequenceById(sequenceId)
        : Future<db.Sequence?>.value(null);

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
    final target = results[1] as db.Target?;
    final sequence = results[2] as db.Sequence?;
    final checkpoint = results[3] as db.SequenceCheckpoint?;

    // Parse equipment snapshot if available
    EquipmentSnapshot? equipmentSnapshot;
    if (equipmentSnapshotJson != null && equipmentSnapshotJson.isNotEmpty) {
      try {
        equipmentSnapshot = EquipmentSnapshot.fromJsonString(
          equipmentSnapshotJson,
        );
      } catch (e) {
        developer.log(
          'QuickStartService: Failed to parse equipment snapshot: $e',
          name: 'QuickStartService',
          level: 900,
          error: e,
        );
      }
    }

    // Get frame counts from checkpoint if available
    int completedFrames = 0;
    int totalFrames = 0;
    if (checkpoint != null) {
      completedFrames = checkpoint.completedFrames;
      totalFrames = checkpoint.totalFrames;
    } else {
      // Fall back to session stats
      completedFrames = session.successfulExposures;
      totalFrames = session.totalExposures;
    }

    // Calculate total integration in hours
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
      developer.log(
        'QuickStartService: Extended columns not available: $e',
        name: 'QuickStartService',
        level: 900,
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
      coolerTargetTemp: cameraState.targetTemp,
      cameraGain: cameraState.gain,
      cameraOffset: cameraState.offset,
      cameraBinX: binX,
      cameraBinY: binY,
      filterPosition: filterWheelState.currentPosition,
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
    developer.log(
      'QuickStartService: Saving equipment snapshot for session $sessionId',
      name: 'QuickStartService',
      level: 800,
    );

    try {
      final session = await sessionsDao.getSessionById(sessionId);
      if (session == null) {
        throw Exception('Session $sessionId not found');
      }

      final snapshotJson = snapshot.toJsonString();
      await sessionsDao.updateEquipmentSnapshot(sessionId, snapshotJson);
    } catch (e, stackTrace) {
      developer.log(
        'QuickStartService: Error saving equipment snapshot: $e',
        name: 'QuickStartService',
        level: 1000,
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  /// Check if quick start is available.
  ///
  /// Quick start is available if there's a recent session (within 7 days)
  /// that has meaningful progress, or a session left interrupted.
  Future<bool> isQuickStartAvailable() async {
    developer.log(
      'QuickStartService: Checking if quick start is available...',
      name: 'QuickStartService',
      level: 800,
    );

    // Check for sessions left unfinished first
    final hasInterrupted = await sessionsDao.hasIncompleteSessions();
    if (hasInterrupted) {
      developer.log(
        'QuickStartService: Quick start available (interrupted session found)',
        name: 'QuickStartService',
        level: 800,
      );
      return true;
    }

    // Check for recent completed sessions with progress
    final recentSessions = await sessionsDao.getRecentSessions(limit: 5);

    for (final session in recentSessions) {
      final sessionAge = DateTime.now().difference(session.startTime);
      final hasProgress =
          session.successfulExposures > 0 || session.totalIntegrationSecs > 0;

      if (session.status == 'completed' &&
          sessionAge.inDays <= 7 &&
          hasProgress) {
        developer.log(
          'QuickStartService: Quick start available (recent session with progress found)',
          name: 'QuickStartService',
          level: 800,
        );
        return true;
      }
    }

    developer.log(
      'QuickStartService: Quick start not available',
      name: 'QuickStartService',
      level: 800,
    );
    return false;
  }

  /// Get multiple quick start contexts for displaying a list of resumable sessions.
  ///
  /// Returns up to [limit] sessions that are suitable for quick start,
  /// ordered by recency.
  Future<List<QuickStartContext>> getQuickStartContexts({int limit = 5}) async {
    developer.log(
      'QuickStartService: Getting quick start contexts (limit: $limit)...',
      name: 'QuickStartService',
      level: 800,
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

    developer.log(
      'QuickStartService: Found ${contexts.length} quick start contexts',
      name: 'QuickStartService',
      level: 800,
    );
    return contexts;
  }
}
