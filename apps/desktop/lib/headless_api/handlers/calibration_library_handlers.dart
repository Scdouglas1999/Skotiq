import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// Handlers for the unified Calibration Library Manager.
///
/// Distinct from the per-table `/api/calibration/*` CRUD surface: this
/// exposes the *library* view that joins darks, flats, biases, and defect
/// maps into one list with user tags/notes ([CalibrationLibraryService]),
/// plus the transparent auto-matcher a remote client uses to preview which
/// masters a given light-frame context will auto-select and why.
///
/// Endpoints (all under `/api/calibration-library`):
///   GET    /api/calibration-library            — list masters (filters)
///   POST   /api/calibration-library/match      — best master per type + why
///   PUT    `/api/calibration-library/<type>/<id>/tags` — set tags/notes
///   DELETE `/api/calibration-library/<type>/<id>`      — delete row (+ file?)
class CalibrationLibraryHandlers {
  final ProviderContainer container;
  CalibrationLibraryHandlers(this.container);

  /// Map a hub-transport failure onto its wire status.
  ///
  /// A hub fault on the share paths must not reach the generic trap as a 500
  /// `internal_error`: "your hub is switched off" would read as "the appliance
  /// is broken", and a remote client could not tell a retryable outage from a
  /// request it must fix. Identical to `MosaicHandlers` / `CoImagingHandlers`
  /// — one feature must not answer three different codes for one cause.
  static int _hubStatusFor(ConstellationErrorKind kind) => switch (kind) {
    // No answer from the hub at all — this appliance is the gateway.
    ConstellationErrorKind.network => 502,
    // The hub answered, but is itself unhealthy; retry later.
    ConstellationErrorKind.server => 503,
    ConstellationErrorKind.auth => 401,
    ConstellationErrorKind.notFound => 404,
    ConstellationErrorKind.conflict => 409,
    ConstellationErrorKind.geometryMismatch => 409,
    // The hub rejected the request itself — the caller must change it.
    ConstellationErrorKind.protocol => 400,
    _ => 502,
  };

  Response _hubError(
    ConstellationException error, {
    required String code,
    required String message,
  }) {
    _logger.warning(
      '[API] $code: $error',
      source: 'CalibrationLibraryHandlers',
    );
    return jsonError(
      code: code,
      message: '$message: ${error.message}',
      statusCode: _hubStatusFor(error.kind),
    );
  }

  LoggingService get _logger => container.read(loggingServiceProvider);
  CalibrationLibraryService get _service =>
      container.read(calibrationLibraryServiceProvider);

  /// Captured calibration batches and the exact frames selected for night end.
  Future<Response> handleBacklog(Request request) async {
    final backlog = container.read(calibrationBacklogServiceProvider);
    final scheduled = await backlog.scheduledFlats();
    return jsonOk({
      'groups': [
        for (final group in await backlog.pending())
          {
            'key': group.key,
            'kind': group.kind.name,
            'filter': group.filter,
            'gain': group.gain,
            'offset': group.offset,
            'binX': group.binX,
            'binY': group.binY,
            'night': group.night,
            'lastCapturedAt': group.lastCapturedAt.toIso8601String(),
            'frameIds': group.frames.map((f) => f.id).toList(),
            'buildable': group.buildable,
            'missingFiles': group.missingFiles,
            'scheduled': scheduled.containsKey(group.key),
          },
      ],
    });
  }

  /// Largest page [handleList] will return in one response.
  static const int _maxListLimit = 1000;

