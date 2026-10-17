// API surface for DB tables the phone could not see
// before this wave (sequence_runs, observation_logs (notes journal),
// guide_rms_history, polar_alignment_history) plus paginated reads on
// the calibration tables (dark_library, flat_history) that bypass the
// existing "best match" semantics.
//
// Replay scrubber extensions. Three additional endpoints
// support the mobile session-replay surface:
//
//   GET /api/sequence-runs/<runId>
//   GET /api/sequence-runs/<runId>/events
//   GET /api/sequence-runs/<runId>/frames
//
// These are scoped to a single past run so the phone can rehydrate the
// dashboard state at any point during a finished session.
//
// Endpoints (all under /api):
//
//   Sequence run history:
//     GET /api/sequence-runs
//         ?sequenceId=&limit=&offset=
//
//   Notes journal (observation_logs):
//     GET /api/notes-journal
//         ?equipmentProfileId=&limit=&offset=
//     POST /api/notes-journal
//     DELETE /api/notes-journal/<id>
//     DELETE /api/notes-journal
//
//   Guide-RMS history (time-bucketed):
//     GET /api/guide-rms-history
//         ?sinceMs=&untilMs=&limit=&offset=
//
//   Polar alignment history:
//     GET /api/polar-alignment-history
//         ?equipmentProfileId=&limit=&offset=
//
//   Dark library (paginated read):
//     GET /api/db/dark-library
//         ?gainMin=&gainMax=&temperatureC=&exposureSecs=&limit=&offset=
//
//   Flat history (paginated read):
//     GET /api/db/flat-history
//         ?filterName=&panelKey=&limit=&offset=
//
// The dark/flat reads live under /api/db/ rather than /api/calibration/
// so we do NOT clash with the existing calibration endpoints
// (which use different filter shapes — exposure tolerance ratios etc.).
//
// All endpoints return a JSON envelope: `{ "items": [...], "total": N }`.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// Read handlers for the DB tables the phone reads directly.
class DbReadHandlers {
  /// Default page size. Same value as the science / calibration read
  /// surfaces use, so phone callers can apply one batching policy.
  static const int defaultLimit = 200;

  /// Hard upper bound per request. Picked so a fully-populated row of
  /// the largest table (sequence_runs.statsJson can be tens of KB)
  /// still fits in a typical mobile read budget.
  static const int maxLimit = 1000;

  final ProviderContainer container;

  DbReadHandlers(this.container);

  LoggingService get _logger => container.read(loggingServiceProvider);
  SkotiqDatabase get _database => container.read(databaseProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'DbReadHandlers');

