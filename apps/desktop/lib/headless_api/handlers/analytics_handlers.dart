import 'package:drift/drift.dart' show Variable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// The grading verdict over one session's LIGHT frames.
///
/// Separate from `successfulExposures`/`failedExposures`, which count what the
/// CAMERA returned: a frame can expose and download perfectly and still be
/// rejected for trailing or cloud. A night whose every sub was rejected writes
/// exactly the same `12 / 12 / 0` exposure row as a night whose every sub was
/// kept, so those two columns cannot answer "did this night produce anything".
/// These two can, because they are read off the frames themselves.
class SessionGrading {
  const SessionGrading({required this.accepted, required this.rejected});

  /// A session with no light frames on record — not an assumption that the
  /// frames were good, which is the direction the old surfaces failed in.
  const SessionGrading.noFrames() : accepted = 0, rejected = 0;

  final int accepted;
  final int rejected;
}

/// What `avgHfr` measures, shipped beside every `avgHfr` this file emits.
///
/// One name for one rule: `imaging_sessions.avg_hfr` is the running mean over
/// the frames the grader ACCEPTED — see
/// `SessionStateNotifier.recordExposureComplete`, which owns that rule. A night
/// whose every light was rejected therefore has no accepted sample and honestly
/// reports `null` — on every endpoint, not on three of four.
const String _kAvgHfrBasis = 'accepted-frames';

/// Handlers for session management and analytics
class AnalyticsHandlers {
  final ProviderContainer container;

  /// Upper bound for the `/api/sessions/recent` `limit`. Imaging sessions
  /// accumulate slowly; 1000 is far more than any "recent" list shows and keeps
  /// a negative from becoming SQLite `LIMIT -1` (all rows).
  static const int _maxRecentSessionsLimit = 1000;

  /// Session ids bound into one grading read. Well under SQLite's own
  /// bound-variable ceiling, so the shape of the query never depends on how
  /// many nights the rig has recorded.
  static const int _idsPerGradingRead = 500;

