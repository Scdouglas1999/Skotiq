part of '../network_backend.dart';

/// The dark library, flat records and defect-map settings of a linked imaging host.
mixin HostCalibrationFrames on NetworkBackendTransport {
  /// GET /api/calibration/darks — filtered listing.
  Future<List<RemoteDarkLibraryEntry>> listDarks({
    double? exposureSeconds,
    int? gain,
    double? temperatureCelsius,
    int? limit,
  }) async {
    final params = <String, dynamic>{};
    if (exposureSeconds != null) params['exposureSeconds'] = exposureSeconds;
    if (gain != null) params['gain'] = gain;
    if (temperatureCelsius != null) {
      params['temperatureC'] = temperatureCelsius;
    }
    if (limit != null) params['limit'] = limit;
    final response = await _get(
      CalibrationApi.listDarks,
      query: params.isEmpty ? null : params,
    );
    return _rowsFromJson(response['darks'], RemoteDarkLibraryEntry.fromJson);
  }

  Future<Map<String, dynamic>> getDarkLibrarySettings() async {
    return _get(CalibrationApi.getDarkSettings);
  }

  Future<Map<String, dynamic>> updateDarkLibrarySettings({
    bool? autoCalibrate,
    double? temperatureTolerance,
  }) async {
    return _post(
      CalibrationApi.updateDarkSettings,
      body: {
        if (autoCalibrate != null) 'autoCalibrate': autoCalibrate,
        if (temperatureTolerance != null)
          'temperatureTolerance': temperatureTolerance,
      },
    );
  }

  Future<Map<String, dynamic>> createDarkLibraryMaster({
    required double exposureTime,
    required int gain,
    required int offset,
    required int binX,
    required int binY,
    required String outputPath,
    required String frameType,
  }) async {
    return _post(
      CalibrationApi.createMasterDark,
      body: {
        'exposureTime': exposureTime,
        'gain': gain,
        'offset': offset,
        'binX': binX,
        'binY': binY,
        'outputPath': outputPath,
        'frameType': frameType,
      },
    );
  }

  /// DELETE `/api/calibration/darks/{id}?deleteFile=<bool>`.
  Future<void> deleteDark(int id, {bool deleteFile = false}) async {
    if (deleteFile) {
      await _delete(
        CalibrationApi.deleteDark,
        path: {'id': id},
        query: {'deleteFile': 'true'},
      );
    } else {
      await _delete(CalibrationApi.deleteDark, path: {'id': id});
    }
  }

  Future<int> deleteDarkLibraryGroup({
    required double exposureTime,
    required int? gain,
    required int? offset,
    required int binX,
    required int binY,
    required String frameType,
    bool deleteFiles = false,
  }) async {
    final response = await _post(
      CalibrationApi.deleteDarkGroup,
      body: {
        'exposureTime': exposureTime,
        if (gain != null) 'gain': gain,
        if (offset != null) 'offset': offset,
        'binX': binX,
        'binY': binY,
        'frameType': frameType,
        'deleteFiles': deleteFiles,
      },
    );
    return (response['removed'] as num?)?.toInt() ?? 0;
  }

  Future<int> cleanDarkLibraryOrphans() async {
    final response = await _post(CalibrationApi.cleanDarkOrphans);
    return (response['removed'] as num?)?.toInt() ?? 0;
  }

  Future<int> clearDarkLibrary({bool deleteFiles = false}) async {
    final response = await _post(
      CalibrationApi.clearDarkLibrary,
      body: {'deleteFiles': deleteFiles},
    );
    return (response['removed'] as num?)?.toInt() ?? 0;
  }

  /// GET /api/calibration/flats — filtered listing.
  Future<List<RemoteFlatHistoryEntry>> listFlats({
    String? filter,
    int? equipmentProfileId,
    int? gain,
    DateTime? since,
    int? limit,
  }) async {
    final params = <String, dynamic>{};
    if (filter != null) params['filter'] = filter;
    if (equipmentProfileId != null) {
      params['equipmentProfileId'] = equipmentProfileId;
    }
    if (gain != null) params['gain'] = gain;
    if (since != null) params['since'] = since.toUtc().toIso8601String();
    if (limit != null) params['limit'] = limit;
    final response = await _get(
      CalibrationApi.listFlats,
      query: params.isEmpty ? null : params,
    );
    return _rowsFromJson(response['flats'], RemoteFlatHistoryEntry.fromJson);
  }

  /// POST /api/calibration/flats — record a flat-history entry.
  Future<RemoteFlatHistoryEntry> recordFlat({
    required String filter,
    required double exposureDuration,
    required int adu,
    double histogramTarget = 50.0,
    int gain = 0,
    int binning = 1,
    int? panelBrightness,
    double? skyAduRate,
    String? twilightPhase,
    int? equipmentProfileId,
  }) async {
    final body = <String, dynamic>{
      'filter': filter,
      'exposureDuration': exposureDuration,
      'adu': adu,
      'histogramTarget': histogramTarget,
      'gain': gain,
      'binning': binning,
      if (panelBrightness != null) 'panelBrightness': panelBrightness,
      if (skyAduRate != null) 'skyAduRate': skyAduRate,
      if (twilightPhase != null) 'twilightPhase': twilightPhase,
      if (equipmentProfileId != null) 'equipmentProfileId': equipmentProfileId,
    };
    final response = await _post(CalibrationApi.recordFlat, body: body);
    return RemoteFlatHistoryEntry.fromJson(
      (response['flat'] as Map).cast<String, dynamic>(),
    );
  }

  Future<Map<String, dynamic>> getDefectMapSettings() {
    return _get(CalibrationApi.getDefectMapSettings);
  }

  Future<Map<String, dynamic>> updateDefectMapSettings(
    Map<String, dynamic> patch,
  ) {
    return _post(CalibrationApi.updateDefectMapSettings, body: patch);
  }
}