  /// Parse and clamp a `limit` query parameter. Defaults to
  /// [defaultLimit]; clamps to [1, maxLimit]. Why clamp silently here
  /// (and not throw): the spec promises pagination, and a phone caller
  /// asking for 5000 rows is better off receiving 1000 than a 400.
  int _parseLimit(String? raw) {
    if (raw == null || raw.isEmpty) return defaultLimit;
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed <= 0) return defaultLimit;
    return parsed > maxLimit ? maxLimit : parsed;
  }

  /// Parse and clamp an `offset` query parameter. Defaults to 0;
  /// negative offsets are treated as 0.
  int _parseOffset(String? raw) {
    if (raw == null || raw.isEmpty) return 0;
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed < 0) return 0;
    return parsed;
  }

  int? _parseOptionalInt(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return int.tryParse(raw);
  }

  double? _parseOptionalDouble(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return double.tryParse(raw);
  }

  // Sequence run history

  Future<Response> handleListSequenceRuns(Request request) async {
    _logInfo('[API] GET /api/sequence-runs');
    final qp = request.url.queryParameters;
    final limit = _parseLimit(qp['limit']);
    final offset = _parseOffset(qp['offset']);
    final sequenceId = _parseOptionalInt(qp['sequenceId']);

    final dao = _database.sequenceRunsDao;
    final rows = await dao.listPaginated(
      sequenceId: sequenceId,
      limit: limit,
      offset: offset,
    );
    final total = await dao.countFiltered(sequenceId: sequenceId);

    return jsonOk({
      'items': rows.map(_sequenceRunToJson).toList(),
      'total': total,
    });
  }

  Map<String, dynamic> _sequenceRunToJson(SequenceRun row) {
    return {
      'id': row.id,
      'sequenceId': row.sequenceId,
      'sequenceName': row.sequenceName,
      'startedAt': row.startedAt.toIso8601String(),
      'endedAt': row.endedAt?.toIso8601String(),
      'status': row.status,
      'statsJson': row.statsJson,
    };
  }

  // Notes journal (observation_logs)
  //
  // The task spec said "?sessionId=" — but the underlying observation_logs
  // table is per-equipment-profile, not per-imaging-session. We expose
  // the actual column (equipmentProfileId) so the phone gets a filter
  // that matches reality instead of a silent no-op on a fake key.

  Future<Response> handleListNotesJournal(Request request) async {
    _logInfo('[API] GET /api/notes-journal');
    final qp = request.url.queryParameters;
    final limit = _parseLimit(qp['limit']);
    final offset = _parseOffset(qp['offset']);
    final profileId = _parseOptionalInt(qp['equipmentProfileId']);

    final dao = _database.observationLogsDao;
    final rows = await dao.listPaginated(
      equipmentProfileId: profileId,
      limit: limit,
      offset: offset,
    );
    final total = await dao.countFiltered(equipmentProfileId: profileId);

    return jsonOk({
      'items': rows.map(_observationLogToJson).toList(),
      'total': total,
    });
  }

  Future<Response> handleCreateObservationLog(Request request) async {
    _logInfo('[API] POST /api/notes-journal');
    final payload = await readJsonObject(request);
    final timestampRaw = requireString(payload, 'timestamp');
    final timestamp = DateTime.tryParse(timestampRaw);
    if (timestamp == null) {
      throw BadRequestError(
        field: 'timestamp',
        expected: 'ISO-8601 timestamp',
        message: 'timestamp must be a valid ISO-8601 timestamp',
      );
    }

    final id = await _database.observationLogsDao.insertLog(
      timestamp: timestamp,
      objectName: requireString(payload, 'objectName', maxLength: 500),
      ra: requireDouble(payload, 'ra', min: 0, max: 24),
      dec: requireDouble(payload, 'dec', min: -90, max: 90),
      objectType: optionalString(payload, 'objectType', maxLength: 100),
      catalogId: optionalString(payload, 'catalogId', maxLength: 100),
      altitude: optionalDouble(payload, 'altitude', min: -90, max: 90),
      azimuth: optionalDouble(payload, 'azimuth', min: 0, max: 360),
      notes: optionalString(payload, 'notes', allowEmpty: true),
      rating: optionalInt(payload, 'rating', min: 1, max: 5),
      equipmentProfileId: optionalInt(payload, 'equipmentProfileId', min: 1),
      seeingConditions: optionalString(
        payload,
        'seeingConditions',
        maxLength: 100,
      ),
      transparency: optionalString(payload, 'transparency', maxLength: 100),
      locationName: optionalString(payload, 'locationName', maxLength: 500),
      latitude: optionalDouble(payload, 'latitude', min: -90, max: 90),
      longitude: optionalDouble(payload, 'longitude', min: -180, max: 180),
    );
    return jsonOk({'status': 'created', 'id': id});
  }

  Future<Response> handleDeleteObservationLog(
    Request request,
    String idRaw,
  ) async {
    _logInfo('[API] DELETE /api/notes-journal/$idRaw');
    final id = int.tryParse(idRaw);
    if (id == null || id <= 0) {
      throw BadRequestError(
        field: 'id',
        expected: 'positive integer',
        message: '"$idRaw" is not a valid observation-log id',
      );
    }
    final deleted = await _database.observationLogsDao.deleteLog(id);
    if (deleted == 0) {
      return jsonNotFound({
        'error': 'observation_log_not_found',
        'message': 'No observation log with id $id',
      });
    }
    return jsonOk({'status': 'deleted', 'id': id});
  }

  Future<Response> handleDeleteAllObservationLogs(Request request) async {
    _logInfo('[API] DELETE /api/notes-journal');
    final deleted = await _database.observationLogsDao.deleteAllLogs();
    return jsonOk({'status': 'deleted', 'count': deleted});
  }

  Map<String, dynamic> _observationLogToJson(ObservationLogEntry row) {
    return {
      'id': row.id,
      'timestamp': row.timestamp.toUtc().toIso8601String(),
      'objectName': row.objectName,
      'objectType': row.objectType,
      'catalogId': row.catalogId,
      'ra': row.ra,
      'dec': row.dec,
      'altitude': row.altitude,
      'azimuth': row.azimuth,
      'notes': row.notes,
      'rating': row.rating,
      'equipmentProfileId': row.equipmentProfileId,
      'seeingConditions': row.seeingConditions,
      'transparency': row.transparency,
      'locationName': row.locationName,
      'latitude': row.latitude,
      'longitude': row.longitude,
    };
  }

  // Guide-RMS history

  Future<Response> handleListGuideRmsHistory(Request request) async {
    _logInfo('[API] GET /api/guide-rms-history');
    final qp = request.url.queryParameters;
    final limit = _parseLimit(qp['limit']);
    final offset = _parseOffset(qp['offset']);
    final sinceMs = _parseOptionalInt(qp['sinceMs']);
    final untilMs = _parseOptionalInt(qp['untilMs']);
    final mountId = qp['mountId']?.trim();

    final dao = _database.guideRmsHistoryDao;
    final rows = await dao.listPaginated(
      mountId: mountId,
      sinceMs: sinceMs,
      untilMs: untilMs,
      limit: limit,
      offset: offset,
    );
    final total = await dao.countFiltered(
      mountId: mountId,
      sinceMs: sinceMs,
      untilMs: untilMs,
    );

    return jsonOk({
      'items': rows.map(_guideRmsToJson).toList(),
      'total': total,
    });
  }

  Map<String, dynamic> _guideRmsToJson(GuideRmsHistoryEntry row) {
    return {
      'id': row.id,
      'sessionId': row.sessionId,
      'mountId': row.mountId,
      'targetId': row.targetId,
      'totalRmsArcsec': row.totalRmsArcsec,
      'sampleCount': row.sampleCount,
      'exposureSeconds': row.exposureSeconds,
      'recordedAt': row.recordedAt.toIso8601String(),
    };
  }

  // Polar alignment history

  Future<Response> handleListPolarAlignmentHistory(Request request) async {
    _logInfo('[API] GET /api/polar-alignment-history');
    final qp = request.url.queryParameters;
    final limit = _parseLimit(qp['limit']);
    final offset = _parseOffset(qp['offset']);
    final profileId = _parseOptionalInt(qp['equipmentProfileId']);

    final dao = _database.polarAlignmentHistoryDao;
    final rows = await dao.listPaginated(
      equipmentProfileId: profileId,
      limit: limit,
      offset: offset,
    );
    final total = await dao.countFiltered(equipmentProfileId: profileId);

    return jsonOk({
      'items': rows.map(_polarAlignmentToJson).toList(),
      'total': total,
    });
  }

  Map<String, dynamic> _polarAlignmentToJson(PolarAlignmentHistoryEntry row) {
    return {
      'id': row.id,
      'equipmentProfileId': row.equipmentProfileId,
      'initialAzimuthError': row.initialAzimuthError,
      'initialAltitudeError': row.initialAltitudeError,
      'initialTotalError': row.initialTotalError,
      'finalAzimuthError': row.finalAzimuthError,
      'finalAltitudeError': row.finalAltitudeError,
      'finalTotalError': row.finalTotalError,
      'startedAt': row.startedAt.toIso8601String(),
      'completedAt': row.completedAt.toIso8601String(),
      'autoCompleted': row.autoCompleted,
      'isNorth': row.isNorth,
      'configJson': row.configJson,
    };
  }

  // Journal notes (notes_journal — the operator's per-target / per-run
  // notes). Distinct from /api/notes-journal, which despite its name serves
  // the observation_logs table. The notes_journal table lives outside
  // @DriftDatabase and is read through NotesService's raw SQL, so we serve
  // it here with the same JournalNote.toJson shape the slave decodes.

  Future<Response> handleListJournalNotes(Request request) async {
    _logInfo('[API] GET /api/db/notes');
    final qp = request.url.queryParameters;
    final targetId = qp['targetId'];
    final runId = _parseOptionalInt(qp['runId']);

    final service = NotesService(_database);
    final List<JournalNote> notes;
    if (targetId != null && targetId.isNotEmpty) {
      notes = await service.notesForTarget(targetId);
    } else if (runId != null) {
      notes = await service.notesForRun(runId);
    } else {
      notes = await service.allNotes();
    }

    return jsonOk({
      'items': notes.map((n) => n.toJson()).toList(),
      'total': notes.length,
    });
  }

  Future<Response> handleCreateJournalNote(Request request) async {
    _logInfo('[API] POST /api/db/notes');
    final payload = await readJsonObject(request);
    final service = NotesService(_database);
    final note = await service.addNote(
      targetId: requireString(payload, 'targetId', maxLength: 500),
      sequenceRunId: optionalInt(payload, 'sequenceRunId', min: 1),
      body: requireString(
        payload,
        'body',
        allowEmpty: true,
        maxLength: 1000000,
      ),
      title: optionalString(payload, 'title', maxLength: 1000),
      tags: optionalList<String>(payload, 'tags') ?? const <String>[],
      attachments:
          optionalList<String>(payload, 'attachments') ?? const <String>[],
      sentiment: optionalString(payload, 'sentiment', maxLength: 20),
    );
    return jsonOk({'status': 'created', 'note': note.toJson()});
  }

  Future<Response> handleUpdateJournalNote(Request request, String id) async {
    _logInfo('[API] PUT /api/db/notes/$id');
    if (id.trim().isEmpty || id.length > 200) {
      throw BadRequestError(
        field: 'id',
        expected: 'non-empty note id',
        message: 'Journal-note id is invalid',
      );
    }
    final payload = await readJsonObject(request);
    final service = NotesService(_database);
    if (await service.getNoteById(id) == null) {
      return jsonNotFound({
        'error': 'journal_note_not_found',
        'message': 'No journal note with id $id',
      });
    }
    final note = await service.updateNote(
      id,
      body: payload.containsKey('body')
          ? requireString(payload, 'body', allowEmpty: true, maxLength: 1000000)
          : null,
      title: optionalString(payload, 'title', maxLength: 1000),
      tags: optionalList<String>(payload, 'tags'),
      attachments: optionalList<String>(payload, 'attachments'),
      sentiment: optionalString(payload, 'sentiment', maxLength: 20),
      clearTitle: optionalBool(payload, 'clearTitle') ?? false,
      clearSentiment: optionalBool(payload, 'clearSentiment') ?? false,
    );
    return jsonOk({'status': 'updated', 'note': note.toJson()});
  }

  Future<Response> handleDeleteJournalNote(Request request, String id) async {
    _logInfo('[API] DELETE /api/db/notes/$id');
    if (id.trim().isEmpty || id.length > 200) {
      throw BadRequestError(
        field: 'id',
        expected: 'non-empty note id',
        message: 'Journal-note id is invalid',
      );
    }
    final service = NotesService(_database);
    final deleted = await service.deleteNote(id);
    if (deleted == 0) {
      return jsonNotFound({
        'error': 'journal_note_not_found',
        'message': 'No journal note with id $id',
      });
    }
    return jsonOk({'status': 'deleted', 'id': id});
  }

  // Dark library (paginated read)

  Future<Response> handleListDarkLibrary(Request request) async {
    _logInfo('[API] GET /api/db/dark-library');
    final qp = request.url.queryParameters;
    final limit = _parseLimit(qp['limit']);
    final offset = _parseOffset(qp['offset']);
    final gainMin = _parseOptionalInt(qp['gainMin']);
    final gainMax = _parseOptionalInt(qp['gainMax']);
    final temperatureC = _parseOptionalDouble(qp['temperatureC']);
    final exposureSecs = _parseOptionalDouble(qp['exposureSecs']);

    final dao = _database.darkLibraryDao;
    final rows = await dao.listPaginated(
      gainMin: gainMin,
      gainMax: gainMax,
      temperatureCelsius: temperatureC,
      exposureSeconds: exposureSecs,
      limit: limit,
      offset: offset,
    );
    final total = await dao.countFilteredForRemote(
      gainMin: gainMin,
      gainMax: gainMax,
      temperatureCelsius: temperatureC,
      exposureSeconds: exposureSecs,
    );

    return jsonOk({
      'items': rows.map(_darkLibraryToJson).toList(),
      'total': total,
    });
  }

  Map<String, dynamic> _darkLibraryToJson(DarkLibraryEntry row) {
    return {
      'id': row.id,
      'filePath': row.filePath,
      'frameType': row.frameType,
      'exposureTime': row.exposureTime,
      'gain': row.gain,
      'offset': row.offset,
      'binX': row.binX,
      'binY': row.binY,
      'temperature': row.temperature,
      'width': row.width,
      'height': row.height,
      'masterDarkPath': row.masterDarkPath,
      'masterFrameCount': row.masterFrameCount,
      'createdAt': row.createdAt.toIso8601String(),
    };
  }

  // Flat history (paginated read)

  Future<Response> handleListFlatHistory(Request request) async {
    _logInfo('[API] GET /api/db/flat-history');
    final qp = request.url.queryParameters;
    final limit = _parseLimit(qp['limit']);
    final offset = _parseOffset(qp['offset']);
    final filterName = qp['filterName'];
    // `panelKey` maps onto `panelBrightness` — see DAO comment for the
    // mapping rationale (no separate panel-id column in this table).
    final panelKey = _parseOptionalInt(qp['panelKey']);

    final dao = _database.flatHistoryDao;
    final rows = await dao.listPaginated(
      filterName: (filterName != null && filterName.isNotEmpty)
          ? filterName
          : null,
      panelBrightness: panelKey,
      limit: limit,
      offset: offset,
    );
    final total = await dao.countFiltered(
      filterName: (filterName != null && filterName.isNotEmpty)
          ? filterName
          : null,
      panelBrightness: panelKey,
    );

    return jsonOk({
      'items': rows.map(_flatHistoryToJson).toList(),
      'total': total,
    });
  }

  Map<String, dynamic> _flatHistoryToJson(FlatHistoryEntry row) {
    return {
      'id': row.id,
      'filterName': row.filterName,
      'exposureTime': row.exposureTime,
      'histogramTarget': row.histogramTarget,
      'actualAdu': row.actualAdu,
      'equipmentProfileId': row.equipmentProfileId,
      'panelBrightness': row.panelBrightness,
      'skyAduRate': row.skyAduRate,
      'twilightPhase': row.twilightPhase,
      'gain': row.gain,
      'binning': row.binning,
      'timestamp': row.timestamp.toIso8601String(),
    };
  }

  // Replay scrubber endpoints (single run + per-run events/frames).

  /// Parse a path-segment integer with translation to a structured 400.
  /// The existing `_parseOptionalInt` returns null for invalid input,
  /// which is fine for query params (the handler treats null as "filter
  /// not requested"); a missing/garbled path param is a client bug and
  /// must surface as a Bad Request rather than a silent no-op.
  int _parseRunId(String raw) {
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed <= 0) {
      throw BadRequestError(
        field: 'runId',
        expected: 'positive integer',
        message: '"$raw" is not a valid sequence-run id',
      );
    }
    return parsed;
  }

  bool _parseIncludeDiffContext(Request request) {
    final raw = request.url.queryParameters['includeDiffContext'];
    if (raw == null) return false;
    switch (raw.toLowerCase()) {
      case 'true':
        return true;
      case 'false':
        return false;
      default:
        throw BadRequestError(
          field: 'includeDiffContext',
          expected: 'boolean',
          message: 'includeDiffContext must be true or false',
        );
    }
  }

  /// `GET /api/sequence-runs/<runId>` — fetch a single sequence-run by id.
  ///
  /// The response carries everything the replay scrubber needs to build
  /// its timeline header: started/ended timestamps so it can compute the
  /// duration, the sequence and target names for the header label, the
  /// final status, the stats blob (frame count + integration time), and
  /// a `frameCount` projection convenience field so the client can render
  /// the header without parsing statsJson.
  Future<Response> handleGetSequenceRunById(
    Request request,
    String runIdRaw,
  ) async {
    _logInfo('[API] GET /api/sequence-runs/$runIdRaw');
    final runId = _parseRunId(runIdRaw);
    final includeDiffContext = _parseIncludeDiffContext(request);

    final run = await _database.sequenceRunsDao.getRunById(runId);
    if (run == null) {
      return jsonNotFound({
        'error': 'sequence_run_not_found',
        'message': 'No sequence run with id $runId',
      });
    }

    // Project a frame count by counting captured_images rows whose
    // producing_run_id matches the run id. This is the same source of
    // truth used by the run dashboard's thumbnail strip; we surface it
    // here so the replay's run-picker row doesn't have to call
    // /frames just to display "23 frames".
    final frameCount = await _database.imagesDao.countImagesByProducingRun(
      producingRunId: runId.toString(),
    );

    // Derive a target name from the captured frames (target_id → targets
    // table). Take the first-captured frame's target as the canonical one
    // — multi-target runs list them in capture order; the first non-null
    // target_id wins. If there are no frames or the join produces nothing
    // the field is omitted entirely so the client falls back to
    // sequenceName.
    String? targetName;
    if (frameCount > 0) {
      final firstFrames = await _database.imagesDao.getImagesByProducingRun(
        producingRunId: runId.toString(),
        limit: 1,
      );
      if (firstFrames.isNotEmpty && firstFrames.first.targetId != null) {
        final target = await _database.targetsDao.getTargetById(
          firstFrames.first.targetId!,
        );
        targetName = target?.name;
      }
    }

    Map<String, dynamic>? diffContext;
    if (includeDiffContext) {
      final previousSnapshot = run.sequenceId == null
          ? null
          : await _database.sequenceRunsDao.previousCompletedRunSnapshot(
              run.sequenceId!,
              before: run.startedAt,
            );
      diffContext = {
        'runId': run.id,
        'sequenceId': run.sequenceId,
        'currentSnapshotJson': _nonEmptySnapshot(run.sequenceSnapshotJson),
        'previousSnapshotJson': _nonEmptySnapshot(previousSnapshot),
      };
    }

    return jsonOk({
      'run': _sequenceRunDetailToJson(run, frameCount, targetName),
      if (diffContext != null) 'diffContext': diffContext,
    });
  }

  String? _nonEmptySnapshot(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    return value;
  }

  /// Detail-shaped JSON for a single run — same field names as the list
  /// view plus `frameCount` and `targetName` for replay header rendering.
  Map<String, dynamic> _sequenceRunDetailToJson(
    SequenceRun row,
    int frameCount,
    String? targetName,
  ) {
    return {
      'id': row.id,
      'sequenceId': row.sequenceId,
      'sequenceName': row.sequenceName,
      'startedAt': row.startedAt.toIso8601String(),
      'endedAt': row.endedAt?.toIso8601String(),
      'status': row.status,
      'statsJson': row.statsJson,
      'frameCount': frameCount,
      if (targetName != null) 'targetName': targetName,
    };
  }

  /// `GET /api/sequence-runs/<runId>/events` — paginated events captured
  /// during the run's time window.
  ///
  /// The headless server does NOT (yet) persist `SkotiqEvent`
  /// instances to a dedicated DAO — events are forwarded to the
  /// LoggingService which keeps an in-memory ring buffer (1000 entries)
  /// and the Rust tracing appender that writes to disk. The disk format
  /// is human-readable text, not structured JSON, and is not indexed
  /// by sequence-run id; for now the ring buffer is the only structured
  /// source we can hand back.
  ///
  /// Consequence: any run older than ~the last 1000 log entries (or one
  /// that ended before the server restarted) will return a sparse event
  /// list. We surface this loudly via `is_partial: true` in the
  /// envelope so the phone UI can render a banner explaining the gap
  /// rather than silently misleading the operator. Follow-up work is
  /// tracked in the W7B report — a `skotiq_events` DAO writing every
  /// broadcast event would make this lossless.
  Future<Response> handleGetSequenceRunEvents(
    Request request,
    String runIdRaw,
  ) async {
    _logInfo('[API] GET /api/sequence-runs/$runIdRaw/events');
    final runId = _parseRunId(runIdRaw);

    final run = await _database.sequenceRunsDao.getRunById(runId);
    if (run == null) {
      return jsonNotFound({
        'error': 'sequence_run_not_found',
        'message': 'No sequence run with id $runId',
      });
    }

    final qp = request.url.queryParameters;
    final limit = _parseLimit(qp['limit']);
    final offset = _parseOffset(qp['offset']);

    final sinceMs = _parseOptionalInt(qp['since']);
    final untilMs = _parseOptionalInt(qp['until']);

    final startBound = sinceMs != null
        ? DateTime.fromMillisecondsSinceEpoch(sinceMs)
        : run.startedAt;
    final endBound = untilMs != null
        ? DateTime.fromMillisecondsSinceEpoch(untilMs)
        : (run.endedAt ?? DateTime.now());

    LogLevel? severityMin;
    final sevRaw = qp['severityMin'];
    if (sevRaw != null && sevRaw.isNotEmpty) {
      final parsed = LoggingService.parseLogLevel(sevRaw);
      if (parsed == null) {
        throw BadRequestError(
          field: 'severityMin',
          expected: 'one of: ${LogLevel.values.map((l) => l.name).join(', ')}',
          message: '"$sevRaw" is not a valid severity name',
        );
      }
      severityMin = parsed;
    }

    final logger = container.read(loggingServiceProvider);
    final allEntries = logger.getRecentLogs(minLevel: severityMin);
    final inWindow = allEntries.where((e) {
      // Inclusive lower/upper bounds — the run header events
      // `sequencer.started` and `sequencer.completed` line up exactly
      // with `startedAt`/`endedAt` so half-open semantics would drop
      // the bookends.
      if (e.timestamp.isBefore(startBound)) return false;
      if (e.timestamp.isAfter(endBound)) return false;
      return true;
    }).toList();

    final total = inWindow.length;
    final end = (offset + limit).clamp(0, total);
    final start = offset.clamp(0, total);
    final slice = (start >= end) ? <LogEntry>[] : inWindow.sublist(start, end);

    // The ring buffer is finite (1000 entries). If the oldest buffered
    // entry's timestamp is AFTER the run's startedAt we know we have
    // dropped older entries that should logically belong to this run.
    // Surface that as `is_partial` so the client can render a banner.
    final bool isPartial;
    final String? partialReason;
    if (allEntries.isEmpty) {
      isPartial = true;
      partialReason = 'no_buffered_entries';
    } else {
      final oldest = allEntries.first.timestamp;
      isPartial = oldest.isAfter(run.startedAt);
      partialReason = isPartial ? 'ring_buffer_truncated' : null;
    }

    return jsonOk({
      'items': slice.map(_eventEntryToJson).toList(growable: false),
      'total': total,
      'is_partial': isPartial,
      'source': 'logging_service_ring_buffer',
      if (partialReason != null) 'partialReason': partialReason,
    });
  }

  /// Project a LogEntry into the wire shape the replay client consumes.
  /// Mirrors LogEntry.toJson plus a unix-ms timestamp for monotonic
  /// scrubber arithmetic on the phone side (DateTime parsing on
  /// Dart-on-iOS has noticeable cost vs an int comparison; the scrubber
  /// runs the scan-to-time on every drag frame, so the extra field
  /// pays for itself within a few drags).
  Map<String, Object?> _eventEntryToJson(LogEntry entry) {
    return {
      'timestamp': entry.timestamp.toUtc().toIso8601String(),
      'timestampMs': entry.timestamp.millisecondsSinceEpoch,
      'severity': entry.level.name,
      if (entry.source != null) 'source': entry.source,
      'message': entry.message,
      if (entry.fields.isNotEmpty) 'fields': _jsonSafeFields(entry.fields),
    };
  }

  /// Defensive copy of [LogEntry.fields] suitable for JSON encoding.
  /// LogEntry already calls its private `_jsonSafe` helper on toJson,
  /// but that helper is unreachable from this file. We re-implement
  /// the narrow safety: pass through primitives, recurse into maps/
  /// iterables, stringify everything else. Mirrors the upstream
  /// helper so wire payloads agree shape-for-shape.
  Object? _jsonSafeFields(Object? value) {
    if (value == null || value is num || value is bool || value is String) {
      return value;
    }
    if (value is DateTime) return value.toIso8601String();
    if (value is Iterable) {
      return value.map(_jsonSafeFields).toList(growable: false);
    }
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key.toString(): _jsonSafeFields(entry.value),
      };
    }
    return value.toString();
  }

  /// `GET /api/sequence-runs/<runId>/frames` — paginated captured-image
  /// rows for the run.
  ///
  /// Joins to the `producing_run_id` raw-DDL column added in the v30
  /// migration. The row shape includes every column the replay
  /// scrubber's "current frame" panel may want: HFR, star count,
  /// background, guiding RMS at the time of the exposure, the filter
  /// name, and the file path so the phone can request a thumbnail via
  /// the existing `/api/images/<id>/thumbnail` endpoint.
  Future<Response> handleGetSequenceRunFrames(
    Request request,
    String runIdRaw,
  ) async {
    _logInfo('[API] GET /api/sequence-runs/$runIdRaw/frames');
    final runId = _parseRunId(runIdRaw);

    final run = await _database.sequenceRunsDao.getRunById(runId);
    if (run == null) {
      return jsonNotFound({
        'error': 'sequence_run_not_found',
        'message': 'No sequence run with id $runId',
      });
    }

    final qp = request.url.queryParameters;
    final limit = _parseLimit(qp['limit']);
    final offset = _parseOffset(qp['offset']);

    final frames = await _database.imagesDao.getImagesByProducingRun(
      producingRunId: runId.toString(),
      limit: limit,
      offset: offset,
    );
    final total = await _database.imagesDao.countImagesByProducingRun(
      producingRunId: runId.toString(),
    );

    return jsonOk({
      'items': frames.map(_capturedImageToJson).toList(growable: false),
      'total': total,
    });
  }

  /// Wire projection of a CapturedImage row scoped to what the replay
  /// scrubber renders. We deliberately do NOT include `displayData` or
  /// any FITS body bytes — those are served by `/api/images/{id}/...`
  /// endpoints and would balloon this list response.
  ///
  /// Uses [DbCapturedImage] because the skotiq_core barrel hides
  /// the raw drift `CapturedImage` entity to avoid colliding with the
  /// imaging-domain class of the same name.
  Map<String, Object?> _capturedImageToJson(DbCapturedImage row) {
    return {
      'id': row.id,
      'fileName': row.fileName,
      'filePath': row.filePath,
      'capturedAt': row.capturedAt.toIso8601String(),
      'capturedAtMs': row.capturedAt.millisecondsSinceEpoch,
      'frameType': row.frameType,
      'exposureDuration': row.exposureDuration,
      'filter': row.filter,
      'gain': row.gain,
      'offset': row.offset,
      'binX': row.binX,
      'binY': row.binY,
      'sensorTemp': row.sensorTemp,
      'hfr': row.hfr,
      'starCount': row.starCount,
      'background': row.background,
      'noise': row.noise,
      'qualityScore': row.qualityScore,
      'guidingRmsRa': row.guidingRmsRa,
      'guidingRmsDec': row.guidingRmsDec,
      'guidingRmsTotal': row.guidingRmsTotal,
      'mountRa': row.mountRa,
      'mountDec': row.mountDec,
      'mountAltitude': row.mountAltitude,
      'mountAzimuth': row.mountAzimuth,
      'focuserPosition': row.focuserPosition,
      'isAccepted': row.isAccepted,
      'rejectionReason': row.rejectionReason,
      'sessionId': row.sessionId,
      'targetId': row.targetId,
    };
  }
}