  /// GET /api/calibration-library — list masters, newest first.
  ///
  /// Query params (all optional): `type` (dark|bias|flat|defectMap),
  /// `cameraId`, `gain`, `filter`, `binX`, `binY`, `exposureSeconds`
  /// (with `exposureTolSecs`), `tempMin`, `tempMax`, and `mastersOnly`
  /// (default true).
  ///
  /// Pagination is optional and omitting it returns the full set, so a remote
  /// client that expects every master still gets one: `offset` (rows to skip)
  /// and `limit` (rows to return, 1–[_maxListLimit]). The response carries
  /// `total` (matches before paging) alongside `count` (rows in this page).
  Future<Response> handleList(Request request) async {
    _logger.info(
      '[API] GET /api/calibration-library',
      source: 'CalibrationLibraryHandlers',
    );
    final q = request.url.queryParameters;
    final typeRaw = q['type'];
    final temperatureMin = optionalQueryDouble(q, 'tempMin');
    final temperatureMax = optionalQueryDouble(q, 'tempMax');
    if (temperatureMin != null &&
        temperatureMax != null &&
        temperatureMin > temperatureMax) {
      throw BadRequestError(
        field: 'tempMin',
        expected: '<= tempMax',
        message: 'tempMin must not exceed tempMax',
      );
    }

    final filter = CalibrationLibraryFilter(
      type: typeRaw == null || typeRaw.isEmpty ? null : _requireType(typeRaw),
      cameraId: _nonBlank(q['cameraId']),
      gain: optionalQueryInt(q, 'gain'),
      filter: _nonBlank(q['filter']),
      binX: optionalQueryInt(q, 'binX', min: 1),
      binY: optionalQueryInt(q, 'binY', min: 1),
      exposureSeconds: optionalQueryDouble(q, 'exposureSeconds', min: 0),
      exposureToleranceSecs:
          optionalQueryDouble(q, 'exposureTolSecs', min: 0) ?? 0.5,
      temperatureMin: temperatureMin,
      temperatureMax: temperatureMax,
      mastersOnly: optionalQueryBool(q, 'mastersOnly') ?? true,
    );

    final records = await _service.listMasters(filter: filter);
    final total = records.length;

    var page = records;
    final offset = optionalQueryInt(q, 'offset', min: 0);
    if (offset != null && offset > 0) {
      page = offset >= page.length
          ? const <CalibrationMasterRecord>[]
          : page.sublist(offset);
    }
    final limit = optionalQueryInt(q, 'limit', min: 1, max: _maxListLimit);
    if (limit != null) {
      if (page.length > limit) page = page.sublist(0, limit);
    }

    final now = DateTime.now();
    return jsonOk({
      'masters': [for (final r in page) r.toJson(now: now)],
      'count': page.length,
      'total': total,
    });
  }

  /// POST /api/calibration-library/match — preview the auto-selection for a
  /// light-frame context. Body: `{exposureSeconds, gain?, offset?,
  /// temperature?, filter?, binX?, binY?, cameraId?, opticalTrainId?,
  /// sensorWidth?, sensorHeight?}`.
  ///
  /// `gain` and `offset` are optional because a caller's own capture metadata
  /// may not carry them (`captured_images.gain`/`.offset` are nullable). An
  /// omitted one is passed to the matcher as UNKNOWN, which drops that
  /// dimension from the comparison and marks the pick unverified on it — the
  /// alternative, defaulting to 0, would silently match the caller's lights
  /// against a gain-0 library.
  ///
  /// `cameraId` and `sensorWidth`/`sensorHeight` feed the quality gate: a
  /// REMOTE shared master is folded into the ranking only when it was shot on the
  /// same camera and sensor geometry, so omitting them refuses every remote
  /// candidate (the gate fails closed).
  Future<Response> handleMatch(Request request) async {
    _logger.info(
      '[API] POST /api/calibration-library/match',
      source: 'CalibrationLibraryHandlers',
    );
    final body = await readJsonObject(request);

    final context = LightFrameContext(
      cameraId: optionalString(body, 'cameraId'),
      gain: optionalInt(body, 'gain'),
      offset: optionalInt(body, 'offset'),
      exposureSeconds: requireDouble(body, 'exposureSeconds', min: 0),
      temperature: optionalDouble(body, 'temperature'),
      filter: optionalString(body, 'filter'),
      binX: optionalInt(body, 'binX', min: 1) ?? 1,
      binY: optionalInt(body, 'binY', min: 1) ?? 1,
      opticalTrainId: optionalString(body, 'opticalTrainId'),
      sensorWidth: optionalInt(body, 'sensorWidth', min: 1),
      sensorHeight: optionalInt(body, 'sensorHeight', min: 1),
    );

    final matchSet = await _service.match(context);
    return jsonOk(matchSet.toJson());
  }

