part of '../network_backend.dart';

/// A backup or restore of a season's database takes the host minutes, and
/// the answer is the outcome.
const _backupTimeout = Duration(minutes: 30);

mixin _NetworkBackendSessionScienceOperations on NetworkBackendTransport {
  Future<List<AstrometryResidualVectorRow>> getSessionResidualVectors(
    int sessionId,
  ) async {
    final endpoint = 'GET /api/sessions/$sessionId/residuals';
    final response = await _get(
      AnalyticsApi.getSessionResiduals,
      path: {'id': sessionId},
    );
    final rows = _sessionScienceObjectList(response, 'residuals', endpoint);
    final seenIds = <int>{};
    final vectors = <AstrometryResidualVectorRow>[];
    for (var index = 0; index < rows.length; index++) {
      final vector = _residualVectorFromJson(rows[index], endpoint, index);
      if (!seenIds.add(vector.id)) {
        throw FormatException(
          '$endpoint row $index field `id` duplicates id ${vector.id}',
        );
      }
      vectors.add(vector);
    }
    return vectors;
  }

  Future<Map<String, dynamic>> getAnalyticsSummary({
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final params = <String, dynamic>{};
    if (startDate != null) {
      params['startDate'] = startDate.toUtc().toIso8601String();
    }
    if (endDate != null) {
      params['endDate'] = endDate.toUtc().toIso8601String();
    }
    final response = await _get(
      AnalyticsApi.getAnalyticsSummary,
      query: params.isEmpty ? null : params,
    );
    return response;
  }

  Future<Map<String, dynamic>> getTotalIntegrationTime({
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final params = <String, dynamic>{};
    if (startDate != null) {
      params['startDate'] = startDate.toUtc().toIso8601String();
    }
    if (endDate != null) {
      params['endDate'] = endDate.toUtc().toIso8601String();
    }
    final response = await _get(
      AnalyticsApi.getTotalIntegrationTime,
      query: params.isEmpty ? null : params,
    );
    return response;
  }

  Future<Map<String, dynamic>> getWeatherRadar(
    double lat,
    double lon, {
    bool forceRefresh = false,
  }) async {
    final response = await _get(
      WeatherApi.getRadarData,
      query: {
        'lat': lat.toString(),
        'lon': lon.toString(),
        if (forceRefresh) 'refresh': 'true',
      },
    );
    return response;
  }

  Future<List<Map<String, dynamic>>> getWeatherAlerts() async {
    final response = await _get(WeatherApi.getAlerts);
    return _sessionScienceObjectList(
      response,
      'alerts',
      'GET /api/weather/alerts',
    );
  }

  Future<void> clearWeatherCache() async {
    await _post(WeatherApi.clearCache);
  }

  Future<Map<String, dynamic>> getTargetScore(int targetId) async {
    final response = await _get(
      SuggestionApi.getTargetScore,
      path: {'targetId': targetId},
    );
    return response;
  }

  Future<void> queueTransient(String transientId) async {
    await _post(TransientApi.queueTransient, path: {'id': transientId});
  }

  Future<void> dismissTransient(String transientId) async {
    await _post(TransientApi.dismissTransient, path: {'id': transientId});
  }

  Future<void> refreshTransientAlerts() async {
    await _post(TransientApi.refreshAlerts);
  }

  Future<Map<String, dynamic>> getQueuedTransients() async {
    final response = await _get(TransientApi.getQueued);
    return response;
  }

  Future<Map<String, dynamic>> getBackupMetadata(String backupId) async {
    final response = await _get(
      BackupApi.getBackupMetadata,
      path: {'id': backupId},
    );
    return response;
  }

  // Only the currently viewed sessions retain spatial maps. Old hosts return
  // no versions and continue using their full GET response.
  final _scienceSessionCache =
      <int, ({Map<String, dynamic> versions, RemoteScienceBundle bundle})>{};

  Future<RemoteScienceBundle> getScienceSessionBundle(int sessionId) async {
    final cached = _scienceSessionCache[sessionId];
    final response = cached == null
        ? await _get(
            ScienceApi.getSessionBundle,
            path: {'sessionId': sessionId},
          )
        : await _post(
            ScienceApi.postSessionBundle,
            path: {'sessionId': sessionId},
            body: {'spatialVersions': cached.versions},
          );
    final versions = (response['spatialVersions'] as Map?)
        ?.cast<String, dynamic>();
    List<T> spatialRows<T>(
      String product,
      List<T> previous,
      T Function(Map<String, dynamic>) decode,
      int? Function(T) imageId,
      DateTime Function(T) timestamp, {
      bool descending = true,
    }) {
      final rows = _rowsFromJson<T>(response[product], decode);
      if (versions == null || cached == null) return rows;
      final current = (versions[product] as Map).cast<String, dynamic>();
      final old = (cached.versions[product] as Map).cast<String, dynamic>();
      if (current.length == old.length &&
          current.entries.every((e) => old[e.key] == e.value)) {
        return previous;
      }
      final merged = [
        for (final row in previous)
          if (current.containsKey(imageId(row)?.toString() ?? 'none') &&
              current[imageId(row)?.toString() ?? 'none'] ==
                  old[imageId(row)?.toString() ?? 'none'])
            row,
        ...rows,
      ];
      merged.sort(
        (a, b) => descending
            ? timestamp(b).compareTo(timestamp(a))
            : timestamp(a).compareTo(timestamp(b)),
      );
      return merged;
    }

    final bundle = RemoteScienceBundle(
      photometry: _rowsFromJson<PhotometryMeasurementRow>(
        response['photometry'],
        PhotometryMeasurementRow.fromJson,
      ),
      calibrations: _rowsFromJson<FramePhotometricCalibrationRow>(
        response['calibrations'],
        FramePhotometricCalibrationRow.fromJson,
      ),
      transparency: _rowsFromJson<TransparencySampleRow>(
        response['transparency'],
        TransparencySampleRow.fromJson,
      ),
      psfTiles: spatialRows<PsfFieldTileRow>(
        'psfTiles',
        cached?.bundle.psfTiles ?? const [],
        PsfFieldTileRow.fromJson,
        (row) => row.capturedImageId,
        (row) => row.timestamp,
        descending: true,
      ),
      frameQuality: _rowsFromJson<ScienceFrameQualityMetricsRow>(
        response['frameQuality'],
        ScienceFrameQualityMetricsRow.fromJson,
      ),
      tileMetrics: spatialRows<ScienceTileMetricRow>(
        'tileMetrics',
        cached?.bundle.tileMetrics ?? const [],
        ScienceTileMetricRow.fromJson,
        (row) => row.capturedImageId,
        (row) => row.timestamp,
        descending: true,
      ),
      residuals: spatialRows<AstrometryResidualVectorRow>(
        'residuals',
        cached?.bundle.residuals ?? const [],
        AstrometryResidualVectorRow.fromJson,
        (row) => row.capturedImageId,
        (row) => row.timestamp,
        descending: false,
      ),
      movingObjects: _rowsFromJson<MovingObjectCandidateRow>(
        response['movingObjects'],
        MovingObjectCandidateRow.fromJson,
      ),
      lineRatios: _rowsFromJson<LineRatioProductRow>(
        response['lineRatios'],
        LineRatioProductRow.fromJson,
      ),
    );
    if (versions != null) {
      _scienceSessionCache.remove(sessionId);
      _scienceSessionCache[sessionId] = (versions: versions, bundle: bundle);
      while (_scienceSessionCache.length > 2) {
        _scienceSessionCache.remove(_scienceSessionCache.keys.first);
      }
    } else {
      _scienceSessionCache.remove(sessionId);
    }
    return bundle;
  }

  Future<ScienceSessionConfig?> getScienceSessionConfig(int sessionId) async {
    final response = await _get(
      ScienceApi.getSessionConfig,
      path: {'sessionId': sessionId},
    );
    final config = _sessionScienceNullableObject(
      response,
      'config',
      'GET /api/science/session/$sessionId/config',
    );
    return config == null ? null : ScienceSessionConfig.fromJson(config);
  }

  Future<void> updateScienceSessionConfig(
    int sessionId,
    ScienceSessionConfig config,
  ) async {
    await _post(
      ScienceApi.updateSessionConfig,
      path: {'sessionId': sessionId},
      body: {'config': config.toJson()},
    );
  }

  String? _sessionScienceRowNullableString(
    Map<String, dynamic> json,
    String field,
    String endpoint,
    int rowIndex,
  ) {
    if (!json.containsKey(field) || json[field] == null) return null;
    final raw = json[field];
    if (raw is! String || raw.trim().isEmpty) {
      throw FormatException(
        '$endpoint row $rowIndex field `$field` must be a non-empty string or null',
      );
    }
    return raw;
  }

  AstrometryResidualVectorRow _residualVectorFromJson(
    Map<String, dynamic> json,
    String endpoint,
    int rowIndex,
  ) {
    return AstrometryResidualVectorRow(
      id: _sessionScienceRowInt(json, 'id', endpoint, rowIndex, minimum: 1),
      capturedImageId: _sessionScienceRowNullableId(
        json,
        'capturedImageId',
        endpoint,
        rowIndex,
      ),
      sessionId: _sessionScienceRowNullableId(
        json,
        'sessionId',
        endpoint,
        rowIndex,
      ),
      x: _sessionScienceRowDouble(json, 'x', endpoint, rowIndex, minimum: 0),
      y: _sessionScienceRowDouble(json, 'y', endpoint, rowIndex, minimum: 0),
      dxArcsec: _sessionScienceRowDouble(json, 'dxArcsec', endpoint, rowIndex),
      dyArcsec: _sessionScienceRowDouble(json, 'dyArcsec', endpoint, rowIndex),
      magnitudeArcsec: _sessionScienceRowDouble(
        json,
        'magnitudeArcsec',
        endpoint,
        rowIndex,
        minimum: 0,
      ),
      recommendationCode: _sessionScienceRowNullableString(
        json,
        'recommendationCode',
        endpoint,
        rowIndex,
      ),
      timestamp: _sessionScienceRowTimestamp(json, endpoint, rowIndex),
    );
  }
}

extension _NetworkBackendSessionScienceOperationsHelpers
    on NetworkBackendTransport {
  List<Map<String, dynamic>> _sessionScienceObjectList(
    Map<String, dynamic> response,
    String field,
    String request,
  ) {
    final raw = response[field];
    if (raw is! List) {
      throw FormatException(
        '$request returned a missing or non-list `$field` field',
      );
    }
    final rows = <Map<String, dynamic>>[];
    for (var index = 0; index < raw.length; index++) {
      final row = raw[index];
      if (row is! Map) {
        throw FormatException(
          '$request returned a non-object `$field[$index]` row',
        );
      }
      rows.add(row.cast<String, dynamic>());
    }
    return rows;
  }

  Map<String, dynamic> _sessionScienceObject(
    Map<String, dynamic> response,
    String field,
    String request,
  ) {
    final raw = response[field];
    if (raw is! Map) {
      throw FormatException(
        '$request returned a missing or non-object `$field` field',
      );
    }
    return raw.cast<String, dynamic>();
  }

  Map<String, dynamic>? _sessionScienceNullableObject(
    Map<String, dynamic> response,
    String field,
    String request,
  ) {
    if (!response.containsKey(field)) {
      throw FormatException('$request returned no `$field` field');
    }
    final raw = response[field];
    if (raw == null) return null;
    if (raw is! Map) {
      throw FormatException('$request returned a non-object `$field` field');
    }
    return raw.cast<String, dynamic>();
  }

  num _sessionScienceNumber(
    Map<String, dynamic> response,
    String field,
    String request,
  ) {
    final raw = response[field];
    if (raw is! num) {
      throw FormatException(
        '$request returned a missing or non-numeric `$field` field',
      );
    }
    return raw;
  }

  List<Map<String, dynamic>> _narratorEventsList(Map<String, dynamic> json) {
    return _sessionScienceObjectList(json, 'events', 'GET /api/narrator feed');
  }

  PsfFieldTileRow _psfFieldTileFromJson(
    Map<String, dynamic> json,
    String endpoint,
    int rowIndex,
  ) {
    return PsfFieldTileRow(
      id: _sessionScienceRowInt(json, 'id', endpoint, rowIndex, minimum: 1),
      capturedImageId: _sessionScienceRowNullableId(
        json,
        'capturedImageId',
        endpoint,
        rowIndex,
      ),
      sessionId: _sessionScienceRowNullableId(
        json,
        'sessionId',
        endpoint,
        rowIndex,
      ),
      tileRow: _sessionScienceRowInt(
        json,
        'tileRow',
        endpoint,
        rowIndex,
        minimum: 0,
      ),
      tileCol: _sessionScienceRowInt(
        json,
        'tileCol',
        endpoint,
        rowIndex,
        minimum: 0,
      ),
      starCount: _sessionScienceRowInt(
        json,
        'starCount',
        endpoint,
        rowIndex,
        minimum: 0,
      ),
      medianFwhm: _sessionScienceRowDouble(
        json,
        'medianFwhm',
        endpoint,
        rowIndex,
        minimum: 0,
      ),
      medianHfr: _sessionScienceRowDouble(
        json,
        'medianHfr',
        endpoint,
        rowIndex,
        minimum: 0,
      ),
      medianEccentricity: _sessionScienceRowDouble(
        json,
        'medianEccentricity',
        endpoint,
        rowIndex,
        minimum: 0,
        maximum: 1,
      ),
      roundness: _sessionScienceRowDouble(
        json,
        'roundness',
        endpoint,
        rowIndex,
        minimum: 0,
        maximum: 1,
      ),
      timestamp: _sessionScienceRowTimestamp(json, endpoint, rowIndex),
    );
  }

  int _sessionScienceRowInt(
    Map<String, dynamic> json,
    String field,
    String endpoint,
    int rowIndex, {
    int? minimum,
  }) {
    final raw = json[field];
    if (raw is! num || !raw.isFinite || raw.toInt() != raw) {
      throw FormatException(
        '$endpoint row $rowIndex field `$field` must be a finite integer',
      );
    }
    final value = raw.toInt();
    if (minimum != null && value < minimum) {
      throw FormatException(
        '$endpoint row $rowIndex field `$field` must be at least $minimum',
      );
    }
    return value;
  }

  int? _sessionScienceRowNullableId(
    Map<String, dynamic> json,
    String field,
    String endpoint,
    int rowIndex,
  ) {
    if (!json.containsKey(field) || json[field] == null) return null;
    return _sessionScienceRowInt(json, field, endpoint, rowIndex, minimum: 1);
  }

  double _sessionScienceRowDouble(
    Map<String, dynamic> json,
    String field,
    String endpoint,
    int rowIndex, {
    double? minimum,
    double? maximum,
  }) {
    final raw = json[field];
    if (raw is! num || !raw.isFinite) {
      throw FormatException(
        '$endpoint row $rowIndex field `$field` must be a finite number',
      );
    }
    final value = raw.toDouble();
    if (minimum != null && value < minimum ||
        maximum != null && value > maximum) {
      final range = maximum == null
          ? 'at least $minimum'
          : minimum == null
          ? 'at most $maximum'
          : 'between $minimum and $maximum';
      throw FormatException(
        '$endpoint row $rowIndex field `$field` must be $range',
      );
    }
    return value;
  }

  DateTime _sessionScienceRowTimestamp(
    Map<String, dynamic> json,
    String endpoint,
    int rowIndex,
  ) {
    final milliseconds = _sessionScienceRowInt(
      json,
      'timestamp',
      endpoint,
      rowIndex,
      minimum: 0,
    );
    return DateTime.fromMillisecondsSinceEpoch(milliseconds);
  }
}
