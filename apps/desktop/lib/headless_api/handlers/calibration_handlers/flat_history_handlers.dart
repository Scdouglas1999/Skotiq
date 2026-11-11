part of '../calibration_handlers.dart';

extension CalibrationFlatHistoryHandlers on CalibrationHandlers {
  /// GET /api/calibration/flats
  Future<Response> handleListFlats(Request request) async {
    final params = request.url.queryParameters;

    final filter = params['filter'];
    final equipmentProfileId = _parseIntParam(params, 'equipmentProfileId');
    final gain = _parseIntParam(params, 'gain');
    final since = _parseDateParam(params, 'since');
    final limit = _parseListLimit(params);

    final entries = await _database.flatHistoryDao.listFiltered(
      filterName: filter,
      equipmentProfileId: equipmentProfileId,
      gain: gain,
      since: since,
      limit: limit,
    );

    final json = entries.map(_flatEntryToJson).toList(growable: false);
    return jsonOk({'flats': json, 'count': json.length});
  }

  /// GET /api/calibration/flats/{id}
  Future<Response> handleGetFlat(Request request, String id) async {
    final iid = _parsePathId(id, 'id');
    final entry = await _database.flatHistoryDao.getById(iid);
    if (entry == null) {
      return jsonNotFound({
        'error': 'flat_not_found',
        'message': 'No flat history entry with id $iid',
      });
    }
    return jsonOk({'flat': _flatEntryToJson(entry)});
  }

  /// POST /api/calibration/flats
  Future<Response> handleRecordFlat(Request request) async {
    _logInfo('[API] POST /api/calibration/flats');
    final payload = await readJsonObject(request);

    final filterName = requireString(payload, 'filter');
    final exposureDuration = requireDouble(payload, 'exposureDuration', min: 0);
    final adu = requireInt(payload, 'adu', min: 0);
    final histogramTarget = optionalDouble(payload, 'histogramTarget') ?? 50.0;
    final gain = optionalInt(payload, 'gain') ?? 0;
    final binning = optionalInt(payload, 'binning', min: 1) ?? 1;
    final panelBrightness = optionalInt(
      payload,
      'panelBrightness',
      min: 0,
      max: 255,
    );
    final skyAduRate = optionalDouble(payload, 'skyAduRate');
    final twilightPhase = optionalString(payload, 'twilightPhase');
    final equipmentProfileId = optionalInt(payload, 'equipmentProfileId');

    final id = await _database.flatHistoryDao.insertEntry(
      FlatHistoryCompanion.insert(
        filterName: filterName,
        exposureTime: exposureDuration,
        histogramTarget: histogramTarget,
        actualAdu: adu,
        gain: Value(gain),
        binning: Value(binning),
        panelBrightness: Value(panelBrightness),
        skyAduRate: Value(skyAduRate),
        twilightPhase: Value(twilightPhase),
        equipmentProfileId: Value(equipmentProfileId),
      ),
    );
    final entry = await _database.flatHistoryDao.getById(id);
    if (entry == null) {
      throw HandlerFailure(
        code: 'flat_record_failed',
        message: 'Failed to read back newly-recorded flat history entry',
      );
    }
    return jsonCreated({'flat': _flatEntryToJson(entry)});
  }

  /// DELETE /api/calibration/flats/{id}
  Future<Response> handleDeleteFlat(Request request, String id) async {
    final iid = _parsePathId(id, 'id');
    _logInfo('[API] DELETE /api/calibration/flats/$iid');
    final rows = await _database.flatHistoryDao.deleteById(iid);
    if (rows == 0) {
      return jsonNotFound({
        'error': 'flat_not_found',
        'message': 'No flat history entry with id $iid',
      });
    }
    return jsonOk({'deleted': true});
  }

  /// GET /api/calibration/flats/recommendation
  Future<Response> handleFlatRecommendation(Request request) async {
    final params = request.url.queryParameters;
    final filter = params['filter'];
    if (filter == null || filter.isEmpty) {
      throw BadRequestError(
        field: 'filter',
        expected: 'non-empty string',
        message: 'filter query parameter is required',
      );
    }
    final equipmentProfileId = _parseIntParam(params, 'equipmentProfileId');
    final gain = _parseIntParam(params, 'gain');

    final entry = await _database.flatHistoryDao.findMostRecentMatch(
      filterName: filter,
      equipmentProfileId: equipmentProfileId,
      gain: gain,
    );
    if (entry == null) {
      return jsonOk({'recommended': null, 'reason': 'no_matching_history'});
    }
    final ageDays = DateTime.now()
        .toUtc()
        .difference(entry.timestamp.toUtc())
        .inDays;
    final confidence = ageDays <= 7
        ? 'high'
        : (ageDays <= 30 ? 'medium' : 'low');
    return jsonOk({
      'recommended': {
        'exposureDuration': entry.exposureTime,
        'basedOn': {
          'flatId': entry.id,
          'ageDays': ageDays,
          'confidence': confidence,
        },
      },
    });
  }
}