  /// POST /api/calibration-library/accept — download a REMOTE shared master
  /// surfaced by a prior `/match` and merge it into the appliance's local
  /// library on accept, with the consent + quality gates re-applied.
  ///
  /// Body is the REMOTE `CalibrationMasterRecord` JSON from the match result
  /// (must carry `remoteId`). Returns the acceptance outcome: `merged` (with the
  /// new local id + file path), `preferredLocal` (an exact-tuple local master was
  /// kept), or `refused` (with the reason).
  Future<Response> handleAccept(Request request) async {
    _logger.info(
      '[API] POST /api/calibration-library/accept',
      source: 'CalibrationLibraryHandlers',
    );
    final body = await readJsonObject(request);
    // Parse defensively (same shape as profile_handlers): every other field in
    // this decoder is tolerant, but `id` is a hard `(json['id'] as num)` cast,
    // so a missing or misspelled id collapsed into an opaque 500
    // ("type 'Null' is not a subtype of type 'num' in type cast").
    final CalibrationMasterRecord record;
    try {
      record = CalibrationMasterRecord.fromJson(body);
    } on Object {
      throw BadRequestError(
        field: 'id',
        expected: 'calibration_master_record with a numeric id',
        message: 'Malformed calibration-master payload',
      );
    }
    if (!record.isRemote) {
      throw BadRequestError(
        field: 'remoteId',
        expected: 'a remote master record (with remoteId set)',
        message: 'accept requires a remote shared-master record',
      );
    }
    try {
      final outcome = await _service.acceptRemoteMaster(record);
      return jsonOk({
        'kind': outcome.kind.name,
        if (outcome.mergedId != null) 'mergedId': outcome.mergedId,
        if (outcome.filePath != null) 'filePath': outcome.filePath,
        if (outcome.existing != null) 'existingId': outcome.existing!.id,
        if (outcome.reason != null) 'reason': outcome.reason,
      });
    } on ConstellationException catch (e) {
      return _hubError(
        e,
        code: 'calibration_accept_failed',
        message: 'Failed to accept calibration master',
      );
    } on StateError catch (e) {
      throw HandlerFailure(
        code: 'calibration_accept_failed',
        message: e.message,
        statusCode: 400,
      );
    }
  }

  /// POST /api/calibration-library/publish — publish a LOCAL appliance master to
  /// the configured hub under an explicit consent/license.
  ///
  /// Body: `{type, id, license, attributionName?, shareRawSubframes?,
  /// allowDerivatives?, allowRedistribution?, darkCurrent?}`.
  Future<Response> handlePublish(Request request) async {
    _logger.info(
      '[API] POST /api/calibration-library/publish',
      source: 'CalibrationLibraryHandlers',
    );
    final body = await readJsonObject(request);
    final type = _requireType(requireString(body, 'type'));
    final id = requireInt(body, 'id', min: 1);
    // An explicit publish action opts into the permissive default only when the
    // license token is recognized; an unknown token fails closed to `private`,
    // which publishMaster then refuses.
    final license = ContributionLicense.fromWire(
      requireString(body, 'license'),
      fallback: ContributionLicense.private,
    );
    final record = await _service.getRecord(type, id);
    if (record == null) {
      throw HandlerFailure(
        code: 'calibration_master_not_found',
        message: 'No calibration master with that type/id',
        statusCode: 404,
      );
    }
    final consent = ContributionConsent(
      license: license,
      attributionName: optionalString(body, 'attributionName'),
      shareRawSubframes: optionalBool(body, 'shareRawSubframes') ?? false,
      allowDerivatives: optionalBool(body, 'allowDerivatives') ?? true,
      allowRedistribution: optionalBool(body, 'allowRedistribution') ?? true,
      consentedAt: DateTime.now(),
    );
    try {
      final published = await _service.publishMaster(
        record,
        consent: consent,
        provenance: Provenance(
          darkCurrent: optionalDouble(body, 'darkCurrent'),
        ),
      );
      return jsonOk({
        'status': 'published',
        'id': published.id,
        'masterType': published.masterType,
        'license': published.license.wireName,
        'frameCount': published.frameCount,
      });
    } on ConstellationException catch (e) {
      return _hubError(
        e,
        code: 'calibration_publish_failed',
        message: 'Failed to publish calibration master',
      );
    } on StateError catch (e) {
      throw HandlerFailure(
        code: 'calibration_publish_failed',
        message: e.message,
        statusCode: 400,
      );
    }
  }