  AnalyticsHandlers(this.container);

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'AnalyticsHandlers');

  // Why: URL path segments like `/api/sessions/{id}` would otherwise reach
  // `int.parse` and a malformed id (e.g. `/api/sessions/foo`) would surface
  // as FormatException → HTTP 500. Translate at the boundary into a 400.
  int _parsePathId(String raw, String field) {
    final parsed = int.tryParse(raw);
    if (parsed == null) {
      throw BadRequestError(field: field, expected: 'integer');
    }
    return parsed;
  }

  DateTime? _optionalDateQuery(Request request, String field) {
    final raw = request.url.queryParameters[field];
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw BadRequestError(
        field: field,
        expected: 'iso8601_datetime|epoch_milliseconds',
      );
    }

    // Accept epoch milliseconds from older companion builds while the current
    // client uses the documented ISO-8601 wire shape.
    final epochMilliseconds = int.tryParse(trimmed);
    if (epochMilliseconds != null) {
      try {
        return DateTime.fromMillisecondsSinceEpoch(
          epochMilliseconds,
          isUtc: true,
        );
      } on RangeError {
        throw BadRequestError(
          field: field,
          expected: 'iso8601_datetime|epoch_milliseconds',
        );
      }
    }

    final parsed = DateTime.tryParse(trimmed);
    if (parsed == null) {
      throw BadRequestError(
        field: field,
        expected: 'iso8601_datetime|epoch_milliseconds',
      );
    }
    return parsed;
  }

  Future<List<ImagingSession>> _sessionsInRequestedRange(
    Request request,
  ) async {
    final start = _optionalDateQuery(request, 'startDate');
    final end = _optionalDateQuery(request, 'endDate');
    if (start != null && end != null && start.isAfter(end)) {
      throw BadRequestError(
        field: 'startDate|endDate',
        expected: 'startDate <= endDate',
        message: 'The analytics start date must not be after the end date',
      );
    }

    final sessions = await container
        .read(databaseProvider)
        .sessionsDao
        .getAllSessions();
    if (start == null && end == null) return sessions;
    return sessions
        .where(
          (session) =>
              (start == null || !session.startTime.isBefore(start)) &&
              (end == null || !session.startTime.isAfter(end)),
        )
        .toList(growable: false);
  }

  Map<String, num> _statisticsForSessions(List<ImagingSession> sessions) {
    var exposures = 0;
    var integrationSeconds = 0.0;
    for (final session in sessions) {
      exposures += session.totalExposures;
      integrationSeconds += session.totalIntegrationSecs;
    }
    return {
      'totalSessions': sessions.length,
      'totalExposures': exposures,
      'totalIntegrationSecs': integrationSeconds,
      'totalIntegrationHours': integrationSeconds / 3600,
    };
  }

  // Get all sessions

  Future<Response> handleGetAllSessions(Request request) async {
    _logInfo('[API] GET /api/sessions');
    final database = container.read(databaseProvider);
    final sessions = await database.sessionsDao.getAllSessions();

    return jsonOk({"sessions": await _sessionsToJson(database, sessions)});
  }

  // Get Session By ID

  Future<Response> handleGetSessionById(Request request, String id) async {
    _logInfo('[API] GET /api/sessions/$id');
    final sessionId = _parsePathId(id, 'id');
    final database = container.read(databaseProvider);
    final session = await database.sessionsDao.getSessionById(sessionId);

    if (session == null) {
      return jsonNotFound({"error": "Session not found: $id"});
    }

    return jsonOk({
      "session": _sessionToJson(
        session,
        await _gradingFor(database, session.id),
      ),
    });
  }

  // Get active session

  Future<Response> handleGetActiveSession(Request request) async {
    _logInfo('[API] GET /api/sessions/active');
    final database = container.read(databaseProvider);
    final activeSessions = await database.sessionsDao.getActiveSessions();

    if (activeSessions.isEmpty) {
      return jsonOk({"session": null});
    }

    // Return the most recent active session
    final active = activeSessions.first;
    return jsonOk({
      "session": _sessionToJson(active, await _gradingFor(database, active.id)),
    });
  }

  // Get recent sessions

  Future<Response> handleGetRecentSessions(Request request) async {
    // Absent → 10. A supplied limit must be a positive, bounded whole number so
    // a negative can't become SQLite `LIMIT -1` (all rows) and a huge value
    // can't scan the whole session history. Validate before the DAO read.
    final limit =
        optionalQueryInt(
          request.url.queryParameters,
          'limit',
          min: 1,
          max: _maxRecentSessionsLimit,
        ) ??
        10;
    _logInfo('[API] GET /api/sessions/recent?limit=$limit');
    final database = container.read(databaseProvider);
    final sessions = await database.sessionsDao.getRecentSessions(limit: limit);

    return jsonOk({"sessions": await _sessionsToJson(database, sessions)});
  }

  // Create session

  Future<Response> handleCreateSession(Request request) async {
    _logInfo('[API] POST /api/sessions');
    final payload = await readJsonObject(request);
    const allowedFields = {'name', 'profileId', 'targetId', 'sequenceId'};
    final unknownFields = payload.keys
        .where((key) => !allowedFields.contains(key))
        .toList(growable: false);
    if (unknownFields.isNotEmpty) {
      throw BadRequestError(
        field: unknownFields.join(','),
        expected: 'one of: ${allowedFields.join(', ')}',
        message: 'Unknown session field${unknownFields.length == 1 ? '' : 's'}',
      );
    }
    if (!payload.keys.any(allowedFields.contains)) {
      throw BadRequestError(
        field: 'body',
        expected: 'at least one of: ${allowedFields.join(', ')}',
        message: 'A session must identify its name or imaging context',
      );
    }

    final name = optionalString(payload, 'name')?.trim();
    if (payload.containsKey('name') && (name == null || name.isEmpty)) {
      throw BadRequestError(
        field: 'name',
        expected: 'non-blank string',
        message: 'Session name must not be blank',
      );
    }
    final profileId = optionalInt(payload, 'profileId', min: 1);
    final targetId = optionalInt(payload, 'targetId', min: 1);
    final sequenceId = optionalInt(payload, 'sequenceId', min: 1);
    final database = container.read(databaseProvider);

    if (profileId != null &&
        await database.equipmentProfilesDao.getProfileById(profileId) == null) {
      throw BadRequestError(
        field: 'profileId',
        expected: 'an existing equipment profile id',
      );
    }
    if (targetId != null &&
        await database.targetsDao.getTargetById(targetId) == null) {
      throw BadRequestError(
        field: 'targetId',
        expected: 'an existing target id',
      );
    }
    if (sequenceId != null &&
        await database.sequencesDao.getSequenceById(sequenceId) == null) {
      throw BadRequestError(
        field: 'sequenceId',
        expected: 'an existing sequence id',
      );
    }

    final int id;
    try {
      id = await database.sessionsDao.startSession(
        name: name,
        profileId: profileId,
        targetId: targetId,
        sequenceId: sequenceId,
      );
    } on ActiveImagingSessionException catch (error) {
      return jsonConflict({
        'error': 'active_session_exists',
        'message': error.toString(),
        'activeSessionId': error.sessionId,
      });
    }

    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.session,
      action: HostMutationAction.created,
      entityId: id.toString(),
    );
    return jsonOk({"status": "created", "id": id});
  }

  // Update session

  Future<Response> handleUpdateSession(Request request, String id) async {
    _logInfo('[API] PUT /api/sessions/$id');
    final sessionId = _parsePathId(id, 'id');
    final payload = await readJsonObject(request);
    final database = container.read(databaseProvider);

    // Update stats if provided
    if (payload.containsKey('totalExposures') ||
        payload.containsKey('successfulExposures') ||
        payload.containsKey('failedExposures') ||
        payload.containsKey('totalIntegrationSecs') ||
        payload.containsKey('avgHfr') ||
        payload.containsKey('avgGuidingRms') ||
        payload.containsKey('autofocusCount')) {
      await database.sessionsDao.updateSessionStats(
        sessionId,
        totalExposures: optionalInt(payload, 'totalExposures', min: 0),
        successfulExposures: optionalInt(
          payload,
          'successfulExposures',
          min: 0,
        ),
        failedExposures: optionalInt(payload, 'failedExposures', min: 0),
        totalIntegrationSecs: optionalDouble(
          payload,
          'totalIntegrationSecs',
          min: 0,
        ),
        avgHfr: optionalDouble(payload, 'avgHfr', min: 0),
        avgGuidingRms: optionalDouble(payload, 'avgGuidingRms', min: 0),
        autofocusCount: optionalInt(payload, 'autofocusCount', min: 0),
      );
    }

    // Update notes if provided
    if (payload.containsKey('notes')) {
      await database.sessionsDao.updateNotes(
        sessionId,
        requireString(payload, 'notes', allowEmpty: true),
      );
    }

    // Update status if provided
    if (payload.containsKey('status')) {
      final status = requireString(payload, 'status');
      if (!const {'active', 'completed', 'aborted', 'error'}.contains(status)) {
        throw BadRequestError(
          field: 'status',
          expected: 'active|completed|aborted|error',
        );
      }
      await database.sessionsDao.updateSessionStatus(sessionId, status);
    }

    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.session,
      action: HostMutationAction.updated,
      entityId: sessionId.toString(),
    );
    return jsonOk({"status": "updated"});
  }

  // End session

  Future<Response> handleEndSession(Request request, String id) async {
    _logInfo('[API] POST /api/sessions/$id/end');
    final sessionId = _parsePathId(id, 'id');
    final payload = await readJsonObject(request);
    final status = optionalString(payload, 'status') ?? 'completed';
    if (!const {'completed', 'aborted', 'error'}.contains(status)) {
      throw BadRequestError(
        field: 'status',
        expected: 'completed|aborted|error',
      );
    }
    final database = container.read(databaseProvider);

    await database.sessionsDao.endSession(sessionId, status: status);

    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.session,
      action: HostMutationAction.updated,
      entityId: sessionId.toString(),
      extra: {'status': status},
    );
    return jsonOk({"status": "ended"});
  }

  // Delete session

  Future<Response> handleDeleteSession(Request request, String id) async {
    _logInfo('[API] DELETE /api/sessions/$id');
    final sessionId = _parsePathId(id, 'id');
    final database = container.read(databaseProvider);

    final deleted = await database.sessionsDao.deleteSession(sessionId);
    if (deleted == 0) {
      return jsonNotFound({"error": "Session not found: $id"});
    }

    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.session,
      action: HostMutationAction.deleted,
      entityId: sessionId.toString(),
    );
    return jsonOk({"status": "deleted"});
  }

  // Get session stats

  /// `GET /api/sessions/<id>/stats`
  ///
  /// `avgHfr` here is the SAME number `/api/sessions`, `/api/sessions/<id>` and
  /// the session export report: the stored `imaging_sessions.avg_hfr`, which is
  /// the running mean over ACCEPTED frames only (see
  /// `SessionStateNotifier.recordExposureComplete` for the rule and why
  /// rejected subs are kept out of it). This endpoint used to answer its own
  /// question —
  /// the mean over every `captured_images` row that carried an HFR, rejects and
  /// calibration frames included — so a night in which every light was rejected
  /// reported `avgHfr: null` on three surfaces and a real number here, for one
  /// session read at one moment.
  ///
  /// The all-lights mean is still worth having: it is the diagnostic that
  /// answers "was it focus or was it cloud?", which is the question an
  /// all-rejected night raises. So it is reported too — as
  /// `avgHfrAllLights`, a DIFFERENT question with its own name and its own
  /// sample count, never as a second value for `avgHfr`.
  Future<Response> handleGetSessionStats(Request request, String id) async {
    _logInfo('[API] GET /api/sessions/$id/stats');
    final sessionId = _parsePathId(id, 'id');
    final database = container.read(databaseProvider);
    final session = await database.sessionsDao.getSessionById(sessionId);

    if (session == null) {
      return jsonNotFound({"error": "Session not found: $id"});
    }

    // Get images for this session
    final images = await database.imagesDao.getImagesForSession(sessionId);
    // The same read the list surfaces use, rather than a second tally over the
    // rows already in hand: two counters over one fact drift, and this endpoint
    // and `/api/sessions` disagreeing about one night is exactly the defect
    // this call closes.
    final grading = await _gradingFor(database, sessionId);

    // Calculate stats
    int lightCount = 0;
    int darkCount = 0;
    int flatCount = 0;
    int biasCount = 0;
    // The all-lights HFR diagnostic (see the doc comment): every light frame
    // that carried a measurement, accepted or rejected. Calibration frames are
    // excluded because a dark's HFR is not a focus reading.
    double totalLightHfr = 0;
    int lightHfrCount = 0;
    final filterCounts = <String, int>{};

    for (final img in images) {
      switch (img.frameType) {
        case 'light':
          lightCount++;
          break;
        case 'dark':
          darkCount++;
          break;
        case 'flat':
          flatCount++;
          break;
        case 'bias':
          biasCount++;
          break;
      }

      if (img.hfr != null && img.frameType == 'light') {
        totalLightHfr += img.hfr!;
        lightHfrCount++;
      }

      if (img.filter != null) {
        filterCounts[img.filter!] = (filterCounts[img.filter!] ?? 0) + 1;
      }
    }

    return jsonOk({
      "stats": {
        "totalExposures": session.totalExposures,
        "successfulExposures": session.successfulExposures,
        "failedExposures": session.failedExposures,
        "totalIntegrationSecs": session.totalIntegrationSecs,
        "acceptedLights": grading.accepted,
        "rejectedLights": grading.rejected,
        "avgHfr": session.avgHfr,
        "avgHfrBasis": _kAvgHfrBasis,
        "avgHfrAllLights": lightHfrCount > 0
            ? totalLightHfr / lightHfrCount
            : null,
        "avgHfrAllLightsCount": lightHfrCount,
        "avgGuidingRms": session.avgGuidingRms,
        "autofocusCount": session.autofocusCount,
        "frameBreakdown": {
          "light": lightCount,
          "dark": darkCount,
          "flat": flatCount,
          "bias": biasCount,
        },
        "filterBreakdown": filterCounts,
        "durationSecs": session.endTime != null
            ? session.endTime!.difference(session.startTime).inSeconds
            : DateTime.now().difference(session.startTime).inSeconds,
      },
    });
  }

  // Session science data

  Future<Response> handleGetSessionPsfTiles(Request request, String id) async {
    _logInfo('[API] GET /api/sessions/$id/psf-tiles');
    final sessionId = _parsePathId(id, 'id');
    final database = container.read(databaseProvider);
    final psfTiles = await database.scienceDao.getPsfTilesForSession(sessionId);

    return jsonOk({'psfTiles': psfTiles.map(_psfTileToJson).toList()});
  }

  Future<Response> handleGetSessionResiduals(Request request, String id) async {
    _logInfo('[API] GET /api/sessions/$id/residuals');
    final sessionId = _parsePathId(id, 'id');
    final database = container.read(databaseProvider);
    final residuals = await database.scienceDao.getResidualsForSession(
      sessionId,
    );

    return jsonOk({'residuals': residuals.map(_residualVectorToJson).toList()});
  }

  // Get analytics summary

  Future<Response> handleGetAnalyticsSummary(Request request) async {
    _logInfo('[API] GET /api/analytics/summary');
    final sessions = await _sessionsInRequestedRange(request);
    final stats = _statisticsForSessions(sessions);

    return jsonOk({
      "summary": {
        "totalSessions": stats['totalSessions'],
        "totalExposures": stats['totalExposures'],
        "totalIntegrationHours": stats['totalIntegrationHours'],
        "sessionsInRange": sessions.length,
      },
    });
  }

  // Get total integration time

  Future<Response> handleGetTotalIntegrationTime(Request request) async {
    _logInfo('[API] GET /api/analytics/integration-time');
    final sessions = await _sessionsInRequestedRange(request);
    final stats = _statisticsForSessions(sessions);

    return jsonOk({
      "totalIntegrationSecs": stats['totalIntegrationSecs'],
      "totalIntegrationHours": stats['totalIntegrationHours'],
    });
  }

  // Get target statistics

  Future<Response> handleGetTargetStatistics(
    Request request,
    String targetId,
  ) async {
    _logInfo('[API] GET /api/analytics/target/$targetId');
    final tid = _parsePathId(targetId, 'targetId');
    final database = container.read(databaseProvider);
    final stats = await database.sessionsDao.getTargetStatistics(tid);

    return jsonOk({"stats": stats});
  }

  // Untracked targets cleanup

  /// GET /api/analytics/untracked-targets/count
  /// Number of "untracked" library targets (no integration goal, not a
  /// favorite, no captured subs, no integration time, not referenced by any
  /// imaging session) eligible for the opt-in Analytics cleanup. Same
  /// session-aware predicate as the local Drift path, run against the host DB.
  Future<Response> handleGetUntrackedTargetsCount(Request request) async {
    _logInfo('[API] GET /api/analytics/untracked-targets/count');
    final database = container.read(databaseProvider);
    final count = await database.targetsDao.countUntrackedTargets();

    return jsonOk({"count": count});
  }

  /// POST /api/analytics/untracked-targets/remove
  /// Permanently removes every untracked library target (see
  /// [handleGetUntrackedTargetsCount]) and returns how many rows were deleted.
  /// Irreversible — the client confirms with the user before calling this.
  Future<Response> handleRemoveUntrackedTargets(Request request) async {
    _logInfo('[API] POST /api/analytics/untracked-targets/remove');
    final database = container.read(databaseProvider);
    final deleted = await database.targetsDao.deleteUntrackedTargets();

    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.target,
      action: HostMutationAction.deleted,
    );
    return jsonOk({"status": "removed", "deleted": deleted});
  }

  // Get sessions for target

  Future<Response> handleGetSessionsForTarget(
    Request request,
    String targetId,
  ) async {
    _logInfo('[API] GET /api/analytics/target/$targetId/sessions');
    final tid = _parsePathId(targetId, 'targetId');
    final database = container.read(databaseProvider);
    final sessions = await database.sessionsDao.getSessionsForTarget(tid);

    return jsonOk({"sessions": await _sessionsToJson(database, sessions)});
  }

  // Helpers

  /// Accepted and rejected LIGHT frames per session id, counted from
  /// `captured_images` — the one place the grading verdict is recorded.
  ///
  /// Every session surface reads it through here, so the list and the
  /// per-session stats cannot disagree about the same night. They did: the
  /// list served `imaging_sessions.successful_exposures` on its own, which the
  /// session writer stamps from completed exposures, so a night whose twelve
  /// subs were all rejected for low star count reported "successful 12,
  /// failed 0" while `/api/sessions/<id>/stats` — the only surface that then
  /// read the frames — reported 0 accepted and 12 rejected.
  ///
  /// One grouped read for the whole page: a hundred-session list stays one
  /// query instead of a hundred. Calibration frames are excluded because they
  /// are never graded, so counting them would inflate `accepted` with darks
  /// and flats nobody culled.
  Future<Map<int, SessionGrading>> _gradingBySession(
    SkotiqDatabase database,
    List<int> sessionIds,
  ) async {
    if (sessionIds.isEmpty) return const <int, SessionGrading>{};

    final accepted = <int, int>{};
    final rejected = <int, int>{};
    // `/api/sessions` is unbounded, and SQLite refuses a statement with more
    // bound variables than its compiled limit. A rig with more nights than one
    // batch reads them in several statements rather than raising a limit error
    // on the endpoint an operator opens to see the season.
    for (
      var start = 0;
      start < sessionIds.length;
      start += _idsPerGradingRead
    ) {
      final batch = sessionIds.sublist(
        start,
        (start + _idsPerGradingRead).clamp(0, sessionIds.length),
      );
      final placeholders = List.filled(batch.length, '?').join(', ');
      final rows = await database
          .customSelect(
            'SELECT session_id, is_accepted, COUNT(*) AS frames '
            'FROM captured_images '
            "WHERE frame_type = 'light' AND session_id IN ($placeholders) "
            'GROUP BY session_id, is_accepted',
            variables: [for (final id in batch) Variable<int>(id)],
            readsFrom: {database.capturedImages},
          )
          .get();
      for (final row in rows) {
        final sessionId = row.read<int>('session_id');
        final frames = row.read<int>('frames');
        final bucket = row.read<bool>('is_accepted') ? accepted : rejected;
        bucket[sessionId] = (bucket[sessionId] ?? 0) + frames;
      }
    }

    return {
      for (final id in sessionIds)
        id: SessionGrading(
          accepted: accepted[id] ?? 0,
          rejected: rejected[id] ?? 0,
        ),
    };
  }

  /// The grading verdict for a single session.
  Future<SessionGrading> _gradingFor(
    SkotiqDatabase database,
    int sessionId,
  ) async {
    final bySession = await _gradingBySession(database, [sessionId]);
    return bySession[sessionId] ?? const SessionGrading.noFrames();
  }

  /// Serialize a list of sessions, reading every session's grading verdict in
  /// one query rather than one per row.
  Future<List<Map<String, dynamic>>> _sessionsToJson(
    SkotiqDatabase database,
    List<ImagingSession> sessions,
  ) async {
    final grading = await _gradingBySession(database, [
      for (final session in sessions) session.id,
    ]);
    return [
      for (final session in sessions)
        _sessionToJson(
          session,
          grading[session.id] ?? const SessionGrading.noFrames(),
        ),
    ];
  }

  Map<String, dynamic> _sessionToJson(
    ImagingSession session,
    SessionGrading grading,
  ) {
    return {
      'id': session.id,
      'name': session.name,
      'startTime': session.startTime.millisecondsSinceEpoch,
      'endTime': session.endTime?.millisecondsSinceEpoch,
      'status': session.status,
      'profileId': session.profileId,
      'targetId': session.targetId,
      'sequenceId': session.sequenceId,
      'totalExposures': session.totalExposures,
      'successfulExposures': session.successfulExposures,
      'failedExposures': session.failedExposures,
      // What the culling actually decided. `successfulExposures` above answers
      // "did the camera return the frame"; these answer "is the frame worth
      // stacking", and a client that shows only the first reports a clean
      // night for a session whose every sub was thrown away.
      'acceptedLights': grading.accepted,
      'rejectedLights': grading.rejected,
      'totalIntegrationSecs': session.totalIntegrationSecs,
      'avgHfr': session.avgHfr,
      // The rule travels with the figure, on every surface that ships it, so a
      // client rendering "Mean HFR --" for an all-rejected night can say WHY it
      // is empty instead of leaving the operator to guess.
      'avgHfrBasis': _kAvgHfrBasis,
      'avgGuidingRms': session.avgGuidingRms,
      'autofocusCount': session.autofocusCount,
      'avgTemperature': session.avgTemperature,
      'avgHumidity': session.avgHumidity,
      'avgSeeing': session.avgSeeing,
      'notes': session.notes,
      'equipmentSnapshot': session.equipmentSnapshot,
    };
  }

  Map<String, dynamic> _psfTileToJson(PsfFieldTileRow tile) {
    return {
      'id': tile.id,
      'capturedImageId': tile.capturedImageId,
      'sessionId': tile.sessionId,
      'tileRow': tile.tileRow,
      'tileCol': tile.tileCol,
      'starCount': tile.starCount,
      'medianFwhm': tile.medianFwhm,
      'medianHfr': tile.medianHfr,
      'medianEccentricity': tile.medianEccentricity,
      'roundness': tile.roundness,
      'timestamp': tile.timestamp.millisecondsSinceEpoch,
    };
  }

  Map<String, dynamic> _residualVectorToJson(
    AstrometryResidualVectorRow residual,
  ) {
    return {
      'id': residual.id,
      'capturedImageId': residual.capturedImageId,
      'sessionId': residual.sessionId,
      'x': residual.x,
      'y': residual.y,
      'dxArcsec': residual.dxArcsec,
      'dyArcsec': residual.dyArcsec,
      'magnitudeArcsec': residual.magnitudeArcsec,
      'recommendationCode': residual.recommendationCode,
      'timestamp': residual.timestamp.millisecondsSinceEpoch,
    };
  }
}