  /// POST /api/calibration-library/retract — retract (un-share) a LOCAL
  /// appliance master the user published to the hub. Owner-scoped.
  /// Body: `{type, id}`.
  Future<Response> handleRetract(Request request) async {
    _logger.info(
      '[API] POST /api/calibration-library/retract',
      source: 'CalibrationLibraryHandlers',
    );
    final body = await readJsonObject(request);
    final type = _requireType(requireString(body, 'type'));
    final id = requireInt(body, 'id', min: 1);
    final record = await _service.getRecord(type, id);
    if (record == null) {
      throw HandlerFailure(
        code: 'calibration_master_not_found',
        message: 'No calibration master with that type/id',
        statusCode: 404,
      );
    }
    try {
      await _service.retractPublishedMaster(record);
      return jsonOk({
        'status': 'retracted',
        'type': calibrationMasterTypeWireName(type),
        'id': id,
      });
    } on ConstellationException catch (e) {
      return _hubError(
        e,
        code: 'calibration_retract_failed',
        message: 'Failed to retract calibration master',
      );
    } on StateError catch (e) {
      throw HandlerFailure(
        code: 'calibration_retract_failed',
        message: e.message,
        statusCode: 400,
      );
    }
  }

  /// PUT `/api/calibration-library/<type>/<id>/tags` — replace tags/notes.
  /// Body: `{tags?: string[], notes?: string|null}`.
  Future<Response> handleSetTags(
    Request request,
    String typeRaw,
    String idRaw,
  ) async {
    final type = _requireType(typeRaw);
    final id = _requireId(idRaw);
    _logger.info(
      '[API] PUT /api/calibration-library/$typeRaw/$id/tags',
      source: 'CalibrationLibraryHandlers',
    );
    final body = await readJsonObject(request);

    if (body.containsKey('tags')) {
      final tags = requireList<String>(body, 'tags');
      await _service.setTags(type, id, tags);
    }
    if (body.containsKey('notes')) {
      await _service.setNotes(type, id, optionalString(body, 'notes'));
    }

    final updated = await _service.getRecord(type, id);
    if (updated == null) {
      throw HandlerFailure(
        code: 'calibration_master_not_found',
        message: 'No calibration master with that type/id',
        statusCode: 404,
      );
    }
    return jsonOk(updated.toJson());
  }

  /// DELETE `/api/calibration-library/<type>/<id>[?deleteFile=true]`.
  Future<Response> handleDelete(
    Request request,
    String typeRaw,
    String idRaw,
  ) async {
    final type = _requireType(typeRaw);
    final id = _requireId(idRaw);
    final deleteFile =
        optionalQueryBool(request.url.queryParameters, 'deleteFile') ?? false;
    _logger.info(
      '[API] DELETE /api/calibration-library/$typeRaw/$id'
      ' (deleteFile=$deleteFile)',
      source: 'CalibrationLibraryHandlers',
    );

    final removed = await _service.deleteMaster(
      type,
      id,
      deleteFile: deleteFile,
    );
    if (!removed) {
      throw HandlerFailure(
        code: 'calibration_master_not_found',
        message: 'No calibration master with that type/id',
        statusCode: 404,
      );
    }
    return jsonOk({'status': 'deleted', 'type': typeRaw, 'id': id});
  }

  // param helpers

  CalibrationMasterType _requireType(String? raw) {
    final type = _typeParam(raw);
    if (type == null) {
      throw BadRequestError(
        field: 'type',
        expected: 'dark|bias|flat|defectMap',
        message: 'Unknown calibration master type',
      );
    }
    return type;
  }

  int _requireId(String? raw) {
    final id = _intParam(raw);
    if (id == null || id < 1) {
      throw BadRequestError(field: 'id', expected: 'positive integer');
    }
    return id;
  }

  static CalibrationMasterType? _typeParam(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return calibrationMasterTypeFromWire(raw);
  }

  static int? _intParam(String? raw) =>
      (raw == null || raw.isEmpty) ? null : int.tryParse(raw);

  static String? _nonBlank(String? raw) {
    final value = raw?.trim();
    return value == null || value.isEmpty ? null : value;
  }
}
